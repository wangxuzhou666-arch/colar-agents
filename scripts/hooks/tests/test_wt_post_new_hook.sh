#!/usr/bin/env bash
# scripts/wt 的「仓库级 post-new 钩子」契约自证：
#   H1 新树里有 scripts/wt-post-new.sh → 调用恰好一次，$1=主仓根、$2=新树路径（都是 realpath），cwd=新树
#   H2 钩子 exit 1 → wt new 仍 exit 0，stderr 有带退出码的警告，树保留不拆
#   H3 --no-hook → 不调用
#   H4 --no-env 与钩子独立 → 照常调用
#   H5 新树里没有钩子 → 静默跳过，不提「跑仓库钩子」
#   H6 调用方漏进来绝对 GIT_DIR（2026-10-06 织锦事故形态）→ 钩子进程里 GIT_DIR 已被剥掉
#
# 跑法：bash scripts/hooks/tests/test_wt_post_new_hook.sh
# 变异验证：WT=<改坏一条规则的副本> bash 本脚本 → 对应用例必须转红，否则该用例没有判别力。
#
# 隔离（本测试要防的正是「测试里起的 git 打到真仓库」）：
#   - 开头剥掉 GIT_DIR / GIT_INDEX_FILE / GIT_WORK_TREE / GIT_COMMON_DIR，所有仓库都在 mktemp 目录里 git init
#   - GIT_CONFIG_GLOBAL=/dev/null + GIT_CONFIG_NOSYSTEM=1：Colar 的全局 hooksPath / 模板不在临时仓里触发
#   - WT_HOME 指向临时目录，不碰真实 ~/.wt
#   - 结尾校验本仓 .git/config 前后字节一致，被污染就整体判红
# 写法上的注意：判断退出码一律不走管道（管道后取 $? 既脆也会被 bash_pitfall_guard 拦）。
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
TMP=$(cd "$TMP" && pwd -P)   # macOS 的 /var → /private/var；wt 内部全用 realpath，期望值也得是
export WT_HOME="$TMP/wt-home"
OUT="$TMP/.stdout.txt"
ERR="$TMP/.stderr.txt"

# 造一个带钩子的临时仓：钩子把参数 / cwd / GIT_DIR 追加写进 $HOOK_LOG（落在树外，不弄脏 worktree）
REPO="$TMP/repo"
git init -q "$REPO"
mkdir -p "$REPO/scripts"
cat > "$REPO/scripts/wt-post-new.sh" <<'HOOK'
#!/usr/bin/env bash
printf 'root=%s\npath=%s\npwd=%s\ngit_dir=%s\n' "$1" "$2" "$(pwd -P)" "${GIT_DIR-unset}" >> "$HOOK_LOG"
exit "${HOOK_EXIT:-0}"
HOOK
git -C "$REPO" add scripts/wt-post-new.sh
git -C "$REPO" -c user.name=wt-test -c user.email=wt-test@localhost commit -q -m init

# 对照仓：没有钩子
BARE_REPO="$TMP/repo-nohook"
git init -q "$BARE_REPO"
git -C "$BARE_REPO" -c user.name=wt-test -c user.email=wt-test@localhost commit -q --allow-empty -m init

RC=0
# $1 仓库目录，其余是 wt 参数；子 shell 里 cd，结果落进全局 RC 与 OUT/ERR 文件
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
  [ -f "${HOOK_LOG:-/nonexistent}" ] && echo "   hook log: $(tr '\n' '|' < "$HOOK_LOG")"
}
calls() { if [ -f "$HOOK_LOG" ]; then grep -c '^root=' "$HOOK_LOG"; else echo 0; fi; }

# ---- H1：有钩子 → 恰好一次，参数与 cwd 正确 ----
export HOOK_LOG="$TMP/h1.log" HOOK_EXIT=0
run_wt "$REPO" new h1
want_path="$WT_HOME/repo-h1"
if [ "$RC" = 0 ] && [ "$(calls)" = 1 ] \
   && grep -qxF "root=$REPO" "$HOOK_LOG" \
   && grep -qxF "path=$want_path" "$HOOK_LOG" \
   && grep -qxF "pwd=$want_path" "$HOOK_LOG"; then ok; else bad "H1 有钩子 → 调用一次且 \$1=主仓根 \$2=新树 cwd=新树"; fi
# 钩子先于「就绪」：就绪行必须出现在「跑仓库钩子」之后
hook_line=$(grep -n '跑仓库钩子' "$OUT" | head -1 | cut -d: -f1)
ready_line=$(grep -n '就绪' "$OUT" | head -1 | cut -d: -f1)
if [ -n "$hook_line" ] && [ -n "$ready_line" ] && [ "$hook_line" -lt "$ready_line" ]; then ok; else bad "H1b 钩子在打印「就绪」之前执行"; fi

# ---- H2：钩子 exit 1 → wt 仍 0，警告带退出码，树保留 ----
export HOOK_LOG="$TMP/h2.log" HOOK_EXIT=1
run_wt "$REPO" new h2
if [ "$RC" = 0 ] && [ "$(calls)" = 1 ] && grep -q '警告' "$ERR" && grep -qF 'exit 1' "$ERR" \
   && [ -d "$WT_HOME/repo-h2" ]; then ok; else bad "H2 钩子失败 → wt new exit 0 + 警告含 exit 1 + 树保留"; fi

# ---- H3：--no-hook → 不调用 ----
export HOOK_LOG="$TMP/h3.log" HOOK_EXIT=0
run_wt "$REPO" new h3 --no-hook
if [ "$RC" = 0 ] && [ "$(calls)" = 0 ] && ! grep -q '跑仓库钩子' "$OUT"; then ok; else bad "H3 --no-hook → 钩子不被调用"; fi

# ---- H4：--no-env 不影响钩子 ----
export HOOK_LOG="$TMP/h4.log" HOOK_EXIT=0
run_wt "$REPO" new h4 --no-env
if [ "$RC" = 0 ] && [ "$(calls)" = 1 ]; then ok; else bad "H4 --no-env 与钩子独立 → 照常调用"; fi

# ---- H5：树里没有钩子 → 静默跳过 ----
export HOOK_LOG="$TMP/h5.log" HOOK_EXIT=0
run_wt "$BARE_REPO" new h5
if [ "$RC" = 0 ] && [ "$(calls)" = 0 ] && ! grep -q '跑仓库钩子' "$OUT"; then ok; else bad "H5 无钩子 → 不调用、不提示"; fi

# ---- H6：调用方带着绝对 GIT_DIR 进来 → 钩子里已剥掉 ----
export HOOK_LOG="$TMP/h6.log" HOOK_EXIT=0
RC=0
( cd "$REPO" && GIT_DIR="$REPO/.git" bash "$WT" new h6 ) > "$OUT" 2> "$ERR" || RC=$?
if [ "$RC" = 0 ] && [ "$(calls)" = 1 ] && grep -qxF 'git_dir=unset' "$HOOK_LOG"; then ok; else bad "H6 漏进来的 GIT_DIR 不继承给钩子"; fi

# ---- 用法报错文案带上 --no-hook ----
run_wt "$REPO" new --bogus
if [ "$RC" = 1 ] && grep -qF -- '--no-hook' "$ERR"; then ok; else bad "U1 未知参数报错列出 --no-hook"; fi

# ---- 隔离自证：本仓真实 config 没被测试碰过 ----
if [ "$(shasum "$SELF_REPO_CONFIG" 2>/dev/null)" = "$SELF_SUM_BEFORE" ]; then ok; else
  fail=$((fail + 1)); echo "FAIL ISO 本仓 $SELF_REPO_CONFIG 在测试期间被改动 —— 隔离失效，立刻人工检查"; fi

echo "PASS $pass / FAIL $fail"
[ "$fail" -eq 0 ]
