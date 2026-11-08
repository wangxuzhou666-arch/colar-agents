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
#
# 自证测试：bash scripts/hooks/tests/test_bash_pitfall_guard.sh —— 每条规则都有正例（必 deny）
# 与反例（必放行，含各规则明写的放行例外）。改任何规则先跑它；新规则不带正反用例不许进。
# 已知限制：heredoc 正文也在被扫的命令串里（规则 5 / 8 / 9 / 10 除外，它们的判定器会跳过 heredoc 正文），
#           往文件里写含这些形状的内容请用 Write/Edit 工具。

input=$(cat 2>/dev/null || true)
[ -z "$input" ] && exit 0

cmd=$(printf '%s' "$input" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("tool_input",{}).get("command",""))
except Exception: pass' 2>/dev/null || true)
[ -z "$cmd" ] && exit 0

suggest=""

# ---- 规则 1 已退役（2026-11-07）：~/.zshenv 在 Claude Code 里开了 nonomatch，无匹配的 glob 原样传给命令；编号保留不重排 ----

# ---- 规则 2 已退役（2026-11-06）：30 天 58 次拦截 0 次真裸露，zsh 对裸括号路径自己会报 no matches；编号保留不重排 ----

# ---- 规则 3 已退役（2026-11-06）：30 天 9/9 误拦、0 真阳性；编号保留不重排 ----

# ---- 规则 4：相对路径 source .venv / 裸 .venv 可执行 ----
# cwd 会漂回裸 home（/Users/colar），相对 .venv 必 exit 127。
# 实证：07-30 / 08-23 / 08-25 / 09-09 / 09-10 / 09-11 多次，是全库复现最多的一类。
# 2026-11 审计：30 天 207 次拦截人工 64 条样本真阳性 0 —— cwd 自带 .venv 的占 55%，
# 与 wt-discipline 要求的 wt run <名> .venv/bin/python 正面冲突，所以只在「拿不出 cwd 已锚定的证据」时拦。
# 放行（任一成立）：
#   (a) hook stdin 的 cwd 字段读不到（fail-open），或 <cwd>/.venv/bin 真实存在 —— 相对 .venv 解析得到；
#   (b) 命令含 wt run —— wt 的 cmd_run 是 ( cd "$path" && "$@" )，cwd 已锚定；
#   (c) 命令里已有 cd / pushd 词（cd /abs、cd $W、cd "$W"、cd ~/x、cd $(git rev-parse …) 都算）。
# 三者都不成立才拦：cwd 在无 .venv 的目录（如裸 home），又没有任何锚定动作。不做引号 / heredoc / for 列表感知。
if [ -z "$suggest" ]; then
  if printf '%s' "$cmd" | grep -qE '(^|[[:space:];&|])(source[[:space:]]+)?\.venv/bin/'; then
    hook_cwd=$(printf '%s' "$input" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("cwd","") or "")
except Exception: pass' 2>/dev/null || true)
    if [ -z "$hook_cwd" ] || [ -d "$hook_cwd/.venv/bin" ]; then
      : # (a) cwd 读不到，或 cwd 自带 .venv，放行
    elif printf '%s' "$cmd" | grep -qE '(^|[/[:space:]])wt[[:space:]]+run([[:space:]]|$)'; then
      : # (b) wt run 已锚定 cwd，放行
    elif printf '%s' "$cmd" | grep -qE '(^|[[:space:];&|(])(cd|pushd)[[:space:]]'; then
      : # (c) 同条命令里已 cd / pushd，放行 —— 拦它会把模型逼进死胡同
    else
      suggest="cwd 会漂回裸 home（/Users/colar），相对 .venv/bin/ 必 exit 127（全库复现最多的一类坑）。用绝对路径，或同条命令里先 cd \$(git rev-parse --show-toplevel)"
    fi
  fi
fi

# ---- 规则 5：管道末段是展示型过滤器，紧接着就判 $? ----
# zsh 里 $? 是管道最后一段的码，前段失败被静默吞掉。实证 09-09 → 09-11 连续三天。
# 2026-11 审计：旧判据「整条命令有任意 | 且有任意 $?」30 天拦 1419 次、精度约 11%（真正 $? 紧跟管道只占 14.5%），
# 与本头注「任何不确定一律放行」矛盾，所以收窄到下面的形状。
# 拦（全部满足）：live 的 $?（不在单引号 / heredoc 正文 / bash -c '…' 里；双引号里的 "rc=$?" 算 live）·
#     含它的那条命令紧邻前一条是真管道（| 或 |&）的末段 · 该末段命令词属 tail head cut tee sed tr wc sort cat。
# 放行：$? 在管道之前（echo exit $? | tee log）· $? 跟在非管道命令后（cmd; echo $?）· 末段是 grep xargs diff python 等
#     （要首段还是末段的状态是意图问题，判不了）· 命令里有小写 pipestatus（含 ${pipestatus[1]:-$?}）或 set -o pipefail /
#     setopt pipefail。大写 PIPESTATUS 不豁免：zsh 里它是空的，${PIPESTATUS[0]:-$?} 会静默退回末段码。
# 判定在同目录 pipe_status_check.py（要认引号 / heredoc / 管道邻接，bash 正则写不清；与规则 8 / 9 共用 shell_segments.py 切词）；
# 判定器缺失或异常一律放行。预过滤：整条命令没有 | 或没有 $? 就不起 python。
if [ -z "$suggest" ]; then
  case "$cmd" in
    *'|'*)
      case "$cmd" in
        *'$?'*)
          pipe_checker="$(dirname "${BASH_SOURCE[0]}")/pipe_status_check.py"
          if [ -f "$pipe_checker" ]; then
            pipe_hit=$(printf '%s' "$cmd" | python3 "$pipe_checker" 2>/dev/null | head -n 1 || true)
            if [ -n "$pipe_hit" ]; then
              suggest="管道末段 ${pipe_hit}（只做展示）之后的 \$? 是 ${pipe_hit} 的退出码，前段失败被静默吞掉。最小改法（顶层 zsh）：cmd 2>&1 | tail -5; echo \"rc=\${pipestatus[1]}\"；要兼容 bash -c 就别进管道：cmd > <scratchpad 绝对路径>/x.log 2>&1; rc=\$?; tail -n 20 <scratchpad 绝对路径>/x.log。要的是首段状态就用 \${pipestatus[1]}"
            fi
          fi ;;
      esac ;;
  esac
fi

# ---- 规则 6：zsh 不对裸 $VAR 分词 ----
# VAR=$(find / grep -l / git diff --name-only …) 之后 pytest $VAR：zsh 把整块多行输出当 1 个参数。
# 实证 2026-09-15：30 个路径当 1 参数，pytest "no tests ran"；经 bash -c 跑不暴露，
# 所以 bash 肌肉记忆在这里必错。判定逻辑在同目录 zsh_wordsplit_check.py（形状复杂，bash 正则写不清）；
# 判定器缺失或异常一律放行。
if [ -z "$suggest" ]; then
  checker="$(dirname "${BASH_SOURCE[0]}")/zsh_wordsplit_check.py"
  if [ -f "$checker" ]; then
    hit=$(printf '%s' "$cmd" | python3 "$checker" 2>/dev/null | head -n 1 || true)
    if [ -n "$hit" ]; then
      suggest="zsh 不对裸 \$$hit 分词：它由多行列表型命令替换赋值，整块会被当成 1 个参数（2026-09-15 实测 30 个路径 → pytest \"no tests ran\"；bash -c 下不暴露）。用 \${=$hit} 强制分词，或把 \$(cmd) 直接内联到参数位（zsh 对命令替换会分词），或改走 | xargs"
    fi
  fi
fi

# ---- 规则 7：未加花括号的 $NAME:<字母> 被 zsh 当修饰符吃掉 ----
# "refs/heads/$b:refs/heads/$b" 里的 :r（去扩展名）被吞，展开成 refs/heads/feat/xefs/heads/feat/x，
# 双引号里也照吃。实证 2026-10-06：15 次 git push 全败。
# 判定在同目录 zsh_modifier_check.py（要认单引号 / 反斜杠，bash 正则写不清）；判定器缺失或异常一律放行。
if [ -z "$suggest" ]; then
  modifier_checker="$(dirname "${BASH_SOURCE[0]}")/zsh_modifier_check.py"
  if [ -f "$modifier_checker" ]; then
    modifier_hit=$(printf '%s' "$cmd" | python3 "$modifier_checker" 2>/dev/null | head -n 1 || true)
    if [ -n "$modifier_hit" ]; then
      read -r modifier_name modifier_letter <<< "$modifier_hit"
      suggest="zsh 把未加花括号的 \$${modifier_name}:${modifier_letter} 里的 :${modifier_letter} 当修饰符吃掉（双引号里也照吃；2026-10-06 实测 \"refs/heads/\$b:refs/heads/\$b\" 展开成 refs/heads/feat/xefs/heads/feat/x，15 次 push 全败）。写 \${${modifier_name}}:${modifier_letter}… ；若本意就是用修饰符，写 \${${modifier_name}:${modifier_letter}}"
    fi
  fi
fi

# ---- 规则 8：会删镜像 / build cache 的 docker 全局清理 ----
# 本机有钉死 digest、按政策不推 registry、无法按字节复原的本地镜像（织锦 PPTAgent 线 colar/pptagent-lab）。
# 实证 2026-10-07：磁盘清理 session 把 docker image prune -a -f; docker builder prune -a -f 当无风险操作，
# 删掉 B3 验收钉死的 v1d-f60543fb… 与 C 系列冻结 / 复核 / 变异镜像，零恢复来源，B3 硬阻塞。
# 项目 RUNBOOK 写了「不要全局 prune」，但清理 session 读不到项目文档 —— 文本规则挡不住，所以进机械层。
# 准入判据的例外：只有 1 次实证、不满足「已实证重踩」—— 那条判据是给可重试的坑定的，
#     这条的后果不可逆，踩一次就够（Colar 2026-10-07 拍板）。
# 拦：image/system/builder/buildx prune 带 -a/--all、docker rmi、docker image rm/remove（含 ; && | 之后、
#     赋值前缀、sudo/xargs 包装、--context/-H、bash -c 包裹）。不拦：不带 -a 的 prune、只读子命令、
#     引号 / 注释 / heredoc 里只是提到。
# 放行：紧贴该条 docker 命令写前缀 ALLOW_DOCKER_PRUNE=1，只对紧跟的那一条生效；export 不算、
#     不读环境变量 —— 刻意不做全局开关。
# 判定在同目录 docker_prune_check.py（要切命令段、认引号 / heredoc，bash 正则写不清）；判定器缺失或异常一律放行。
if [ -z "$suggest" ]; then
  case "$cmd" in
    *docker*)
      docker_checker="$(dirname "${BASH_SOURCE[0]}")/docker_prune_check.py"
      if [ -f "$docker_checker" ]; then
        docker_hit=$(printf '%s' "$cmd" | python3 "$docker_checker" 2>/dev/null | head -n 1 || true)
        if [ -n "$docker_hit" ]; then
          suggest="命中 ${docker_hit}：会删镜像或 build cache，不是无风险清理。本机有钉死 digest、不推 registry、无法按字节复原的本地镜像（例如织锦 PPTAgent 线 colar/pptagent-lab；2026-10-07 一次磁盘清理跑 image prune -a + builder prune -a，删掉 B3 钉死的 v1d-f60543fb… 等镜像，零恢复来源）。先跑 docker image ls --digests 看清会删什么。更安全的替代：不带 -a 的 docker image prune（只删 dangling）；docker builder prune --reserved-space <大小>（不带 -a，保留一部分 cache；旧版 CLI 叫 --keep-storage）；确需 -a 时用 --filter（until= / label!=）排除要保留的。看清后若 Colar 明确要删，在这条 docker 命令前紧贴写 ALLOW_DOCKER_PRUNE=1（只对紧跟的这一条生效）"
        fi
      fi ;;
  esac
fi

# ---- 规则 9：跳过仓库钩子（--no-verify / 换走 core.hooksPath）/ 强推 ----
# 2026-10-17 织锦 git 协作规范：多个助理（本机 / 云端 Claude、Codex）共用一个仓，规则的机械层就是仓库钩子
# （pre-commit / pre-merge-commit / pre-push），--no-verify 一个词让它们全部失效且不留痕；开发分支一律
# merge origin/main 后快进推送，强推会覆盖别人已推的提交。准入判据的例外同规则 8：后果不可逆 / 绕过无痕，
# 踩一次就够，不等重踩证据（随 2026-10-17 织锦 git 协作规范计划一并拍板纳入）。
# 拦：git commit --no-verify / -n、git merge --no-verify、git push --no-verify；git push --force / -f /
#     --force-with-lease / --force-if-includes / --mirror / +refspec。不拦：git push -n（--dry-run）、--delete / :分支 删除。
#     换钩子目录同属跳钩子：git -c core.hooksPath=… / --config-env[=]core.hooksPath=…（任何子命令、任何值）、
#     git config core.hooksPath <值 ≠ .githooks>、--global / --system / --worktree / --file（-f）下设 core.hooksPath
#     （任何值：全局设成 .githooks 会让本机没有 .githooks 目录的仓全都不跑钩子）、git config --unset core.hooksPath
#     （都含 set / unset 子命令写法），键不分大小写。不拦：git config [--local] core.hooksPath .githooks（织锦 SessionStart
#     钩子原句）与只读（任何作用域的 --get / --get-all / --show-origin / --list、不带值）。
# 放行：紧贴该条 git 命令写前缀 ALLOW_NO_VERIFY=1（跳钩子 / 换钩子目录）/ ALLOW_GIT_FORCE=1（强推 / --mirror），
#     各管各的、只对紧跟的那一条生效。
# 已知边界（宁漏勿误、不追）：长选项缩写（--no-veri / --mirr）、git 别名（git pf）、GIT_CONFIG_* 环境变量与直接改 .git/config 都不检查——兜底是 main 上的服务端 ruleset。
# 判定在同目录 git_safety_check.py（与规则 8 共用 shell_segments.py 切词）；判定器缺失或异常一律放行。
if [ -z "$suggest" ]; then
  case "$cmd" in
    *git*commit*|*git*merge*|*git*push*|*[Hh][Oo][Oo][Kk][Ss][Pp][Aa][Tt][Hh]*)
      git_checker="$(dirname "${BASH_SOURCE[0]}")/git_safety_check.py"
      if [ -f "$git_checker" ]; then
        git_hit=$(printf '%s' "$cmd" | python3 "$git_checker" 2>/dev/null | head -n 1 || true)
        if [ -n "$git_hit" ]; then
          read -r git_kind git_label <<< "$git_hit"
          case "$git_kind" in
            no-verify)
              suggest="命中 ${git_label}：会跳过仓库钩子——secret 门 / main 分支拦截 / 推送规则全部失效，且不留痕。钩子拦下就按它的提示修；仓库给了单项登记口的走登记口（织锦：GATE_SKIP_REASON=\"<kind>: <原因>\"，记进 .gate-skips.jsonl）。确需整体绕过且 Colar 明确同意，在这条 git 命令前紧贴写 ALLOW_NO_VERIFY=1（只对紧跟的这一条生效）" ;;
            hooks-path)
              suggest="命中 ${git_label}：把 core.hooksPath 换走或清掉，仓库钩子（secret 门 / main 分支拦截 / 推送规则）就整体不跑、且不留痕；用 git config 写进仓库配置的还会一直生效，之后每个助理的每次提交都跳过钩子。唯一放行的是在本仓配置里设成 .githooks：git config [--local] core.hooksPath .githooks；--global / --system / --worktree / --file 下设 core.hooksPath 不看值一律拦（全局设成 .githooks，本机所有没有 .githooks 目录的仓都不跑钩子）。钩子拦下就按它的提示修；单项要跳走仓库的登记口（织锦：GATE_SKIP_REASON=\"<kind>: <原因>\"）。确需绕过且 Colar 明确同意，在这条 git 命令前紧贴写 ALLOW_NO_VERIFY=1（只对紧跟的这一条生效）" ;;
            force)
              suggest="命中 ${git_label}：强推会覆盖远端已有的提交（--mirror 还会删掉远端有、本地没有的分支和标签）。规则是一分支一个写入方、开发分支只用 git merge origin/main 整合、推送永远快进——推送被拒说明远端有你没有的提交（单写入方已被破坏），该停下报告，不是加 --force。删远端分支用 git push origin --delete <分支>（不拦）。确需强推且 Colar 明确同意，在这条 git 命令前紧贴写 ALLOW_GIT_FORCE=1（只对紧跟的这一条生效）" ;;
          esac
        fi
      fi ;;
  esac
fi

# ---- 规则 10：没走全机重任务槽的多 worker pytest ----
# 实证 2026-11-07 21:52：两个会话各跑一套全量测试（-n auto 8 worker + 覆盖率 / -n 6）+ 刚重启的 Docker 虚拟机，
# 把 16G 内存和 swap 压满，机器卡死被强制重启；19:58 同类并发还把磁盘写满。每个会话只看自己，没有全机统管点。
# 准入判据的例外同规则 8：后果是整机强制重启、所有会话的进行中工作一起丢，踩一次就够（Colar 2026-11-08 拍板）。
# 拦：pytest / python -m pytest 带 -n ≥2 / auto / logical（含 uv / poetry / pipenv / wt run 包装）。
# 不拦：-n 0 / 1、单进程 pytest（带 --cov 也不拦：内存乘数是 worker 数）、已经 heavy_slot.py run … -- 包着的、
#     只是提到。各仓接了槽的入口脚本（织锦 clean_check_all / check_all / coverage_snapshot）内部排队，不在这里拦。
# 不设 ALLOW 前缀：放行路径就是走槽，槽在本仓、总可用；只跑少数文件就去掉 -n。
# 判定在同目录 heavy_task_check.py（与规则 8 / 9 共用 shell_segments.py 切词）；判定器缺失或异常一律放行。
if [ -z "$suggest" ]; then
  case "$cmd" in
    *pytest*)
      case "$cmd" in
        *-n*)
          heavy_checker="$(dirname "${BASH_SOURCE[0]}")/heavy_task_check.py"
          if [ -f "$heavy_checker" ]; then
            heavy_hit=$(printf '%s' "$cmd" | python3 "$heavy_checker" 2>/dev/null | head -n 1 || true)
            if [ -n "$heavy_hit" ]; then
              suggest="命中 ${heavy_hit}：多 worker 的测试要走全机重任务槽，同一时刻全机只跑一套（2026-11-07 两套 -n 全量测试 + Docker 把 16G 内存和 swap 压满，机器卡死被强制重启）。改成：python3 \$HOME/Desktop/colar-agents/scripts/heavy_slot.py run --priority gate --label <线名> -- <原命令>（排队时会播报在等谁；部署门用 --priority deploy）。只跑少数几个测试文件就去掉 -n。看谁在占槽：python3 \$HOME/Desktop/colar-agents/scripts/heavy_slot.py status"
            fi
          fi ;;
      esac ;;
  esac
fi

[ -z "$suggest" ] && exit 0

reason=$(printf '%s' "⛔ pitfall-guard: $suggest" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || true)
[ -z "$reason" ] && exit 0

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}' "$reason"
exit 0
