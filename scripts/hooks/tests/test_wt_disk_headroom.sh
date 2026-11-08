#!/usr/bin/env bash
# scripts/wt 的磁盘水位门自证：WT_HOME 所在卷剩余低于 WT_MIN_DISK_GB → wt new 拒绝（exit 2、不建树）；够 → 照常建。
#
# 跑法：bash scripts/hooks/tests/test_wt_disk_headroom.sh
# 变异验证：WT=<去掉 check_disk_headroom 调用的副本> bash 本脚本 →「水位不够时拒绝」两条转红。
# 隔离同 test_wt_post_new_hook.sh：剥 GIT_* 环境、全局配置指 /dev/null、仓库和 WT_HOME 都在 mktemp 目录里。
# 门槛用极端值（0 / 99999999）制造两种情形，不依赖本机真实剩余空间。
set -u
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WT=${WT:-$HERE/../../wt}
pass=0
fail=0
expect() {
  local label="$1"; shift
  if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $label"; fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)
export WT_HOME="$TMP/wt-home"
REPO="$TMP/repo"
git init -q "$REPO"
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

(cd "$REPO" && WT_MIN_DISK_GB=99999999 bash "$WT" new full --no-env --no-hook) >/dev/null 2>"$TMP/err"; rc=$?
expect "水位不够时拒绝（rc=${rc}）" [ "$rc" = 2 ]
expect "拒绝信息说明磁盘不足" grep -q "磁盘只剩" "$TMP/err"
expect "拒绝时不建树" [ ! -e "$WT_HOME/repo-full" ]

(cd "$REPO" && WT_MIN_DISK_GB=0 bash "$WT" new ok --no-env --no-hook) >/dev/null 2>&1; rc=$?
expect "水位够时照常建树（rc=${rc}）" [ "$rc" = 0 ]
expect "树建出来了" [ -e "$WT_HOME/repo-ok/.git" ]

echo "wt_disk_headroom: $pass 通过, $fail 失败"
[ "$fail" -eq 0 ]
