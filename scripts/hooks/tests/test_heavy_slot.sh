#!/usr/bin/env bash
# scripts/heavy_slot.py（全机重任务槽）的判别力自证。
#
# 跑法：bash scripts/hooks/tests/test_heavy_slot.sh
# 变异验证：SLOT=<改坏的副本> bash 本脚本 → 对应用例必须转红。已验的变异：
#   出队顺序改成按入队时间（不看优先级）→「部署门插队」红；live_tickets 不删死票 →「死票」红；
#   memory_refusal 恒返回 None →「内存压力」「空闲内存」各条红；run 不 set_inheritable（exec 时锁 fd 被关掉）→「A 占槽时 B 超时」红。
# 全部读数走 HEAVY_SLOT_FAKE_FILE，不看本机真实内存；槽目录在临时目录，不碰 ~/.cache/heavy-slot。
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SLOT=${SLOT:-$HERE/../../heavy_slot.py}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HEAVY_SLOT_DIR="$T/slot" HEAVY_POLL=0.1 HEAVY_REPORT=1000 HEAVY_SLOT_FAKE_FILE="$T/fake"
unset HEAVY_SLOT_HELD HEAVY_MEM_WAIT_MAX HEAVY_MIN_FREE_PCT HEAVY_MIN_DISK_GB HEAVY_QUEUE_TIMEOUT
pass=0
fail=0

expect() {  # expect <标签> <条件命令…>
  local label="$1"; shift
  if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $label"; fi
}
normal() { echo "1 50 2 100" > "$T/fake"; }
wait_file() {  # wait_file <路径>：最多等 5s
  local i
  for i in $(seq 50); do [ -e "$1" ] && return 0; sleep 0.1; done
  return 1
}
slot() { python3 "$SLOT" "$@"; }

# ── 1. run：exec 成目标命令，透传退出码，带 HEAVY_SLOT_HELD ──
normal
out=$(slot run --label t1 -- sh -c 'echo "held=$HEAVY_SLOT_HELD"; exit 3' 2>/dev/null); rc=$?
expect "run 透传退出码（rc=${rc}）" [ "$rc" = 3 ]
expect "run 设 HEAVY_SLOT_HELD（out=${out}）" [ "$out" = "held=t1" ]

# ── 2. 互斥：A 占着时 B 排队超时；A 结束后 B 拿到 ──
slot run --label A -- sh -c "touch '$T/a'; sleep 2" 2>/dev/null &
a_pid=$!
wait_file "$T/a"
err=$(slot run --label B --wait-max 0.5 -- true 2>&1); rc=$?
expect "A 占槽时 B 超时退 75（rc=${rc}）" [ "$rc" = 75 ]
expect "超时信息点名占槽者（${err}）" grep -q "A" <<< "$err"
out=$(HEAVY_SLOT_HELD=outer slot run --wait-max 0.5 -- sh -c 'echo reentrant' 2>/dev/null); rc=$?
expect "已在槽内（HEAVY_SLOT_HELD）的重入不排队（rc=$rc out=${out}）" [ "$rc" = 0 ] && [ "$out" = reentrant ]
status=$(slot status 2>&1)
expect "status 显示占槽者（${status}）" grep -q "占槽：A" <<< "$status"
err=$(slot run --label B --wait-max 0.5 --fail-exit 2 -- true 2>&1); rc=$?
expect "--fail-exit 生效（rc=${rc}）" [ "$rc" = 2 ]
wait "$a_pid"
slot run --label B --wait-max 3 -- true 2>/dev/null; rc=$?
expect "A 结束后 B 拿到槽（rc=${rc}）" [ "$rc" = 0 ]
status=$(slot status 2>&1)
expect "空闲时 status 说槽空闲（${status}）" grep -q "槽空闲" <<< "$status"

# ── 3. acquire 给 bash 用：shell 退出后，继承了 fd 的后台子进程仍占着槽 ──
rm -f "$T/c"
bash -c 'exec 7>>"$(python3 "$1" lockfile)"
python3 "$1" acquire --fd 7 --holder-pid $$ --label shell 2>/dev/null || exit 9
(touch "$2/c"; sleep 2) &
exit 0' _ "$SLOT" "$T"; rc=$?
expect "acquire 成功（rc=${rc}）" [ "$rc" = 0 ]
wait_file "$T/c"
slot run --label B --wait-max 0.5 -- true 2>/dev/null; rc=$?
expect "协调 shell 已退出、子进程还在跑时槽仍占着（rc=${rc}）" [ "$rc" = 75 ]
slot run --label B --wait-max 5 -- true 2>/dev/null; rc=$?
expect "子进程退出后槽自动释放（rc=${rc}）" [ "$rc" = 0 ]
bash -c 'python3 "$1" acquire --fd 7 --holder-pid $$ 2>/dev/null' _ "$SLOT"; rc=$?
expect "acquire 的 fd 没打开就拒绝（rc=${rc}）" [ "$rc" = 75 ]

# ── 4. 优先级：先入队的 adhoc 让后入队的 deploy 先出队 ──
: > "$T/order"
slot run --label A -- sh -c "touch '$T/a2'; sleep 1.5" 2>/dev/null &
a_pid=$!
wait_file "$T/a2"
slot run --priority adhoc --label C -- sh -c "echo C >> '$T/order'; sleep 0.3" 2>/dev/null &
c_pid=$!
sleep 0.4
slot run --priority deploy --label D -- sh -c "echo D >> '$T/order'; sleep 0.3" 2>/dev/null &
d_pid=$!
wait "$a_pid" "$c_pid" "$d_pid"
order=$(tr '\n' ' ' < "$T/order")
expect "部署门插队到 adhoc 前面（顺序：${order}）" [ "$order" = "D C " ]

# ── 5. 死票：主人已死（票上没锁）的票不挡路，并被清掉 ──
dead="$HEAVY_SLOT_DIR/queue/0-00000000000000000001-99999.json"
echo '{"label":"dead"}' > "$dead"
slot run --label E --wait-max 2 -- true 2>/dev/null; rc=$?
expect "死票不挡路（rc=${rc}）" [ "$rc" = 0 ]
expect "死票被清掉" [ ! -e "$dead" ]

# ── 6. 内存判据 ──
echo "2 50 2 100" > "$T/fake"
err=$(HEAVY_MEM_WAIT_MAX=0.3 slot run --wait-max 5 -- true 2>&1); rc=$?
expect "内存压力：等满上限照常放行（rc=${rc}）" [ "$rc" = 0 ]
expect "内存压力：放行时喊出来（${err}）" grep -q "照常放行" <<< "$err"
err=$(HEAVY_MEM_WAIT_MAX=100 slot run --wait-max 0.5 -- true 2>&1); rc=$?
expect "内存压力：没等满就排队超时（rc=${rc}）" [ "$rc" = 75 ]
expect "内存压力：超时原因是内存（${err}）" grep -q "内存压力等级 2" <<< "$err"
echo "1 10 2 100" > "$T/fake"
err=$(HEAVY_MEM_WAIT_MAX=100 slot run --wait-max 0.5 -- true 2>&1); rc=$?
expect "空闲内存不足时不放行（rc=${rc}）" [ "$rc" = 75 ]
expect "原因是空闲内存（${err}）" grep -q "空闲内存 10%" <<< "$err"
rm -f "$T/fake"
slot run --wait-max 2 -- true 2>/dev/null; rc=$?
expect "读数读不到时放行（fail-open，rc=${rc}）" [ "$rc" = 0 ]

# ── 7. 磁盘不足直接拒绝，不排队 ──
echo "1 50 2 5" > "$T/fake"
err=$(slot run --wait-max 30 -- true 2>&1); rc=$?
expect "磁盘不足退 75（rc=${rc}）" [ "$rc" = 75 ]
expect "原因是磁盘（${err}）" grep -q "磁盘只剩 5G" <<< "$err"

# ── 8. 旋钮不合法：边界处报错 ──
normal
err=$(HEAVY_POLL=abc slot run -- true 2>&1); rc=$?
expect "旋钮不合法退 75（rc=${rc}）" [ "$rc" = 75 ]
expect "点名旋钮（${err}）" grep -q "HEAVY_POLL" <<< "$err"

echo "heavy_slot: $pass 通过, $fail 失败"
[ "$fail" -eq 0 ]
