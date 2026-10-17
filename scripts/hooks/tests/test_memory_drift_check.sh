#!/usr/bin/env bash
# memory_drift_check.sh 的判别力自证（红/绿夹具）。脚本本身不是 hook，但由 Stop hook 驱动，
# 输出口径就是 hook 口径：有事 → "=== … ===" 段打到 stdout；没事 → 只有一行 "✓ memory drift clean"
# 被 hook 的 grep -v 吃掉 = 零输出。
#
# 覆盖：
#   L  [[ ]] 链接：未解析要报 · allowlist 里的不报 · allowlist 陈旧条目（已能解析 / 已无引用）要报 ·
#      跨类 [[feedback-foo]] 对 project_foo.md 要报（链接侧不剥前缀）而 [[foo]] / [[project-foo]] 不报
#   D  SOUL 日期戳：阈值之上报、阈值及以下不报；非法月份 / 嵌在文件名里的日期不计；紧贴中文的日期要计
#   E  单项检查出错只隔离该项：打 INTERNAL ERROR 段到 stdout，其余检查照跑，exit 仍 0
#   B  语料备份漂移（只读本地 git）：3 天前的未跟踪文件 / 3 天前的未推送提交要报，新鲜的不报，
#      没有 upstream / 不是 git 仓静默
#   K  干净夹具走 hook 同款管道后零输出
#
# 跑法：bash scripts/hooks/tests/test_memory_drift_check.sh
# 变异验证：SCRIPT=<改坏一条规则的副本> bash 本脚本 → 对应用例必须转红，否则该用例没有判别力。
#
# 隔离：所有生产路径都用 env 指到临时目录（MEMORY_DIR / SOUL_PATH / LANE_INDEX / SETTINGS_PATH /
#       AGENTS_DIR / SKILLS_DIR），LINK_ALLOWLIST 故意不设，顺带验证它默认落在 $MEMORY_DIR 下。
#       夹具 git 一律 -c 传配置（不写任何 config 文件），并关掉 hooks 与签名，免得被全局 hook 干扰。
set -u
unset LINK_ALLOWLIST DRIFT_CHECK_FAULT

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT=${SCRIPT:-$HERE/../../memory_drift_check.sh}
pass=0
fail=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/.out.txt"
EMPTY="$TMP/.empty"
mkdir -p "$EMPTY"
FIVE_DAYS_AGO=$(( $(date +%s) - 5 * 86400 ))

CORPUS=""
SOUL=""
# 新建一个最小但「干净」的语料：MEMORY.md 索引了 feedback_alpha.md；SOUL 无日期、无 bold 短语
new_corpus() {
  CORPUS="$TMP/$1"
  SOUL="$TMP/$1.soul.md"
  mkdir -p "$CORPUS"
  printf '# idx\n- feedback_alpha.md\n' > "$CORPUS/MEMORY.md"
  printf -- '---\nname: alpha\ndescription: fixture memory\n---\nbody\n' > "$CORPUS/feedback_alpha.md"
  printf '# soul\nplain axiom\n' > "$SOUL"
}

# 加一个 memory 文件并登记进索引：$1 文件名 · $2 正文
add_mem() {
  printf -- '---\nname: %s\ndescription: fixture\n---\n%s\n' "${1%.md}" "$2" > "$CORPUS/$1"
  printf -- '- %s\n' "$1" >> "$CORPUS/MEMORY.md"
}

# SOUL 写 N 行合法日期戳（每行一个）
soul_with_dates() {
  : > "$SOUL"
  i=1
  while [ "$i" -le "$1" ]; do
    printf 'rule %d (2026-0%d 拍板)\n' "$i" "$i" >> "$SOUL"
    i=$((i + 1))
  done
}

G() {
  git -C "$CORPUS" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c core.hooksPath=/dev/null -c commit.gpgsign=false "$@"
}
git_init() {
  git -c init.defaultBranch=main init -q "$CORPUS"
  G add -A
  G commit -q -m init
}
git_init_with_upstream() {
  git_init
  git -c init.defaultBranch=main init -q --bare "$CORPUS.up.git"
  G remote add origin "$CORPUS.up.git"
  G push -q -u origin main
}
commit_at() {
  # $1 epoch 秒：用该时间做 author/committer date 提交一次
  echo "change $1" >> "$CORPUS/feedback_alpha.md"
  G add -A
  GIT_AUTHOR_DATE="$1 +0000" GIT_COMMITTER_DATE="$1 +0000" G commit -q -m "change"
}
age_file() {
  python3 -c 'import os, sys; t = int(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$FIVE_DAYS_AGO"
}

RC=0
run_check() {
  RC=0
  MEMORY_DIR="$CORPUS" SOUL_PATH="$SOUL" LANE_INDEX="$EMPTY/none" SETTINGS_PATH="$EMPTY/none" \
    AGENTS_DIR="$EMPTY" SKILLS_DIR="$EMPTY" \
    bash "$SCRIPT" > "$OUT" 2>&1 || RC=$?
}

report_fail() {
  fail=$((fail + 1))
  echo "  ✗ $1  (rc=$RC) $2"
  sed 's/^/      | /' "$OUT"
}
expect_has() {
  # $1 标签 · $2 输出必含的固定片段
  if [ "$RC" = "0" ] && grep -qF -- "$2" "$OUT"; then
    pass=$((pass + 1)); echo "  ✓ $1"
  else
    report_fail "$1" "期望含: $2"
  fi
}
expect_lacks() {
  # $1 标签 · $2 输出不得含的固定片段
  if [ "$RC" = "0" ] && ! grep -qF -- "$2" "$OUT"; then
    pass=$((pass + 1)); echo "  ✓ $1"
  else
    report_fail "$1" "期望不含: $2"
  fi
}

echo "== L: [[ ]] 链接 + allowlist =="
new_corpus l1
add_mem feedback_beta.md 'see [[ghost-memory]]'
run_check
expect_has   "L1 未解析链接要报"                 "[[ghost-memory]]"

new_corpus l2
add_mem feedback_beta.md 'see [[ghost-memory]]'
printf '# header\nghost-memory\n' > "$CORPUS/memory-link-allowlist.txt"
run_check
expect_lacks "L2 allowlist 里的链接不报"         "[[ghost-memory]]"
expect_lacks "L2 被引用的 allowlist 条目不算陈旧"  "STALE ALLOWLIST"

new_corpus l3
add_mem feedback_beta.md 'see [[ghost-memory]] and [[alpha]]'
printf 'ghost-memory\nalpha\norphan-entry\n' > "$CORPUS/memory-link-allowlist.txt"
run_check
expect_has   "L3a allowlist 条目已能解析要报"     "alpha  — 已能解析"
expect_has   "L3b allowlist 条目已无引用要报"     "orphan-entry  — 已无任何"
expect_lacks "L3c 仍有效的 allowlist 条目不报"    "ghost-memory  —"

new_corpus l4
add_mem project_foo.md 'fixture'
add_mem feedback_beta.md 'x [[feedback-foo]] y [[foo]] z [[project-foo]] w [[project_foo]]'
run_check
expect_has   "L4a 跨类 [[feedback-foo]] 对 project_foo.md 要报" "[[feedback-foo]]"
expect_lacks "L4b 无前缀 [[foo]] 解析到 project_foo.md"          "[[foo]]"
expect_lacks "L4c 同类 [[project-foo]] 解析"                     "[[project-foo]]"
expect_lacks "L4d snake [[project_foo]] 解析"                     "[[project_foo]]"

new_corpus l5
add_mem feedback_beta.md 'see [[feedback-foo]]'
add_mem project_foo.md 'fixture'
printf 'foo\n' > "$CORPUS/memory-link-allowlist.txt"
run_check
expect_has   "L5 allowlist 不剥前缀：写 foo 不能放行 [[feedback-foo]]" "[[feedback-foo]]"

echo "== D: SOUL 日期戳 =="
new_corpus d1
soul_with_dates 6
run_check
expect_has   "D1 6 行 > 阈值 5 要报"              "SOUL DATE-STAMP CREEP"

new_corpus d2
soul_with_dates 5
run_check
expect_lacks "D2 5 行 = 阈值不报"                 "SOUL DATE-STAMP CREEP"

new_corpus d3
soul_with_dates 5
printf 'bad month 2026-13\nbad month 2026-00\nsee project_x_2026-08-10.md\n' >> "$SOUL"
run_check
expect_lacks "D3 非法月份 / 文件名内日期不计"      "SOUL DATE-STAMP CREEP"

new_corpus d4
soul_with_dates 5
printf '（2026-07审计）\n' >> "$SOUL"
run_check
expect_has   "D4 紧贴中文的日期要计"              "SOUL DATE-STAMP CREEP"

echo "== E: 单项出错隔离 =="
new_corpus e1
soul_with_dates 6
RC=0
MEMORY_DIR="$CORPUS" SOUL_PATH="$SOUL" LANE_INDEX="$EMPTY/none" SETTINGS_PATH="$EMPTY/none" \
  AGENTS_DIR="$EMPTY" SKILLS_DIR="$EMPTY" DRIFT_CHECK_FAULT=links \
  bash "$SCRIPT" > "$OUT" 2>/dev/null || RC=$?
expect_has   "E1 出错项打 INTERNAL ERROR 到 stdout" "=== INTERNAL ERROR in links ==="
expect_has   "E2 其余检查照跑"                    "SOUL DATE-STAMP CREEP"

echo "== B: 语料备份漂移（本地 git） =="
new_corpus b1
git_init_with_upstream
printf 'draft\n' > "$CORPUS/notes.txt"
age_file "$CORPUS/notes.txt"
run_check
expect_has   "B1 3 天前的未跟踪文件要报"          "notes.txt"

new_corpus b2
git_init_with_upstream
printf 'draft\n' > "$CORPUS/notes.txt"
run_check
expect_lacks "B2 新鲜的未跟踪文件不报"            "CORPUS BACKUP DRIFT"

new_corpus b3
git_init_with_upstream
commit_at "$FIVE_DAYS_AGO"
run_check
expect_has   "B3 3 天前的未推送提交要报"          "未推送提交 1 个"

new_corpus b4
git_init_with_upstream
commit_at "$(date +%s)"
run_check
expect_lacks "B4 新鲜的未推送提交不报"            "CORPUS BACKUP DRIFT"

new_corpus b5
git_init
commit_at "$FIVE_DAYS_AGO"
run_check
expect_lacks "B5 没有 upstream 静默"             "CORPUS BACKUP DRIFT"
expect_lacks "B5 没有 upstream 不算内部错误"      "INTERNAL ERROR"

new_corpus b6
printf 'draft\n' > "$CORPUS/notes.txt"
age_file "$CORPUS/notes.txt"
run_check
expect_lacks "B6 不是 git 仓静默"                "CORPUS BACKUP DRIFT"
expect_lacks "B6 不是 git 仓不算内部错误"         "INTERNAL ERROR"

echo "== K: 干净夹具 =="
new_corpus k1
add_mem feedback_beta.md 'see [[alpha]]'
git_init_with_upstream
run_check
expect_has   "K1 干净时只有 ✓ 行"                 "✓ memory drift clean"
expect_lacks "K2 干净时没有任何段"                "==="
# 按 Stop hook 的同款管道过滤后必须零输出
if [ "$RC" = "0" ] && [ -z "$(grep -v '^✓ memory drift clean' "$OUT")" ]; then
  pass=$((pass + 1)); echo "  ✓ K3 hook 管道过滤后零输出"
else
  report_fail "K3 hook 管道过滤后零输出" ""
fi

echo "PASS $pass / FAIL $fail"
[ "$fail" -eq 0 ]
