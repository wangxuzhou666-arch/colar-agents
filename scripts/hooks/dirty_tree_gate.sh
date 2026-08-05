#!/usr/bin/env bash
# dirty-tree gate（Stop hook）— session 结束时，若 git 树脏（dirty 文件数 > 阈值）
# 且并发检测判定无活跃并发 → 输出 advisory：「树脏且无并发，建议分组 commit 或走 /ship，
# 别静默留脏树」。
#
# 为什么：「脏树雪球」的根因之一是 session 静默留脏树等 owner 先 commit，叠加「误判有并发」
#   放大器，导致几十个文件跨 session 累积。本 gate 在 session 收尾时给一次 advisory 提醒——
#   只有在「确实脏 + 确实没有并发理由」时才响，避免误伤正常的 hunk-split 留脏。
#
# 纪律（对齐 memory_drift_check.sh Stop hook 范式）：
#   - advisory，绝不 block：clean（树干净 or 未过阈值）时完全静默；命中才输出；永远 exit 0。
#   - 快：<0.5s。只读 git status + 复用并发检测脚本（后者也只读 ps/sessions，无副作用）。
#   - 幂等、无副作用：不碰 repo 状态，不 commit/add/stash，纯读。
#
# 触发条件（全部满足才响）：
#   dirty_count > DIRTY_THRESHOLD  且  并发裁决 ∈ {NONE, AMBIGUOUS}
#     - NONE      → 完整 advisory（无并发证据，最该 commit）
#     - AMBIGUOUS → 软 advisory（疑似并发但无法确认，提示「确认无并发就分组 commit」）
#     - CONCURRENT→ 静默（确有并发是留脏树的正当理由）
#
# 配置（env 覆盖）：
#   REPO              默认 = 当前 cwd 所在的 git 树（worktree 则为该 worktree）；不在 git 树中则静默退出
#   DIRTY_THRESHOLD   默认 15（脏文件数 > 此值才提示；正常 hunk-split 留几个脏文件不触发）

set -u

DIRTY_THRESHOLD="${DIRTY_THRESHOLD:-15}"
CHECK_SCRIPT="$HOME/Desktop/colar-agents/scripts/concurrent_session_check.sh"

# 前置守卫：git 不可用 → 静默退出
command -v git >/dev/null 2>&1 || exit 0

# REPO 默认取当前所在 git 树的根。不硬编码任何具体项目路径——本 gate 对所有 repo 通用。
REPO="${REPO:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -n "$REPO" ] || exit 0
# 用 rev-parse 判定而非 [ -d "$REPO/.git" ]：worktree 的 .git 是**文件**不是目录，
# 目录判据会让本 gate 在所有 worktree 里静默失效。
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || exit 0

dirty=$(git -C "$REPO" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
# 非数字或未过阈值 → 静默
case "$dirty" in
  ''|*[!0-9]*) exit 0 ;;
esac
[ "$dirty" -gt "$DIRTY_THRESHOLD" ] || exit 0

# 树确实脏 → 问并发检测脚本：有没有活跃并发
verdict_line=$(REPO="$REPO" bash "$CHECK_SCRIPT" --brief 2>/dev/null | head -1)
verdict=$(printf '%s' "$verdict_line" | sed -n 's/^VERDICT=\([A-Z]*\).*/\1/p')

repo_name=$(basename "$REPO")

case "$verdict" in
  CONCURRENT)
    # 确有并发 → 留脏树正当，静默
    exit 0
    ;;
  NONE)
    echo "[dirty-tree gate] ${repo_name} 树脏（${dirty} 个未 commit 文件 > 阈值 ${DIRTY_THRESHOLD}）且未检测到活跃并发 claude session。"
    echo "  建议：分组 commit（按逻辑单元）或走 /ship，别静默留脏树等下个 session——这是脏树雪球的起点。"
    echo "  （详情跑：bash ${CHECK_SCRIPT}）"
    ;;
  AMBIGUOUS)
    echo "[dirty-tree gate] ${repo_name} 树脏（${dirty} 个未 commit 文件 > 阈值 ${DIRTY_THRESHOLD}）。检测到疑似并发 session（裸 home lane，无法确认是否在改本 repo）。"
    echo "  若确认无人在并发改本 repo → 分组 commit 或 /ship，别默认留脏树。（详情跑：bash ${CHECK_SCRIPT}）"
    ;;
  *)
    # 检测异常/无裁决 → 保守静默，不制造噪音
    exit 0
    ;;
esac

exit 0
