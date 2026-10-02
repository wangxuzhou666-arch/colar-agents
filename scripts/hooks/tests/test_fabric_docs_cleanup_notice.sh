#!/usr/bin/env bash
# fabric_docs_cleanup_notice.sh 的判别力自证:非织锦 cwd 必须全程静默,织锦 cwd 下
# pending.json/log.jsonl 的四种状态(有清单/空清单/缺失/过期)必须精确分流到输出或静默。
#
# 跑法：bash scripts/hooks/tests/test_fabric_docs_cleanup_notice.sh
#
# hook 源码把 REPO 写死成真实绝对路径（任务要求全部用绝对路径，不开环境变量后门）,
# 所以测试不直接跑磁盘上那份、也不碰真实仓库的 .claude/docs-archive——而是把源码 sed
# 替换一份"假仓库"副本到临时目录,路径里仍保留 "fabric-agent-demo" 字面量,
# 让 cwd 触发条件和归档读取路径用的是同一棵假树。
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK_SRC=${HOOK_SRC:-$HERE/../fabric_docs_cleanup_notice.sh}
pass=0
fail=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAKE_REPO="$TMP/Desktop/fabric-agent-demo"
mkdir -p "$FAKE_REPO/.claude/docs-archive"

HOOK="$TMP/hook_under_test.sh"
sed "s#/Users/colar/Desktop/创业/fabric-agent-demo#$FAKE_REPO#g" "$HOOK_SRC" > "$HOOK"
chmod +x "$HOOK"

ARCHIVE="$FAKE_REPO/.claude/docs-archive"

reset_archive() {
  rm -f "$ARCHIVE/pending.json" "$ARCHIVE/log.jsonl"
}

write_pending() {
  # $1 = items 的 JSON 数组文本,如 '[]' 或 '[{"path":"docs/x.html"}]'
  printf '{"generated_at":"2026-10-02T09:00:00+08:00","days":14,"items":%s,"command":""}' "$1" \
    > "$ARCHIVE/pending.json"
}

write_log_ts() {
  # $1 = ISO8601 时间戳,写一行最简 log.jsonl(字段形状对齐 docs_cleanup.py 的 append_log)
  printf '{"ts":"%s","days":14,"moved":[],"pending":[],"skipped_referenced":[],"skipped_too_new":[]}\n' "$1" \
    > "$ARCHIVE/log.jsonl"
}

iso_days_ago() {
  python3 -c '
import datetime, sys
d = datetime.datetime.now().astimezone() - datetime.timedelta(days=int(sys.argv[1]))
print(d.isoformat())
' "$1"
}

run_hook() {
  # $1 = cwd;把它包成 SessionStart 的 stdin JSON 喂给 hook
  python3 -c '
import json, sys
print(json.dumps({"cwd": sys.argv[1]}))
' "$1" | "$HOOK"
}

expect_silent() {
  local label="$1" cwd="$2" out rc
  out=$(run_hook "$cwd"); rc=$?
  if [ -z "$out" ] && [ "$rc" -eq 0 ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL[silent] $label"
    echo "   cwd: $cwd"
    echo "   got(rc=$rc): ${out:-<empty>}"
  fi
}

expect_output() {
  local label="$1" cwd="$2" needle="$3" out rc
  out=$(run_hook "$cwd"); rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF -- "$needle"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL[output] $label"
    echo "   cwd: $cwd"
    echo "   needle: $needle"
    echo "   got(rc=$rc): ${out:-<empty>}"
  fi
}

# ---- 非织锦 cwd：全程静默，哪怕归档里明明有非空 pending + 过期 log ----
reset_archive
write_pending '[{"path":"docs/x.html","kind":"A","age_days":30,"size_kb":1.2}]'
write_log_ts "$(iso_days_ago 20)"
expect_silent "非织锦项目 cwd 全静默" "/Users/colar/Desktop/some-other-project"

# ---- 有清单时输出：主仓 cwd + pending.json 非空 ----
reset_archive
write_pending '[{"path":"docs/x.html","kind":"A","age_days":30,"size_kb":1.2},{"path":"docs/y.html","kind":"B","age_days":40,"size_kb":2.0}]'
write_log_ts "$(iso_days_ago 1)"
expect_output "主仓 cwd + 非空 pending → 提示待确认"  "$FAKE_REPO" "docs-cleanup::hook-only"
expect_output "提示里含正确件数 2"                    "$FAKE_REPO" "2 个候选"
expect_output "提示里含清单路径"                      "$FAKE_REPO" "pending.json"

# ---- 清单为空时静默：pending.json 存在但 items 为空数组 ----
reset_archive
write_pending '[]'
write_log_ts "$(iso_days_ago 1)"
expect_silent "pending.json items 为空 → 静默" "$FAKE_REPO"

# ---- 文件缺失时静默：pending.json / log.jsonl 都不存在 ----
reset_archive
expect_silent "pending.json/log.jsonl 都缺失 → 静默" "$FAKE_REPO/frontend"

# ---- 超过 10 天未运行时告警：只有过期 log.jsonl，没有 pending.json ----
reset_archive
write_log_ts "$(iso_days_ago 15)"
expect_output "log.jsonl 15 天前 → 告警"   "$FAKE_REPO" "docs-cleanup::hook-only"
expect_output "告警里含天数"               "$FAKE_REPO" "天未运行"

# ---- 对照组：10 天内不告警 ----
reset_archive
write_log_ts "$(iso_days_ago 3)"
expect_silent "log.jsonl 3 天前，没超阈值 → 静默" "$FAKE_REPO"

# ---- /.wt/fabric- 工作树 cwd 也应触发（不依赖 "fabric-agent-demo" 字面量本身）----
reset_archive
write_pending '[{"path":"docs/z.html","kind":"A","age_days":30,"size_kb":0.5}]'
write_log_ts "$(iso_days_ago 1)"
expect_output "worktree cwd(/.wt/fabric-...) 也触发" "$TMP/.wt/fabric-chat-primitive" "docs-cleanup::hook-only"

echo "PASS $pass / FAIL $fail"
[ "$fail" -eq 0 ]
