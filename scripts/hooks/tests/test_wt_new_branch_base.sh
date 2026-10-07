#!/usr/bin/env bash
# scripts/wt 的「wt new --branch 默认基」契约自证（织锦 R2：新分支只从 origin/main 切，不叠在别线未合并分支上）：
#   B1 --branch 且不给 ref → 新分支基于 origin 默认分支，且是 fetch 之后的最新提交（本地 origin/main 故意滞后）
#   B1b 打印一行实际用的 ref（「从 origin/main 切」）
#   B1c 新分支不跟踪上游（与旧行为「从本地 HEAD 切、无上游」一致）
#   B2 显式给 ref=HEAD → 照用，基于当前功能分支
#   B3 不带 --branch → detached 在 HEAD，不受新逻辑影响
#   B4 仓库没有 origin → 退回 HEAD，stderr 有警告
#   B5 origin/HEAD 缺失 → 依次试 origin/main
#   B6 fetch 失败 → 只警告，用本地已有的 origin/main（滞后的那个）
#
# 跑法：bash scripts/hooks/tests/test_wt_new_branch_base.sh
# 变异验证：WT=<改坏一条规则的副本> bash 本脚本 → 对应用例必须转红，否则该用例没有判别力。
#
# 隔离（同 test_wt_post_new_hook.sh）：剥掉 GIT_DIR 一类变量；GIT_CONFIG_GLOBAL=/dev/null + GIT_CONFIG_NOSYSTEM=1；
# 「远端」是 mktemp 下的 bare 仓；WT_HOME 指向临时目录；结尾校验本仓 .git/config 前后字节一致。
# 判断退出码一律不走管道。
set -u
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WT=${WT:-$HERE/../../wt}
SELF_REPO_CONFIG=$(cd "$HERE" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/config
SELF_SUM_BEFORE=$(shasum "$SELF_REPO_CONFIG" 2>/dev/null)
pass=0
fail=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)
export WT_HOME="$TMP/wt-home"
OUT="$TMP/.stdout.txt"
ERR="$TMP/.stderr.txt"

g()      { git -c user.name=t -c user.email=t@t "$@"; }
commit() { g -C "$1" commit -q --allow-empty -m "$2"; }
tip()    { git -C "$1" rev-parse HEAD 2>/dev/null; }

# ---- 造「远端」：bare 仓 + 一个 seed 克隆负责往 main 推 ----
REMOTE="$TMP/remote.git"
SEED="$TMP/seed"
git init -q --bare -b main "$REMOTE"
git init -q -b main "$SEED"
commit "$SEED" main-1
git -C "$SEED" remote add origin "$REMOTE"
git -C "$SEED" push -q origin main

# 本地克隆：HEAD 停在领先 main 的功能分支上
LOCAL="$TMP/local"
git clone -q "$REMOTE" "$LOCAL"
git -C "$LOCAL" checkout -q -b feature
commit "$LOCAL" feature-1
# B5 用：克隆后删掉 origin/HEAD
NOHEAD="$TMP/nohead"
git clone -q "$REMOTE" "$NOHEAD"
git -C "$NOHEAD" checkout -q -b feature
commit "$NOHEAD" feature-1
git -C "$NOHEAD" remote set-head origin -d
# B6 用：origin 指向不存在的路径，fetch 必失败，只剩本地已有的 origin/main
DEADREMOTE="$TMP/deadremote"
git clone -q "$REMOTE" "$DEADREMOTE"
git -C "$DEADREMOTE" checkout -q -b feature
commit "$DEADREMOTE" feature-1
git -C "$DEADREMOTE" remote set-url origin "$TMP/no-such-remote.git"
STALE_MAIN=$(git -C "$DEADREMOTE" rev-parse origin/main)

# 克隆之后远端 main 再前进一格 → 各克隆里的 origin/main 都滞后，只有 fetch 过才拿得到新提交
commit "$SEED" main-2
git -C "$SEED" push -q origin main
MAIN_TIP=$(git -C "$REMOTE" rev-parse main)
FEATURE_TIP=$(tip "$LOCAL")

# 无 origin 的仓：HEAD 同样停在功能分支上
NOORIGIN="$TMP/noorigin"
git init -q -b main "$NOORIGIN"
commit "$NOORIGIN" main-1
git -C "$NOORIGIN" checkout -q -b feature
commit "$NOORIGIN" feature-1
NOORIGIN_TIP=$(tip "$NOORIGIN")

RC=0
run_wt() {
  local repo=$1; shift
  RC=0
  ( cd "$repo" && bash "$WT" "$@" ) > "$OUT" 2> "$ERR" || RC=$?
}
ok()  { pass=$((pass + 1)); }
bad() {
  fail=$((fail + 1))
  echo "FAIL $1"
  echo "   rc=$RC"
  echo "   stdout: $(tr '\n' '|' < "$OUT")"
  echo "   stderr: $(tr '\n' '|' < "$ERR")"
}

# 前置自检：场景真的成立（功能分支领先 main、滞后的 origin/main 与远端 main 不同），否则下面的用例没有判别力
if [ "$FEATURE_TIP" != "$MAIN_TIP" ] && [ "$STALE_MAIN" != "$MAIN_TIP" ] \
   && [ "$(git -C "$LOCAL" rev-parse origin/main)" != "$MAIN_TIP" ]; then ok; else
  fail=$((fail + 1)); echo "FAIL PRE 场景搭建失败（feature/main/origin-main 没拉开）"; fi

# ---- B1：--branch 无 ref → 基于 fetch 后的 origin/main ----
run_wt "$LOCAL" new b1 --branch y1
W="$WT_HOME/local-b1"
if [ "$RC" = 0 ] && [ "$(tip "$W")" = "$MAIN_TIP" ] \
   && [ "$(git -C "$W" symbolic-ref --short HEAD 2>/dev/null)" = y1 ]; then ok; else
  bad "B1 --branch 无 ref → 新分支 y1 基于 fetch 后的 origin/main"; fi
if grep -qF '从 origin/main 切' "$OUT"; then ok; else bad "B1b 打印实际用的 ref（从 origin/main 切）"; fi
if ! git -C "$W" rev-parse --verify --quiet 'y1@{upstream}' >/dev/null 2>&1; then ok; else
  bad "B1c 新分支不跟踪上游"; fi

# ---- B2：显式 ref=HEAD → 照用 ----
run_wt "$LOCAL" new b2 HEAD --branch y2
if [ "$RC" = 0 ] && [ "$(tip "$WT_HOME/local-b2")" = "$FEATURE_TIP" ] \
   && ! grep -qF '未指定 ref' "$OUT"; then ok; else bad "B2 显式 ref HEAD → 基于功能分支"; fi

# ---- B3：无 --branch → detached 在 HEAD ----
run_wt "$LOCAL" new b3
W="$WT_HOME/local-b3"
if [ "$RC" = 0 ] && [ "$(tip "$W")" = "$FEATURE_TIP" ] \
   && ! git -C "$W" symbolic-ref --quiet HEAD >/dev/null 2>&1 \
   && ! grep -qF '未指定 ref' "$OUT"; then ok; else bad "B3 无 --branch → detached 在 HEAD"; fi

# ---- B4：无 origin → 退回 HEAD + 警告 ----
run_wt "$NOORIGIN" new b4 --branch y4
if [ "$RC" = 0 ] && [ "$(tip "$WT_HOME/noorigin-b4")" = "$NOORIGIN_TIP" ] \
   && grep -q '警告' "$ERR" && grep -qF 'origin' "$ERR"; then ok; else bad "B4 无 origin → 退回 HEAD 且 stderr 警告"; fi

# ---- B5：origin/HEAD 缺失 → 试 origin/main ----
run_wt "$NOHEAD" new b5 --branch y5
if [ "$RC" = 0 ] && [ "$(tip "$WT_HOME/nohead-b5")" = "$MAIN_TIP" ]; then ok; else
  bad "B5 origin/HEAD 缺失 → 回落到 origin/main"; fi

# ---- B6：fetch 失败 → 警告 + 用本地已有的 origin/main ----
run_wt "$DEADREMOTE" new b6 --branch y6
if [ "$RC" = 0 ] && [ "$(tip "$WT_HOME/deadremote-b6")" = "$STALE_MAIN" ] \
   && grep -qF 'fetch origin 失败' "$ERR"; then ok; else bad "B6 fetch 失败 → 只警告，用本地 origin/main"; fi

# ---- 隔离自证：本仓真实 config 没被测试碰过 ----
if [ "$(shasum "$SELF_REPO_CONFIG" 2>/dev/null)" = "$SELF_SUM_BEFORE" ]; then ok; else
  fail=$((fail + 1)); echo "FAIL ISO 本仓 $SELF_REPO_CONFIG 在测试期间被改动 —— 隔离失效，立刻人工检查"; fi

echo "PASS $pass / FAIL $fail"
[ "$fail" -eq 0 ]
