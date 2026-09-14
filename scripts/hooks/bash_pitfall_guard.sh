#!/usr/bin/env bash
# PreToolUse(Bash) 机械坑硬拦 —— 把「反复重踩、纯机械、与任务无关」的坑从文本层降到机械层。
#
# 证据（2026-09-13，从织锦 379 份 handoff 落盘提取 1928 条坑做跨时间聚类）：
#   这几条坑分别已经写进 SOUL（绝对路径）、fabric-loop Pitfalls（source .venv / zsh glob 括号路径），
#   仍然跨两个月反复重踩，周重踩率 5-18% 无下降趋势。结论：文本杠杆对机械坑无效。
#   最刺眼的一条自供：「zsh glob：grep --include=*.py 不加引号（fabric-loop 早写过，又踩）」。
#
# 机制：deny + reason 回模型，让它立刻改写重发（同 tool_discipline_nudge.sh 的姿势）。
#       只拦高置信、零歧义的形状；任何不确定一律放行。脚本自身异常必放行（exit 0），
#       绝不因 hook 出错阻断工具。
#
# 新增规则的判据：必须是「机械的 + 每个 session 都成立 + 与具体任务无关 + 已实证重踩」四条全中。
# 判断类的坑不许进这里 —— 那些该留在 skill 文本里给模型读。

input=$(cat 2>/dev/null || true)
[ -z "$input" ] && exit 0

cmd=$(printf '%s' "$input" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("tool_input",{}).get("command",""))
except Exception: pass' 2>/dev/null || true)
[ -z "$cmd" ] && exit 0

suggest=""

# ---- 规则 1：--include/--exclude 的 glob 未加引号 ----
# zsh 会先行展开 *，当前目录没有匹配就整条命令报 "no matches found" 直接不执行。
# 实证复现：2026-07-23 / 07-28 / 09-03 三次，跨 2 个月。
if printf '%s' "$cmd" | grep -qE -- "--(include|exclude)=[^'\"[:space:]]*\*"; then
  suggest="zsh 会展开 --include=*.py 里的 * ，当前目录无匹配则整条命令报 \"no matches found\" 不执行。加引号：--include='*.py'"
fi

# ---- 规则 2：Next.js 路由组 / 动态段括号路径未加引号 ----
# (console) (studio) [id] 在 zsh 里是 glob 元字符，不加引号会被静默吞掉，
# 于是 git diff / test -f 在残缺的文件集上作业，且不报错。
if [ -z "$suggest" ]; then
  # 先剥掉所有引号包裹的片段，剩下的才是裸露部分
  bare=$(printf '%s' "$cmd" | sed "s/'[^']*'//g; s/\"[^\"]*\"//g")
  if printf '%s' "$bare" | grep -qE '/\([a-z_]+\)|/\[[a-z_]+\]'; then
    suggest="路径里的 (console)/(studio)/[id] 在 zsh 里是 glob 元字符，不加引号会被静默吞掉（命令照跑、文件集残缺、不报错）。整个路径加单引号，或命令前加 noglob"
  fi
fi

# ---- 规则 3：拿系统 python3 跑 pytest ----
# 系统 python3 没装 pytest；实证 2026-07-24/25/27 三天 8 次。
if [ -z "$suggest" ]; then
  case "$cmd" in
    *python3\ -m\ pytest*|*python3\ -m\ unittest*)
      case "$cmd" in
        */.venv/bin/*|*venv/bin/python*) : ;;   # 已经走 venv，放行
        *) suggest="系统 python3 没装 pytest（实测 8 次）。用 repo 的 .venv/bin/python -m pytest，绝对路径起手" ;;
      esac ;;
  esac
fi

# ---- 规则 4：相对路径 source .venv / 裸 .venv 可执行 ----
# cwd 会漂回裸 home（/Users/colar），相对 .venv 必 exit 127。
# 实证：07-30 / 08-23 / 08-25 / 09-09 / 09-10 / 09-11 多次，是全库复现最多的一类。
if [ -z "$suggest" ]; then
  if printf '%s' "$cmd" | grep -qE '(^|[[:space:];&|])(source[[:space:]]+)?\.venv/bin/'; then
    # 同一条命令里已先 cd 到绝对路径（或 cd $(git rev-parse --show-toplevel)）才用相对 .venv，
    # 是 fabric-loop Phase 2 的推荐写法，cwd 已锚定，放行 —— 拦它会把模型逼进死胡同。
    if printf '%s' "$cmd" | grep -qE 'cd[[:space:]]+("|'"'"')?(/|\$\(git[[:space:]]+rev-parse)'; then
      : # 已锚定 cwd，放行
    else
      suggest="cwd 会漂回裸 home（/Users/colar），相对 .venv/bin/ 必 exit 127（全库复现最多的一类坑）。用绝对路径，或同条命令里先 cd \$(git rev-parse --show-toplevel)"
    fi
  fi
fi

# ---- 规则 5：管道后判退出码 ----
# zsh 里 $? 是管道最后一段的码，前段失败被静默吞掉。实证 09-09 → 09-11 连续三天。
if [ -z "$suggest" ]; then
  if printf '%s' "$cmd" | grep -q '|' && printf '%s' "$cmd" | grep -qE '\$\?'; then
    suggest="管道里 \$? 取的是最后一段的退出码，前段失败被静默吞掉（实证连踩三天）。用 \${pipestatus[1]}（zsh）或让被判断的命令不进管道"
  fi
fi

[ -z "$suggest" ] && exit 0

reason=$(printf '%s' "⛔ pitfall-guard: $suggest" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || true)
[ -z "$reason" ] && exit 0

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}' "$reason"
exit 0
