#!/usr/bin/env bash
# icloud_sync_guard.sh 的判别力自证。它治的是「hook 里的 async 实例挂住 / 堆积」（2026-10-06 实测），所以重点不是
# 找对目录（N 组，回归保护），而是三条保命线：
#   L 组：单实例锁 —— 并发的第二个实例必须立刻静默退出；持锁进程已死的残锁必须能接管；退出后锁必须释放
#   T 组：硬 deadline —— 阻塞的 find / BIN（含 --dry-run 的 --status）必须被杀死、不留孤儿、总耗时不超预算，
#         且被杀的 find 吐出的半截路径不许被当成目标（否则可能把整个项目误排除出同步）
#   W 组：--sweep 限频 —— 6 小时内完整扫过就静默退出且不调 BIN；flag-less 永远扫；残缺的 sweep（超时 / 预算用尽）
#         绝不更新时间戳，否则一次残缺扫描会让后面 6 小时的 SessionStart 全被限频挡掉
#   S 组：默认总预算必须 < 70s（SessionStart / PostToolUse 的 hook timeout），改大它就红
#
# 跑法：bash scripts/hooks/tests/test_icloud_sync_guard.sh（约 25s，T 组要真等 deadline）
# 变异验证：GUARD=<改坏一条规则的副本> bash 本脚本 → 对应用例必须转红，否则该用例没有判别力。
#
# 隔离：HOME 指向临时目录（扫描根 / BIN / 冷存档 / 锁 / 时间戳全从 HOME 派生，所以不需要额外的路径开关）。
# 绝不碰真实 Desktop，也不会和真实的守卫实例互相阻塞。锁刻意不依赖 TMPDIR：L1 让两个实例带着不同的 TMPDIR 跑，
# 它们仍必须互斥——实测 Claude Code 的 Bash 环境与干净登录 shell 的 TMPDIR 不同。
#
# 不覆盖：「-flags +dataless -prune 真的不下 dataless 目录」——dataless 是内核置位的系统标志，用户态造不出来；
# 这里只保证该表达式合法（N1 里 find 不报错、照常找到目标）。
#
# 写法上的注意：判断退出码一律不走管道（管道后取 $? 既脆也会被 bash_pitfall_guard 拦）。
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GUARD=${GUARD:-$HERE/../../icloud_sync_guard.sh}
pass=0
fail=0

TMP=$(mktemp -d)
# 随机的 sleep 时长当作假进程的指纹：pgrep 靠它找孤儿，不会误伤别处的 sleep
FAKE_SLEEP=$((90000 + RANDOM))
cleanup() {
  pkill -f "sleep $FAKE_SLEEP" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

BUDGET_T=5 # 测试用总预算；find 阶段占 3/4 = 3s
OUT="$TMP/.stdout.txt"
ERR="$TMP/.stderr.txt"

# 假 BIN：行为由 FAKE_MODE 决定，每次调用把 argv 记进 FAKE_LOG
#   hang   —— exec 成单个永久阻塞的进程（和真实的 Swift 二进制一样是「一个进程」，alarm 才打得到它本身）
#   report —— 对每个目标报「已排除」，模拟本轮修复了漂移
#   status —— 只对 --status 调用报第一个目标「同步中」
#   quiet  —— 什么都不输出，模拟全部早已排除
cat > "$TMP/fake_bin" <<'EOF'
#!/bin/bash
printf 'call %s\n' "$1" >> "$FAKE_LOG"
printf 'arg %s\n' "$@" >> "$FAKE_LOG"
case "$FAKE_MODE" in
  hang) exec sleep "$FAKE_SLEEP" ;;
  report) for a in "$@"; do echo "已排除 $a"; done ;;
  status) if [ "$1" = "--status" ]; then echo "同步中 $2"; fi ;;
  quiet) ;;
esac
EOF
# 假 find：吐一条完整记录 + 一条被截断的残记录，然后永久阻塞（模拟 readdir 卡死在 fileproviderd 上）
mkdir -p "$TMP/shim"
cat > "$TMP/shim/find" <<'EOF'
#!/bin/bash
printf '%s\0%s' "$SHIM_FULL" "$SHIM_PART"
exec sleep "$FAKE_SLEEP"
EOF
chmod +x "$TMP/fake_bin" "$TMP/shim/find"

# 造一个 HOME：$1 目录 · $2=1 带夹具，0 只有空的 Desktop/Documents · $3=0 不装 BIN
mk_home() {
  mkdir -p "$1/.local/bin" "$1/Desktop" "$1/Documents"
  [ "${3:-1}" = "1" ] && cp "$TMP/fake_bin" "$1/.local/bin/icloud-exclude"
  if [ "$2" = "1" ]; then
    # 应命中的三个
    mkdir -p "$1/Desktop/proj/node_modules" "$1/Desktop/proj/.next" "$1/Documents/doc/__pycache__"
    # 不应命中：嵌套在 node_modules 里的同名目录（prune）、普通源码目录、冷存档里的 node_modules
    mkdir -p "$1/Desktop/proj/node_modules/pkg/node_modules" "$1/Desktop/proj/src"
    mkdir -p "$1/Desktop/创业/artifacts/old/node_modules"
  fi
}

H="$TMP/home"
mk_home "$H" 1
CACHE="$H/Library/Caches/icloud_sync_guard"
LOCK="$CACHE/lock"
STAMP="$CACHE/last_sweep"
EXPECTED=$(printf '%s\n' "$H/Desktop/proj/node_modules" "$H/Desktop/proj/.next" "$H/Documents/doc/__pycache__" | sort)

export FAKE_MODE=quiet FAKE_LOG="$TMP/log.init" FAKE_SLEEP SHIM_FULL="" SHIM_PART=""
RUN_PATH="$PATH"
RUN_TMPDIR="$TMP"
RC=0
ELAPSED=0

HUNG=0
# 等 $1 号后台进程结束，最多 BUDGET_T+6 秒；超时就 KILL 它并置 HUNG=1。
# 守卫挂住必须表现为用例失败，而不是让测试自己跟着挂死（变异验证时被改坏的守卫就是会挂）
wait_bounded() {
  local pid=$1 start=$2
  HUNG=0
  while kill -0 "$pid" 2> /dev/null && [ $((SECONDS - start)) -lt $((BUDGET_T + 6)) ]; do
    sleep 0.2
  done
  if kill -0 "$pid" 2> /dev/null; then
    HUNG=1
    # 必须 KILL 不能 TERM：bash 阻塞在 $(...) 里时不处理 TERM，要等子进程结束；KILL 杀不到 EXIT trap，锁得手动清
    kill -KILL "$pid"
    rm -f "$LOCK"
  fi
  RC=0
  wait "$pid" || RC=$?
}

# 跑一次守卫，结果落进全局 RC / ELAPSED / HUNG / OUT / ERR
run_guard() {
  local start=$SECONDS
  HOME="$H" TMPDIR="$RUN_TMPDIR" ICLOUD_GUARD_BUDGET="$BUDGET_T" PATH="$RUN_PATH" \
    /bin/bash "$GUARD" "$@" > "$OUT" 2> "$ERR" &
  wait_bounded $! "$start"
  ELAPSED=$((SECONDS - start))
}

# 每个用例用独立的 FAKE_LOG，避免串味；同时清掉上一个用例可能留下的假进程，免得孤儿检查互相污染
new_log() {
  pkill -f "sleep $FAKE_SLEEP" 2> /dev/null
  FAKE_LOG="$TMP/log.$1"
  : > "$FAKE_LOG"
}

logged_args() { grep '^arg ' "$FAKE_LOG" | sed 's/^arg //' | sort; }
call_count() { grep -c '^call ' "$FAKE_LOG"; }
no_orphan() { ! pgrep -f "sleep $FAKE_SLEEP" > /dev/null; }
lock_released() { [ ! -e "$LOCK" ]; }
is_silent() { [ ! -s "$OUT" ] && [ ! -s "$ERR" ]; }
err_has() { grep -qF -- "$1" "$ERR"; }
out_has() { grep -qF -- "$1" "$OUT"; }

now() { date +%s; }
set_stamp() {
  mkdir -p "$CACHE"
  printf '%s\n' "$1" > "$STAMP"
}
stamp_is() { [ "$(cat "$STAMP" 2> /dev/null)" = "$1" ]; }
stamp_just_written() { [ -r "$STAMP" ] && [ $(($(now) - $(cat "$STAMP"))) -le 10 ]; }
no_calls() { [ "$(call_count)" = "0" ]; }

# 失败时把最近一次 run_guard 的现场打出来
dump() {
  echo "   rc=$RC elapsed=${ELAPSED}s calls=$(call_count)"
  echo "   stdout: $(head -3 "$OUT")"
  echo "   stderr: $(head -3 "$ERR")"
}

check() {
  # $1 标签 · 其余是必须为真的命令
  local label=$1
  shift
  if "$@"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL $label"
    dump
  fi
}

args_exact() { [ "$(logged_args)" = "$EXPECTED" ]; }
rc_zero() { [ "$RC" = "0" ]; }
rc_zero_silent() { rc_zero && is_silent; }
ok_in_budget() { rc_zero && within_budget; }
missing_bin_reported() { [ "$RC" = "1" ] && err_has "缺少"; }
partial_path_not_target() { ! grep -qxF "arg $SHIM_PART" "$FAKE_LOG"; }
called_once() { [ "$(call_count)" = "1" ]; }
quick() { [ "$ELAPSED" -le 1 ]; }
within_budget() { [ "$HUNG" = "0" ] && [ "$ELAPSED" -le $((BUDGET_T + 2)) ]; }

# ---- N 组：正常路径（回归保护）----
new_log n1
FAKE_MODE=quiet run_guard
check "N1a 找到三个目标、不下嵌套 node_modules、不进冷存档、不碰源码目录" args_exact
check "N1b 只调一次 BIN 且退出 0"                                          called_once
check "N1c BIN 没有新修复时完全静默"                                       is_silent
check "N1d 正常退出后锁已释放"                                             lock_released

new_log n2
FAKE_MODE=report run_guard
check "N2a BIN 报了修复 -> 输出汇总行"   out_has "修复 3 个掉回 iCloud 同步域的目录（共扫 3 个）"
check "N2b 汇总行后逐条缩进列出目标"     out_has "  已排除 $H/Desktop/proj/node_modules"

new_log n3
FAKE_MODE=status run_guard --dry-run
check "N3a --dry-run 汇总行"                  out_has "扫到 3 个目录，其中 1 个仍在同步域"
check "N3b --dry-run 列出同步中条目"          out_has "同步中 "
check "N3c --dry-run 只调一次 BIN"            called_once
check "N3d --dry-run 的那次调用是 --status"   grep -qx 'call --status' "$FAKE_LOG"

H_EMPTY="$TMP/home_empty"
mk_home "$H_EMPTY" 0
H_SAVE=$H
H=$H_EMPTY
new_log n4
FAKE_MODE=quiet run_guard
check "N4a 没有任何目标 -> 完全静默" is_silent
check "N4b 没有任何目标 -> 不调 BIN"  [ "$(call_count)" = "0" ]
H=$H_SAVE

H_NOBIN="$TMP/home_nobin"
mk_home "$H_NOBIN" 0 0
H=$H_NOBIN
run_guard
check "N5a 缺 BIN -> 退出 1 并提示" missing_bin_reported
H=$H_SAVE

# ---- W 组：--sweep 限频 ----
OLD=$(($(now) - 25000)) # 比 6 小时（21600s）老的时间戳
rm -f "$STAMP"
new_log w1
FAKE_MODE=quiet run_guard --sweep
check "W1a 没有时间戳 -> sweep 照常扫"           called_once
check "W1b 完整跑完 -> 写入时间戳"               stamp_just_written
check "W1c sweep 没新修复时同样完全静默"         is_silent

W1_STAMP=$(cat "$STAMP")
new_log w2
run_guard --sweep
check "W2a 限频内第二次 sweep 立刻退出（<=1s）"  quick
check "W2b 限频内 sweep 静默、退出 0"            rc_zero_silent
check "W2c 限频内 sweep 不调 BIN"                no_calls
check "W2d 限频内 sweep 不动时间戳"              stamp_is "$W1_STAMP"

new_log w3
run_guard
check "W3a 不带参数的运行无视新鲜时间戳，照常扫"  called_once
check "W3b 不带参数的运行不写时间戳"              stamp_is "$W1_STAMP"

set_stamp $(($(now) - 21000))
new_log w7
run_guard --sweep
check "W7 时间戳 21000s（<6h）仍在限频内 -> 不扫"  no_calls

set_stamp "$((OLD - 600))"
new_log w4
run_guard --sweep
check "W4a 时间戳超过 6 小时 -> 允许 sweep"       called_once
check "W4b 完整跑完后时间戳刷新"                  stamp_just_written

set_stamp "garbage"
new_log w5
run_guard --sweep
check "W5a 时间戳内容不是数字 -> 当作没扫过，照常扫"  called_once
check "W5b 坏时间戳不产生任何报错输出"                is_silent
set_stamp ""
new_log w5c
run_guard --sweep
check "W5c 时间戳是空文件 -> 照常扫"                  called_once

set_stamp "$OLD"
new_log w6
FAKE_MODE=status run_guard --sweep --dry-run
check "W6a --sweep --dry-run 过了限频 -> 报告"      out_has "扫到 3 个目录"
check "W6b --dry-run 绝不写时间戳"                  stamp_is "$OLD"

# W8：只有「预算用尽跳过」、没有任何进程被杀的残缺 sweep。预算 1s -> find 阶段额度为 0，两个根都被直接跳过
set_stamp "$OLD"
new_log w8
BUDGET_T=1
run_guard --sweep
BUDGET_T=5
check "W8a 预算用尽被跳过时报「已用尽」"           err_has "已用尽，跳过"
check "W8b 只有跳过、没有超时被杀，也不更新时间戳" stamp_is "$OLD"

# ---- L 组：单实例锁 ----
# L1：真并发。第一个实例的 BIN 永久阻塞，等它进入 BIN 阶段（说明已持锁）后再起第二个
mkdir -p "$TMP/tmp_a" "$TMP/tmp_b"
set_stamp "$OLD"
new_log hang
FAKE_MODE=hang
START1=$SECONDS
HOME="$H" TMPDIR="$TMP/tmp_a" ICLOUD_GUARD_BUDGET="$BUDGET_T" /bin/bash "$GUARD" --sweep > "$TMP/out1" 2> "$TMP/err1" &
P1=$!
i=0
while [ ! -s "$FAKE_LOG" ] && [ "$i" -lt 40 ]; do
  sleep 0.2
  i=$((i + 1))
done
check "L1a 第一个实例已进入 BIN 阶段（前提）" [ -s "$FAKE_LOG" ]

RUN_TMPDIR="$TMP/tmp_b"
run_guard
RUN_TMPDIR="$TMP"
check "L1b 并发的第二个实例（TMPDIR 不同）立刻退出（<=1s）" quick
check "L1c 第二个实例退出 0 且静默"          rc_zero_silent
check "L1d 第二个实例没有再调 BIN"           called_once

# T1：等第一个实例自己结束；它的 BIN 永久阻塞，必须被 deadline 杀掉
wait_bounded "$P1" "$START1"
RC1=$RC
ELAPSED1=$((SECONDS - START1))
check "T1a 阻塞的 BIN 被 deadline 杀掉，脚本自行退出（没挂住）" [ "$HUNG" = "0" ]
check "T1b 脚本总耗时不超预算（<= 预算+2s）"                  [ "$ELAPSED1" -le $((BUDGET_T + 2)) ]
check "T1c 退出 0（advisory，不阻断 hook）"                   [ "$RC1" = "0" ]
check "T1d 超时在 stderr 留一行说明"                          grep -qF "icloud-exclude 超时" "$TMP/err1"
check "T1e 超时说明带「已中止」「不完整」"                    grep -qF "已中止，本轮结果不完整" "$TMP/err1"
check "T1h 超时 stderr 只有一行（不夹带 bash 自己的 Alarm clock 提示）" [ "$(wc -l < "$TMP/err1" | tr -d ' ')" = "1" ]
check "T1f 阻塞的 BIN 没有留下孤儿进程"                       no_orphan
check "T1g 超时退出后锁已释放"                                lock_released
check "T1i 超时的 sweep（BIN 被杀）不更新时间戳"              stamp_is "$OLD"

# L2：残锁。持锁进程已死（SIGKILL 的遗留）→ 必须接管而不是永久卡死。
# shlock 的两个实测特性（2026-10-06）：① 锁文件太新（< ~2s）时它报 "lock time changed" 并拒绝接管，
# 所以这里要先让残锁老化；② 手写的锁文件（哪怕 mtime 改老）同样被拒，残锁必须由 shlock 自己造
sleep 0.1 &
DEAD=$!
wait "$DEAD"
/usr/bin/shlock -f "$LOCK" -p "$DEAD"
sleep 2
new_log l2
FAKE_MODE=quiet run_guard
check "L2a 持锁进程已死 -> 接管并正常执行" called_once
check "L2b 接管后锁已释放"                 lock_released

# ---- T 组（续）：find 阻塞 + 半截路径 ----
# 假 find 吐「完整路径 + 半截路径」后阻塞。预期：find 在 FIND_LIMIT(3s) 被杀；
# 只有完整路径交给 BIN；第二个根因预算已尽被跳过；BIN 仍拿到剩余预算落地
new_log t2
RUN_PATH="$TMP/shim:$PATH"
SHIM_FULL="$H/Desktop/proj/node_modules"
SHIM_PART="$H/Desktop/pro"
export SHIM_FULL SHIM_PART
set_stamp "$OLD"
FAKE_MODE=quiet run_guard --sweep
RUN_PATH="$PATH"
check "T2a find 阻塞被杀，stderr 报超时"           err_has "超时 3s，已中止，本轮结果不完整"
check "T2b 第二个根预算已尽 -> 跳过并说明"         err_has "已用尽，跳过 find"
check "T2c 退出 0 且不超预算"                      ok_in_budget
check "T2d 阻塞的 find 没有留下孤儿进程"           no_orphan
check "T2e 部分结果照常落地：BIN 只拿到完整路径"   [ "$(logged_args)" = "$SHIM_FULL" ]
check "T2f 半截路径没有被当成目标"                 partial_path_not_target
check "T2h stderr 恰好两行（超时 + 跳过），不夹带 bash 自己的 Alarm clock 提示" [ "$(wc -l < "$ERR" | tr -d ' ')" = "2" ]
check "T2g 超时退出后锁已释放"                     lock_released
check "T2i 残缺的 sweep（find 被杀 + 预算跳过）不更新时间戳" stamp_is "$OLD"

# T3：--dry-run 的 --status 调用同样要有 deadline
new_log t3
FAKE_MODE=hang run_guard --dry-run
check "T3a --status 阻塞被杀并报超时"   err_has "icloud-exclude --status 超时"
check "T3b --dry-run 超时后仍输出汇总"  out_has "扫到 3 个目录"
check "T3c --dry-run 不超预算且退出 0"  ok_in_budget
check "T3d --status 没有留下孤儿进程"   no_orphan

# ---- S 组：默认总预算 ----
DEFAULT_BUDGET=$(sed -n 's/^BUDGET=\${ICLOUD_GUARD_BUDGET:-\([0-9]*\)}.*/\1/p' "$GUARD")
default_budget_ok() { [ -n "$DEFAULT_BUDGET" ] && [ "$DEFAULT_BUDGET" -lt 70 ]; }
check "S1 默认总预算 < 70s（hook 的 timeout）[当前 ${DEFAULT_BUDGET:-?}s]" default_budget_ok

echo "PASS $pass / FAIL $fail"
[ "$fail" -eq 0 ]
