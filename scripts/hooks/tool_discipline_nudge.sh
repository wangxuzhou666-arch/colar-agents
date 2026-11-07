#!/usr/bin/env bash
# PreToolUse(Bash) tool-discipline nudge —— 把「用 shell 整读文件」软性掰回 Read 工具。
#
# 证据（2026-11 审计，30 天）：728 次拦截，608 次发生在一次性 subagent 里；其中 67.7% 本身就是有界读取
#   （tail 末尾 N 行 99 次、sed -n A,Bp、head -N），拦下来只是白费一个回合，Read 并不省 context；
#   .env 分支 0 次触发。Read 做不到的只有「取末尾 N 行」、带正则地址的 sed、多文件 head。
#   ⚠️ 只管「读文件」不管搜索：本 setup 里 Grep/Glob 工具未 provision（0 可用），
#      搜索只能用 Bash grep/find，无替代品，故绝不拦 grep/find —— 拦了会把模型逼进死胡同。
#
# 机制：只拦「独立、无管道、能用 Read 干净替代」的整读命令 → deny + 提示改用 Read（reason 回模型，立刻重发）。
#       含管道 / 链式 / 命令替换 / xargs / 重定向的合法复合命令一律放行（cd X && sed -n … 同理，是设计，不扩展），
#       避免误伤真实 pipeline。非高置信一律放行。脚本任何异常路径都放行（exit 0），绝不因 hook 自身出错而阻断工具。
#
# 判定顺序（独立的 cat / head / tail / sed -n 命令）：
#   1. 命令里出现 .env → deny（强措辞）。排在所有放行分支之前，否则 tail 整类放行会让 `tail ~/.env` 绕过
#   2. tail 整类放行（-n N / -c N / -f，含 tail -f /dev/null）：Read 没有取末尾 N 行的能力
#   3. 带正则地址的 sed -n '/pat/,/pat/p'（也认 N,/pat/）与多文件 head：Read 做不到
#   4. 单文件有界读取放行（Colar 2026-11-07 拍板，部分回退「读文件强制 Read」）：sed -n A,Bp / sed -n Np、
#      head 带显式行数或字节数（-N / -n N / -c N / --lines= / --bytes=）。静默放行，不附提示 ——
#      有界读取不费 context，放行时再附一句「下次用 offset/limit」只是把 deny 换成同样的摩擦
#   5. 其余 deny：不带范围的 cat、不带行数的 head、sed -n 非数字行范围（含 A,$p）
# 已知代价：主 loop 里 sed -n 读完再 Edit 仍会被 edit_read_guard 拦一次（它防的就是这个）；subagent 里它 fail-open。
#
# 自证测试：bash scripts/hooks/tests/test_tool_discipline_nudge.sh

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

# 放行判定（返回 0 = 放行）：Read 做不到的用法 + 单文件有界读取。调用方已保证 $1 以 head / sed -n 开头
allowed_bounded_read() {
  local -a words
  local script word positional=0 has_count=0 skip_next=0
  local address_re='^([0-9]+,)?/'
  local range_re='^[0-9]+(,[0-9]+)?p'"['\"]?"'$'
  set -f   # 下面按空白切词，不能让 * 之类被 glob 展开
  words=($1)
  set +f
  case "${words[0]}" in
    sed)
      script="${words[2]-}"
      script="${script#[\'\"]}"
      [[ $script =~ $address_re ]] && return 0   # 带正则地址：Read 做不到
      [[ $script =~ $range_re ]] && return 0     # 数字行范围：有界
      return 1 ;;
    head)
      for word in "${words[@]:1}"; do
        if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
        case "$word" in
          -n|-c) has_count=1; skip_next=1 ;;
          -[0-9]*|-n[0-9]*|-c[0-9]*|--lines=*|--bytes=*) has_count=1 ;;
          -*) ;;
          *) positional=$((positional + 1)) ;;
        esac
      done
      [ "$positional" -ge 2 ] && return 0                         # 多文件 head：Read 做不到
      [ "$positional" -eq 1 ] && [ "$has_count" = 1 ] && return 0  # 单文件有界
      return 1 ;;
  esac
  return 1
}

suggest=""
case "$trimmed" in
  cat\ *|head\ *|tail\ *|sed\ -n\ *)
    case "$trimmed" in
      # .env 类敏感读取：更强措辞（对齐 feedback_env_file_secret_handling 零信任事故），必须排在所有放行分支之前
      *".env"*) suggest="禁止读 .env（零信任事故有前科）；要验证行数/键用 wc -l / grep -c，绝不让 secret 进 context" ;;
      tail\ *) ;;
      *) allowed_bounded_read "$trimmed" || suggest="整读文件请用 Read file_path=<绝对路径> offset=<行> limit=<行数>" ;;
    esac ;;
esac
[ -z "$suggest" ] && exit 0

reason=$(printf '%s' "🧭 tool-discipline: $suggest" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || true)
[ -z "$reason" ] && exit 0

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}' "$reason"
exit 0
