#!/usr/bin/env bash
# disk_watermark.sh 的判别力自证：够 → 零输出；低于提醒线 → ⚠；低于拒绝线 → ⛔；读数坏 → 静默。
# 跑法：bash scripts/hooks/tests/test_disk_watermark.sh
# 变异验证：HOOK=<把 -ge 改成 -gt 的副本> → 「正好等于提醒线不提醒」转红；去掉拒绝分支 →「低于拒绝线」转红。
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK=${HOOK:-$HERE/../disk_watermark.sh}
pass=0
fail=0
expect() {
  local label="$1"; shift
  if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $label"; fi
}
run() { DISK_WATERMARK_FAKE_GB="$1" DISK_WARN_GB=40 DISK_BLOCK_GB=20 bash "$HOOK" < /dev/null; }

expect "充足时零输出" [ -z "$(run 100)" ]
expect "正好等于提醒线不提醒" [ -z "$(run 40)" ]
out=$(run 39)
expect "低于提醒线提醒（${out}）" grep -q "⚠ 磁盘只剩 39G" <<< "$out"
out=$(run 19)
expect "低于拒绝线强提醒（${out}）" grep -q "⛔ 磁盘只剩 19G" <<< "$out"
expect "读数坏时静默" [ -z "$(run abc)" ]
DISK_WATERMARK_FAKE_GB=5 bash "$HOOK" < /dev/null >/dev/null; rc=$?
expect "任何情况都 exit 0（rc=${rc}）" [ "$rc" = 0 ]

echo "disk_watermark: $pass 通过, $fail 失败"
[ "$fail" -eq 0 ]
