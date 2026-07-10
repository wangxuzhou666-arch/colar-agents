#!/usr/bin/env bash
# PreToolUse(Edit) guard —— Edit 前必须先用 Read 工具读过目标文件,否则拦截。
#
# 背景(2026-07-06 审计):Edit-before-Read 报错 3 天 16-18 次,是最高频自伤。
#   模型常用 cat/head 看完文件就直接 Edit,而 harness 只认 Read 工具 → Edit 必失败,
#   浪费一轮工具调用。本 hook 把失败提前到 PreToolUse,一次拦截 + 明确指路。
#
# 机制:stdin JSON 取 tool_input.file_path + transcript_path;grep transcript 里
#       是否出现过该 path 的 Read(或 Write —— Write 新建的文件 harness 允许直接 Edit)
#       tool_use 记录。确定没读过 → exit 2 + stderr 提示(反馈给模型,立刻改用 Read)。
#
# fail-open:找不到 transcript / stdin 解析异常 / 路径含非 ASCII(transcript 可能存
#       \uXXXX 转义,grep 口径对不上) / 任何不确定 → exit 0 放行,绝不误伤。
# 性能预算:<100ms。transcript 可能几 MB —— 用 grep 扫,不用 python 逐行 json 解析;
#       python3 只用来解析 stdin 那一份小 JSON(手搓 sed 会被 old_string 里的同名字段骗)。

input=$(cat 2>/dev/null || true)
[ -z "$input" ] && exit 0

# 解析 stdin JSON(file_path 第一行 / transcript_path 第二行)
fields=$(printf '%s' "$input" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("file_path", ""))
    print(d.get("transcript_path", ""))
    print(d.get("agent_id", ""))
except Exception:
    pass' 2>/dev/null || true)
[ -z "$fields" ] && exit 0

fp=$(printf '%s\n' "$fields" | sed -n '1p')
tp=$(printf '%s\n' "$fields" | sed -n '2p')
aid=$(printf '%s\n' "$fields" | sed -n '3p')

# subagent 调用 → fail-open（2026-07-10 实证根因）：subagent 的 hook 收到的 transcript_path 是
# 【父 session】的，而 subagent 的 Read 记在【子 sidechain】transcript，父 transcript grep 不到
# → 本 guard 必误判"没读过"→ 反而 fail-CLOSED 误拦合规的先-Read-再-Edit。本 guard 哲学是
# fail-open（不确定即放行），故 subagent 上下文（stdin 带 agent_id）一律放行；edit-before-read
# 自伤基本发生在主 loop，主 loop stdin 无 agent_id，其保护不受本放行影响。
[ -n "$aid" ] && exit 0

[ -n "$fp" ] && [ -n "$tp" ] || exit 0
[ -f "$tp" ] || exit 0
# 目标文件不存在 → 让 Edit 工具自己报错,不归本 guard 管
[ -e "$fp" ] || exit 0

# 路径含非 ASCII → transcript 里可能是 \uXXXX 转义,grep 字面量对不上 → 不确定,放行
if printf '%s' "$fp" | LC_ALL=C grep -q '[^ -~]'; then
    exit 0
fi

# transcript 里 Read/Write 的 tool_use 记录和 file_path 在同一 JSONL 行上:
# 先按 path 缩小到少数行,再看这些行里有没有 Read/Write 调用。宽松方向 = 放行(允许假阴性)。
if grep -F -- "$fp" "$tp" 2>/dev/null | grep -Fq -e '"name":"Read"' -e '"name":"Write"'; then
    exit 0
fi

echo "Edit 前必须先用 Read 工具读该文件（head/cat 不算）——本次已拦截，请先 Read" >&2
exit 2
