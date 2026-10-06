#!/usr/bin/env bash
# iCloud 同步守卫 —— 扫 ~/Desktop 与 ~/Documents 下所有「构建产物 / 依赖目录」，
# 把还在 iCloud 同步域里的批量标记为不同步。advisory：没发现漂移就完全静默。
#
# 为什么需要它：开着「桌面与文稿」同步时，这两个目录下的一切都会被 iCloud 逐份上传并在
# 本地保留完整副本（等于每个大文件占双份）。而 isExcludedFromSync 是「目录自身的属性，
# 不随重建继承」——每次 rm -rf .next、npm ci 重建 node_modules，排除属性就跟着没了，
# 目录悄悄掉回同步域。2026-09-01 实测过这条：删掉 .next 后属性确实丢失。
#
# 为什么是全局巡检而不是逐项目挂 postinstall / check_all.sh：
#   · postinstall 只在 npm i 后触发，完全不覆盖 .next（.next 是 dev/build 时建的）
#   · check_all.sh 在 commit 前才跑，那时 .next 已经在同步域里躺了几小时
#   · 两者都要写进 package.json，会跟着 git 走到别人机器上——而这是本机开着 iCloud 才有的问题
#   · ~/Desktop 下有 7 个项目都有同样问题，逐项目配置是 7 份重复，还漏掉以后新建的
#
# 绝不能挂住或堆积（2026-10-06 实测）：「优化 Mac 储存空间」下很多项是 dataless 云端占位符，
# 对 dataless 目录 readdir 会强制 iCloud 下载，负载高时无限期阻塞在 fileproviderd 上；
# 而 hook 配的 async+timeout 20 实际不生效，每个会话的 SessionStart 都留下一个活 5-14 分钟的实例。
# 所以：单实例锁 + 每个可能阻塞的外部命令都带硬 deadline + 全程总预算（都由脚本自己执行）。
#
# 为什么有 --sweep：Desktop 全量扫描实测 11-13s（负载低）~ 50s（负载高，2026-10-06），每开一个会话
# 就全扫一遍纯属浪费。SessionStart 走 --sweep（6 小时内完整扫过就静默退出）；PostToolUse
# （rm .next / npm install 之后）不带参数、永远扫——那正是属性刚被自己弄丢的时刻，不能被限频挡掉。
#
# 用法：
#   bash icloud_sync_guard.sh            # 修复漂移（有发现才输出），总是扫
#   bash icloud_sync_guard.sh --sweep    # 同上，但距上次「完整」扫描不足 6 小时就静默退出
#   bash icloud_sync_guard.sh --dry-run  # 只报告，不改（可与 --sweep 同用；dry-run 不写时间戳）
set -uo pipefail

BIN="$HOME/.local/bin/icloud-exclude"
DRY=0
SWEEP=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --sweep) SWEEP=1 ;;
  esac
done

[ -x "$BIN" ] || { echo "[icloud-guard] 缺少 ${BIN}（用 swiftc -O 从 colar-agents/scripts/icloud_exclude.swift 编译）" >&2; exit 1; }

# 锁和时间戳放进固定的每用户目录，不放 TMPDIR：实测（2026-10-06）Claude Code 的 Bash 环境里 TMPDIR 是
# /var/folders/.../T/，干净的登录 shell 里 TMPDIR 为空（回落到 /tmp）——入口不同就各持一把锁，互相挡不住
CACHE_DIR="$HOME/Library/Caches/icloud_sync_guard"
STAMP="$CACHE_DIR/last_sweep"
LOCK="$CACHE_DIR/lock"
INCOMPLETE="$CACHE_DIR/incomplete"
SWEEP_INTERVAL=21600 # 6 小时

# stamp 缺失或内容不是数字都当作「没扫过」：否则一个坏文件会让算术报错、sweep 永远走不到更新 stamp 那步
sweep_is_fresh() {
  local last=0
  [ -r "$STAMP" ] && read -r last < "$STAMP"
  case "$last" in '' | *[!0-9]*) return 1 ;; esac
  [ $(($(date +%s) - last)) -lt "$SWEEP_INTERVAL" ]
}
# 在拿锁、扫描之前就退：限频内的 SessionStart 几乎零成本
if [ "$SWEEP" = "1" ] && sweep_is_fresh; then
  exit 0
fi

# 单实例：已有活实例就静默退出。shlock 在锁文件里记 PID，持锁进程已死时会接管（SIGKILL 留下的残锁不会永久卡死）
mkdir -p "$CACHE_DIR"
/usr/bin/shlock -f "$LOCK" -p $$ || exit 0
trap 'rm -f "$LOCK" "$INCOMPLETE"' EXIT
rm -f "$INCOMPLETE" # 已持锁；清掉上一个被 SIGKILL 的实例留下的旗标

# 总预算由脚本自己执行：hook 是 async，本来就不会阻塞会话；真正防堆积的是上面的单实例锁 + 每个外部命令的
# 硬 deadline。hook 的 timeout 配成 70（> 预算），是防 Claude Code 哪天开始真正执行 timeout，
# 把脚本砍在 apply 半路。ICLOUD_GUARD_BUDGET 只为让测试不必真等 60s。
BUDGET=${ICLOUD_GUARD_BUDGET:-60}
# find 阶段最多占 3/4：它慢到吃光预算时，已收集到的部分 targets 仍要留时间交给 BIN 落地（操作幂等）
FIND_LIMIT=$((BUDGET * 3 / 4))
SECONDS=0

# 在「脚本启动后第 limit 秒」之前跑完命令，否则杀掉；超时或预算已尽都返回 124，并立起 INCOMPLETE 旗标。
# 旗标用文件而不是变量：这里常在 $() / 进程替换的子 shell 里跑，变量传不回主 shell。
# 用 perl 的 alarm + exec，而不是脚本层的 alarm / watchdog：alarm 定时器跨 exec 保留，
# SIGALRM 直接打在被阻塞的那个进程本身；脚本层 watchdog 只杀得掉 bash，把阻塞的子进程留成孤儿
# （正是 2026-10-06 观察到的泄漏）。也不能 kill 进程组：hook 可能和 Claude Code 共用同一个进程组。
# 子进程 stderr 在此统一丢弃（find 遍历无权限目录的噪音、BIN 的既有行为）；
# 外层花括号是为了连 bash 自己打印的 "Alarm clock: 14" 一并压掉。
run_bounded() {
  local limit=$1 label=$2
  shift 2
  local left=$((limit - SECONDS))
  if [ "$left" -lt 1 ]; then
    echo "[icloud-guard] 总预算 ${BUDGET}s 已用尽，跳过 ${label}，本轮结果不完整" >&2
    : > "$INCOMPLETE"
    return 124
  fi
  local rc=0
  { /usr/bin/perl -e 'alarm shift; exec @ARGV or die "exec $ARGV[0]: $!\n"' "$left" "$@"; } 2>/dev/null || rc=$?
  if [ "$rc" -eq 142 ]; then # 128 + SIGALRM(14)
    echo "[icloud-guard] ${label} 超时 ${left}s，已中止，本轮结果不完整" >&2
    : > "$INCOMPLETE"
    return 124
  fi
  return "$rc"
}

# 只收「可重建的构建产物 / 依赖目录」。刻意不含 dist/ 与 build/——那两个名字在有些项目里
# 是源码或需要留存的产物，误排除会让它们失去 iCloud 备份而无声无息。
NAMES=(node_modules .next __pycache__ .venv .turbo .pytest_cache .mypy_cache .ruff_cache)

expr_args=()
for i in "${!NAMES[@]}"; do
  [ "$i" -gt 0 ] && expr_args+=(-o)
  expr_args+=(-name "${NAMES[$i]}")
done

# 冷存档目录整棵跳过：里面大量是 dataless 占位符，find 一进去就会阻塞在 fileproviderd 上等下载
# （2026-10-06 实测：卡在 artifacts/.../build-venv 里 14 分钟，SessionStart 每开一个会话就堆一份）。
COLD_ARCHIVE="$HOME/Desktop/创业/artifacts"

targets=()
for root in "$HOME/Desktop" "$HOME/Documents"; do
  [ -d "$root" ] || continue
  # -flags +dataless -prune：dataless 目录没有本地内容、无可排除，且 readdir 它就是阻塞源，不能下去
  # -prune（node_modules 那段）：命中即不再深入（node_modules 里往往还嵌着 node_modules），既提速又避免重复设置
  # -print0 + read -d ''：find 被超时杀掉时，输出末尾可能截断出半截路径；没有结尾 NUL 的残记录 read 会丢弃。
  #   否则半截路径恰好是个真目录（比如某个项目根）时，会把整个项目误排除出同步
  while IFS= read -r -d '' d; do
    targets+=("$d")
  done < <(run_bounded "$FIND_LIMIT" "find $root" find "$root" \
    -path "$COLD_ARCHIVE" -prune -o -flags +dataless -prune -o \
    -type d \( "${expr_args[@]}" \) -prune -print0)
done

if [ "${#targets[@]}" -gt 0 ]; then
  if [ "$DRY" = "1" ]; then
    status_out=$(run_bounded "$BUDGET" "icloud-exclude --status" "$BIN" --status "${targets[@]}")
    pending=$(printf '%s\n' "$status_out" | grep -c "^同步中" || true)
    echo "[icloud-guard] 扫到 ${#targets[@]} 个目录，其中 ${pending:-0} 个仍在同步域"
    printf '%s\n' "$status_out" | grep "^同步中" || true
  else
    # 二进制对「原本已排除」的静默，所以这里的输出天然等于本次新修复的条目
    out=$(run_bounded "$BUDGET" "icloud-exclude" "$BIN" "${targets[@]}")
    if [ -n "$out" ]; then
      n=$(printf '%s\n' "$out" | grep -c "已排除" || true)
      echo "[icloud-guard] 修复 ${n} 个掉回 iCloud 同步域的目录（共扫 ${#targets[@]} 个）:"
      printf '%s\n' "$out" | sed 's/^/  /'
    fi
  fi
fi

# 只有「完整跑完」（没有任何超时 / 预算用尽跳过）才记时间戳：残缺的 sweep 下个会话要重来，不能被限频挡掉。
# dry-run 只报告、不动状态
if [ "$SWEEP" = "1" ] && [ "$DRY" = "0" ] && [ ! -e "$INCOMPLETE" ]; then
  date +%s > "$STAMP"
fi
