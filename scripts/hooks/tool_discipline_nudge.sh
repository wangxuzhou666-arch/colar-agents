#!/usr/bin/env bash
# PreToolUse(Bash) tool-discipline nudge —— 把「用 shell 读文件」软性掰回 Read 工具。
#
# 证据（跨 1134 session transcript 统计，2026-07-03）：
#   用 cat/head/tail/sed 读文件：cat 83 / head 35 / sed 209 / tail 4；这些把整份内容灌进 context + 有 .env 泄漏面。
#   ⚠️ 只管「读文件」不管搜索：本 setup 里 Grep/Glob 工具未 provision（0 可用），
#      搜索只能用 Bash grep/find，无替代品，故绝不拦 grep/find —— 拦了会把模型逼进死胡同。
#
# 机制：只拦「独立、无管道、能用 Read 干净替代」的读文件命令 → deny + 提示改用 Read（reason 回模型，立刻重发）。
#       含管道 / 链式 / 命令替换 / xargs / 重定向的合法复合命令一律放行，避免误伤真实 pipeline。
#       非高置信一律放行。脚本任何异常路径都放行（exit 0），绝不因 hook 自身出错而阻断工具。

input=$(cat 2>/dev/null || true)
[ -z "$input" ] && exit 0

cmd=$(printf '%s' "$input" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("tool_input",{}).get("command",""))
except Exception: pass' 2>/dev/null || true)
[ -z "$cmd" ] && exit 0

# 含管道/链式/命令替换/xargs/重定向 → 合法复合用法，放行
case "$cmd" in
  *"|"*|*"&&"*|*";"*|*'$('*|*'`'*|*"xargs"*|*">"*) exit 0 ;;
esac

# 去前导空格
trimmed="${cmd#"${cmd%%[![:space:]]*}"}"

suggest=""
case "$trimmed" in
  cat\ *|head\ *|tail\ *|sed\ -n\ *)
    suggest="用 Read 工具读文件（cat/head/tail/sed 读文件会把内容全灌进 context + 有 .env 泄漏风险；Read 有 offset/limit 更省 context）" ;;
esac
[ -z "$suggest" ] && exit 0

# .env 类敏感读取：更强措辞（对齐 feedback_env_file_secret_handling 零信任事故）
case "$trimmed" in
  *".env"*) suggest="禁止读 .env（零信任事故有前科）；要验证行数/键用 wc -l / grep -c，绝不让 secret 进 context" ;;
esac

reason=$(printf '%s' "🧭 tool-discipline: $suggest" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || true)
[ -z "$reason" ] && exit 0

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}' "$reason"
exit 0
