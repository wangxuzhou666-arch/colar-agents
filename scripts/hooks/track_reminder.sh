#!/usr/bin/env bash
# UserPromptSubmit hook: 检测长线/易漂移信号 → 软推 /track
#
# 设计要点:
#   - 从 stdin JSON 拿 prompt(UserPromptSubmit 传 prompt)
#   - 只在命中"长线/高漂移"信号时输出(比 todo-reminder 的"多步"更窄,避免与它重复刷屏)
#   - todo-reminder 管"多步→建 checklist";本 hook 管"真长任务→冻结计划防漂移",职责不同
#   - stdout 被 Claude Code 当 context 注入;不命中 → 静默
set +e
INPUT=$(head -c 65536)
export HOOK_INPUT="$INPUT"

python3 -c '
import os, sys, json
try:
    d = json.loads(os.environ.get("HOOK_INPUT", "{}"))
except Exception:
    sys.exit(0)
p = (d.get("prompt", "") or "")
low = p.lower()

# 长线/高漂移信号:重构类 / 迁移类 / 全量遍历类 / 端到端 / 审计 / 显式防漂移诉求。
# 刻意窄:泛化的"多步"归 todo-reminder,这里只抓真会跨多轮、易跑偏的大任务。
SIGNALS = [
    "重构", "重写", "迁移", "整个", "从头", "一步步", "逐个", "逐一", "批量",
    "长线", "多阶段", "分阶段", "端到端", "大改", "别跑偏", "跑偏", "系统性重", "全盘", "全部重写",
    "migrate", "refactor", "rewrite", "end-to-end", "pipeline", "audit", "roadmap", "overhaul",
]
hit = any((s in p) or (s in low) for s in SIGNALS)

if hit:
    print("[track-reminder::hook-only] 本次含长线/易漂移信号。考虑 /track:冻结计划成 artifact + 绑 TodoWrite + checkpoint re-grounding + verify-gate,防中途漂移。单步/机械任务忽略。")
' 2>/dev/null
exit 0
