#!/usr/bin/env bash
# scripts/wt 的「wt done」契约自证（常驻线级树做完一个任务：确认分支已合入 → 树停到最新主干 → 删分支）：
#   OK  分支已经 merge commit 合进 origin/main → exit 0、树 detached 在 fetch 后的 origin/main、本地分支删掉、
#       树本身还在、提示 switch -c、提示 origin/<分支> 还在
#   OK2 下一个任务照提示 switch -c → 新分支不跟踪上游
#   LO  从没推过分支、但 tip 已快进进 main → exit 0、分支删掉
#   NM  没合入 → exit 2、分支与树都不动
#   RA  本地 tip 已合入、origin/<分支> 合并后又多了提交 → exit 2、分支与树都不动
#   NV  git branch -d 不肯删（上游 origin/<分支> 落后于 tip）→ 不升级成 -D：exit 1、分支还在
#   DT  树里有未提交内容 → exit 2；DE detached 树 → exit 2
#   FF  fetch 失败 → exit 1、什么都不动
#   MN  主工作树 → exit 2；NR 不是本仓登记的目录 → exit 2；U1 不给参数 → exit 1
#
# 跑法：bash scripts/hooks/tests/test_wt_done.sh
# 变异验证：WT=<改坏一条规则的副本> bash 本脚本 → 对应用例必须转红，否则该用例没有判别力。
#
# 隔离（同 test_wt_new_branch_base.sh）：剥掉 GIT_DIR 一类变量；GIT_CONFIG_GLOBAL=/dev/null + GIT_CONFIG_NOSYSTEM=1；
# 「远端」是 mktemp 下的 bare 仓；WT_HOME 指向临时目录；结尾校验本仓 .git/config 前后字节一致。
# 判断退出码一律不走管道。
set -u
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=wt-test GIT_AUTHOR_EMAIL=wt-test@localhost GIT_COMMITTER_NAME=wt-test GIT_COMMITTER_EMAIL=wt-test@localhost

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

commit() { git -C "$1" commit -q --allow-empty -m "$2"; }
tip()    { git -C "$1" rev-parse HEAD 2>/dev/null; }
has_branch() { git -C "$LOCAL" show-ref --verify --quiet "refs/heads/$1"; }
on_branch()  { [ "$(git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null)" = "$2" ]; }

# ---- 远端 + seed（代表 GitHub 上合 PR 的那一方）+ 本地克隆 ----
REMOTE="$TMP/remote.git"
SEED="$TMP/seed"
LOCAL="$TMP/local"
git init -q --bare -b main "$REMOTE"
git init -q -b main "$SEED"
commit "$SEED" main-1
git -C "$SEED" remote add origin "$REMOTE"
git -C "$SEED" push -q origin main
git clone -q "$REMOTE" "$LOCAL"

# 在远端把 origin/<分支> 用 merge commit 合进 main（PR 的合法合并方式）
merge_to_main() {
  git -C "$SEED" fetch -q origin
  git -C "$SEED" merge -q --no-ff -m "Merge $1" "origin/$1"
  git -C "$SEED" push -q origin main
}

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
  echo "   stdout: $(LC_ALL=C tr '\n' '|' < "$OUT")"
  echo "   stderr: $(LC_ALL=C tr '\n' '|' < "$ERR")"
}
mk() { run_wt "$LOCAL" new "$@"; [ "$RC" = 0 ] || bad "setup: wt new $*"; }

# ---- OK：已合入 ----
mk t1 --branch feat/a
T=$WT_HOME/local-t1
commit "$T" a-1
git -C "$T" push -q -u origin feat/a
merge_to_main feat/a
MAIN_TIP=$(git -C "$REMOTE" rev-parse main)
run_wt "$LOCAL" done t1
if [ "$RC" = 0 ] && [ -d "$T" ] && ! git -C "$T" symbolic-ref --quiet HEAD >/dev/null 2>&1 \
   && [ "$(tip "$T")" = "$MAIN_TIP" ] && ! has_branch feat/a \
   && grep -qF 'switch -c' "$OUT" && grep -qF 'origin/feat/a 还在' "$OUT"; then ok
else bad "OK 已合入 → exit 0、树 detached 在最新 origin/main、本地分支删掉、树还在、提示 switch -c 与远端分支还在"; fi
git -C "$T" switch -q -c feat/next
if ! git -C "$T" rev-parse --verify --quiet 'feat/next@{upstream}' >/dev/null 2>&1; then ok
else bad "OK2 照提示 switch -c 切出的新分支不跟踪上游"; fi

# ---- LO：从没推过、tip 已快进进 main ----
mk t2 --branch feat/lo
T=$WT_HOME/local-t2
commit "$T" lo-1
git -C "$T" push -q origin HEAD:main
run_wt "$LOCAL" done t2
if [ "$RC" = 0 ] && ! has_branch feat/lo && [ "$(tip "$T")" = "$(git -C "$REMOTE" rev-parse main)" ]; then ok
else bad "LO 没有 origin/<分支>、tip 已在 main 里 → exit 0、分支删掉"; fi

# ---- NM：没合入 ----
mk t3 --branch feat/nm
T=$WT_HOME/local-t3
commit "$T" nm-1
git -C "$T" push -q -u origin feat/nm
run_wt "$LOCAL" done t3
if [ "$RC" = 2 ] && has_branch feat/nm && on_branch "$T" feat/nm && grep -qF '还不是' "$ERR"; then ok
else bad "NM 没合入 → exit 2、分支与树都不动"; fi

# ---- RA：本地已合入，但 origin/<分支> 合并后又多了提交 ----
mk t4 --branch feat/ra
T=$WT_HOME/local-t4
commit "$T" ra-1
git -C "$T" push -q -u origin feat/ra
merge_to_main feat/ra
git -C "$SEED" switch -q -c feat/ra origin/feat/ra
commit "$SEED" ra-after-merge
git -C "$SEED" push -q origin feat/ra
git -C "$SEED" switch -q main
run_wt "$LOCAL" done t4
if [ "$RC" = 2 ] && has_branch feat/ra && on_branch "$T" feat/ra && grep -qF 'origin/feat/ra' "$ERR"; then ok
else bad "RA origin/<分支> 上有没合进 main 的提交 → exit 2、分支与树都不动"; fi

# ---- NV：git branch -d 不肯删时不升级成 -D ----
# 上游 origin/feat/nv 停在 nv-1；本地再提交 nv-2 并直接快进进 main：tip 与 origin/feat/nv 都是 main 的祖先，
# 但 -d 按上游判「没合完」而拒绝 —— wt done 必须如实停下，而不是改用 -D
mk t5 --branch feat/nv
T=$WT_HOME/local-t5
commit "$T" nv-1
git -C "$T" push -q -u origin feat/nv
commit "$T" nv-2
git -C "$T" push -q origin HEAD:main
run_wt "$LOCAL" done t5
if [ "$RC" = 1 ] && has_branch feat/nv && grep -qF '绝不 -D' "$ERR"; then ok
else bad "NV git branch -d 被拒 → exit 1、分支还在（绝不 -D）"; fi

# ---- DT / DE：脏树、detached ----
mk t6 --branch feat/dt
T=$WT_HOME/local-t6
echo wip > "$T/wip.txt"
run_wt "$LOCAL" done t6
if [ "$RC" = 2 ] && has_branch feat/dt && [ -f "$T/wip.txt" ] && grep -qF '未提交' "$ERR"; then ok
else bad "DT 树里有未提交内容 → exit 2、什么都不动"; fi
mk t7
run_wt "$LOCAL" done t7
if [ "$RC" = 2 ] && grep -qF 'detached' "$ERR"; then ok; else bad "DE detached 树 → exit 2"; fi

# ---- FF：fetch 失败 ----
DEAD="$TMP/dead"
git clone -q "$REMOTE" "$DEAD"
run_wt "$DEAD" new t8 --branch feat/ff
T=$WT_HOME/dead-t8
commit "$T" ff-1
git -C "$T" push -q origin HEAD:main          # 已合入：只有 fetch 失败这一个拒绝理由
git -C "$DEAD" remote set-url origin "$TMP/no-such-remote.git"
run_wt "$DEAD" done t8
if [ "$RC" = 1 ] && git -C "$DEAD" show-ref --verify --quiet refs/heads/feat/ff && on_branch "$T" feat/ff \
   && grep -qF 'fetch origin 失败' "$ERR"; then ok
else bad "FF fetch 失败 → exit 1、分支与树都不动"; fi

# ---- MN / NR / U1 ----
run_wt "$LOCAL" done "$LOCAL"
if [ "$RC" = 2 ]; then ok; else bad "MN 主工作树 → exit 2"; fi
mkdir -p "$TMP/plain"
run_wt "$LOCAL" done "$TMP/plain"
if [ "$RC" = 2 ]; then ok; else bad "NR 不是本仓登记的目录 → exit 2"; fi
run_wt "$LOCAL" done
if [ "$RC" = 1 ]; then ok; else bad "U1 不给参数 → exit 1"; fi

# ---- 隔离自证：本仓真实 config 没被测试碰过 ----
if [ "$(shasum "$SELF_REPO_CONFIG" 2>/dev/null)" = "$SELF_SUM_BEFORE" ]; then ok; else
  fail=$((fail + 1)); echo "FAIL ISO 本仓 $SELF_REPO_CONFIG 在测试期间被改动 —— 隔离失效，立刻人工检查"; fi

echo "PASS $pass / FAIL $fail"
[ "$fail" -eq 0 ]
