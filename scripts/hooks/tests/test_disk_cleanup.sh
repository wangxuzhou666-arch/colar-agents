#!/usr/bin/env bash
# scripts/disk_cleanup.sh 的判别力自证：该删的删、不该删的一个不碰。
#
# 跑法：bash scripts/hooks/tests/test_disk_cleanup.sh
# 变异验证：CLEANUP=<改坏的副本> bash 本脚本。已验的变异：
#   is_stale 只看条目自身的 mtime（find -maxdepth 0）→「深处有新文件的旧目录保留」红；
#   窗口改回 find -mmin -N（把未来时间算「最近」）→「全旧的目录删掉」红；
#   pytest-of-* 不往下看一层、整个按条目判 →「旧的一轮删掉」红；去掉 [ ! -L "$tmp" ] →「tmp 是链接时不顺着删」红。
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLEANUP=${CLEANUP:-$HERE/../../disk_cleanup.sh}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0
fail=0
expect() {
  local label="$1"; shift
  if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $label"; fi
}

build() {
  rm -rf "${T:?}/root" "${T:?}/elsewhere"
  local R="$T/root" P="$T/root/a/tmp/pytest-of-colar"
  mkdir -p "$P/pytest-1/test_x0" "$P/pytest-2/test_y0" "$R/a/tmp/old-dir/deep" "$R/a/tmp/mixed-dir/deep" \
           "$R/a/other" "$T/elsewhere/victim"
  echo x > "$P/pytest-1/test_x0/f"; echo x > "$P/pytest-2/test_y0/f"
  echo x > "$R/a/tmp/old-dir/deep/f"; echo x > "$R/a/tmp/mixed-dir/deep/f"; echo x > "$R/a/tmp/mixed-dir/deep/new"
  echo x > "$R/a/tmp/old-dir/deep/future"; echo x > "$R/a/tmp/oldfile"; echo x > "$R/a/tmp/.hidden-old"; echo x > "$R/a/other/f"; echo x > "$T/elsewhere/victim/f"
  ln -s "$P/pytest-2" "$P/pytest-current"
  ln -s "$P/pytest-9" "$P/pytest-dangling"
  mkdir -p "$R/b"; ln -s "$T/elsewhere" "$R/b/tmp"
  # 先全部改旧，再把「新」的几个改回当下（目录 mtime 会被建子项刷新，所以最后统一改）
  find "$R" "$T/elsewhere" -exec touch -h -t 202601010000 {} +
  touch "$P/pytest-2/test_y0/f" "$R/a/tmp/mixed-dir/deep/new"
  touch -t 203304072333 "$R/a/tmp/old-dir/deep/future"   # 有的测试把 mtime 改到未来
}

run_cleanup() {
  ARTIFACTS_ROOT="$T/root" CLEAN_AGE_DAYS=2 DISK_CLEANUP_LOG="$T/log" DISK_CLEANUP_DOCKER=0 bash "$CLEANUP" "$@" >/dev/null 2>&1
}

R="$T/root"; P="$R/a/tmp/pytest-of-colar"

build
run_cleanup --dry-run
expect "dry-run 什么都不删" [ -e "$P/pytest-1" ] && [ -e "$R/a/tmp/oldfile" ] && [ -e "$R/a/tmp/old-dir" ]
expect "dry-run 也写日志" grep -q "dry-run" "$T/log"

build
run_cleanup; rc=$?
expect "正常退出（rc=${rc}）" [ "$rc" = 0 ]
expect "旧的一轮 pytest-1 删掉" [ ! -e "$P/pytest-1" ]
expect "新的一轮 pytest-2 保留" [ -e "$P/pytest-2/test_y0/f" ]
expect "有效的 pytest-current 保留" [ -L "$P/pytest-current" ]
expect "失效链接删掉" [ ! -L "$P/pytest-dangling" ]
expect "pytest-of-colar 本身保留" [ -d "$P" ]
expect "全旧的目录删掉（里面有未来时间的文件也照删）" [ ! -e "$R/a/tmp/old-dir" ]
expect "深处有新文件的旧目录保留" [ -e "$R/a/tmp/mixed-dir/deep/f" ]
expect "旧文件删掉" [ ! -e "$R/a/tmp/oldfile" ]
expect "旧的隐藏文件删掉" [ ! -e "$R/a/tmp/.hidden-old" ]
expect "tmp 以外的产物不碰" [ -e "$R/a/other/f" ]
expect "tmp 是链接时不顺着删" [ -e "$T/elsewhere/victim/f" ]
expect "日志有汇总" grep -q "删 " "$T/log"

ARTIFACTS_ROOT="$T/root" CLEAN_AGE_DAYS=abc DISK_CLEANUP_LOG="$T/log" DISK_CLEANUP_DOCKER=0 bash "$CLEANUP" >/dev/null 2>&1; rc=$?
expect "CLEAN_AGE_DAYS 不合法就退出（rc=${rc}）" [ "$rc" = 1 ]

echo "disk_cleanup: $pass 通过, $fail 失败"
[ "$fail" -eq 0 ]
