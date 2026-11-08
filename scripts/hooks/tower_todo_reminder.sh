#!/usr/bin/env bash
# UserPromptSubmit hook: 让每个 session 把待办写回塔台（Colar 2026-11-08 定，替换原来 settings.json 里
# 写死的 todo-reminder：它提示用 TodoWrite，而这个工具已经没有了，提示一直落空）。
#
# 塔台 = ~/code/session-board 的本机看板（http://127.0.0.1:4317）。scripts/todo.mjs 按 CLAUDE_CODE_SESSION_ID
# 把待办写到 .state/todos/<sessionId>.json；本 hook 用 stdin 里的 session_id 读同一个文件：
#   还没写过 → 提示「要多步完成就把最终目的写成 2–6 条 set」。写不写由模型判断：单步、纯问答不写
#   已经写过 → 把当前清单（编号 + 勾）注入，做完哪条直接 done N，不用先 show
# 塔台不在（todo.mjs 不存在）、输入不是 JSON、session_id 格式不对 → 静默；脚本自己出错也只是这轮不提示。
# 待办文件坏了按「还没写过」处理：重新 set 会整份覆盖。
# 只管待办：进展、后台实验、页面由塔台从对话记录里自己读，session 不用写。
# stdout 被 Claude Code 当 context 注入。TOWER_DIR 可覆盖塔台位置（测试用）。
set +e

TOWER=${TOWER_DIR:-$HOME/code/session-board}
[ -f "$TOWER/scripts/todo.mjs" ] || exit 0

INPUT=$(head -c 65536)
export HOOK_INPUT="$INPUT" HOOK_TOWER="$TOWER" HOOK_HOME="$HOME"

python3 -I -c '
import json, os, re, sys

try:
    data = json.loads(os.environ.get("HOOK_INPUT", ""))
except ValueError:  # 输入不是 JSON：静默
    sys.exit(0)
session = data.get("session_id") or ""
# 拼进文件路径之前先卡格式，防 ../ 之类
if not re.fullmatch(r"[0-9a-f-]{36}", session):
    sys.exit(0)

tower = os.environ["HOOK_TOWER"]
home = os.environ["HOOK_HOME"]
script = os.path.join(tower, "scripts", "todo.mjs")
cmd = "node " + ("~" + script[len(home):] if script.startswith(home + "/") else script)

try:
    with open(os.path.join(tower, ".state", "todos", session + ".json"), encoding="utf-8") as f:
        saved = json.load(f)
except (OSError, ValueError):  # 还没写过，或文件写坏了：都按还没写过提示，重新 set 会整份覆盖
    saved = {}
items = saved.get("items") or []

if items:
    listing = "；".join(str(i) + ("✓ " if item.get("done") else "☐ ") + item["text"] for i, item in enumerate(items, 1))
    print("[tower-todo::hook-only] 塔台上这个 session 的待办：" + listing
          + "。这轮做完哪条就跑 " + cmd + " done N；目标变了用 add 追加或 set 整份替换。")
else:
    print("[tower-todo::hook-only] 塔台上这个 session 还没有待办。本次要多步完成的话，先把这个 session 要达成的最终目的写成 2–6 条大白话："
          + cmd + " set \"…\" \"…\"；单步、机械任务或纯问答就不用写。")
' 2>/dev/null
exit 0
