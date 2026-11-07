#!/usr/bin/env bash
# PreToolUse(Bash) 机械硬拦 —— 推到公开 GitHub 仓的提交，作者 / 提交者邮箱只能是 GitHub noreply。
#
# 规则（Colar 2026-11-05 批准做成 hook）：公开仓的提交只用 noreply 身份（<id>+<login>@users.noreply.github.com）。
# 为什么进机械层（2026-11-05 实证）：新 clone 的仓没有本地身份配置，提交时继承全局 git 身份，而全局身份是私人邮箱。
#   THUDM/slime 的修复提交前一刻才发现、改成 noreply；其他 OSS clone 都是手工设的本地身份。每次新 clone 都会再遇到，
#   推到公开仓就收不回 → 按 SOUL Tool-Call Discipline「机械 → hook」。本文件和判定器里不写任何私人邮箱：本仓公开。
#
# 判定（三条同时成立才拦）：
#   1. 命令里有 git push。cd / git -C / 子 shell / bash -c 的跟踪与 ai_attribution_guard 同口径（复用它的判定器）。
#   2. 要推的提交里有作者或提交者邮箱不是 GitHub noreply。要推的提交 = refspec 源（不写 refspec 是 HEAD；
#      --all / --branches / --mirror 是全部本地分支；--tags 加上标签）里、不在任何 remote-tracking 分支上的提交：
#      上游别人的提交早已公开，不算，所以 fork 落后于上游时不误拦。同一条命令里前面有新建 / 改写提交的 git 命令
#      （commit、rebase、cherry-pick…）时，新提交此刻还不存在，按仓里生效的 user.email 算。
#   3. 目标是公开的 GitHub 仓：remote（不写时依次取 branch.<分支>.pushRemote、remote.pushDefault、
#      branch.<分支>.remote，最后 origin）的 push URL 指向 github.com，且 gh api 查到 private=false。
#      gh 查不到（未登录、断网、无权限、hook 进程 PATH 里没有 gh）→ 按公开处理；查询前先把 /opt/homebrew/bin:/usr/local/bin
#      补进 PATH 末尾。非 GitHub remote（huggingface、本地路径）→ 放行。
# 拦截文案：最多列 3 处命中（短 sha + author / committer + 只露首字母和域名的邮箱），给带 -c 身份的 --reset-author 修法
#   （不写本地配置：某私有项目的 CLAUDE.md 把本地 user.* 当配置污染）。「gh 查不到」那一支带原因（gh 不在 PATH / 退出码 / 超时），
#   并提示先 gh repo view 核实：是 PRIVATE 就是钩子误拦，别改写提交，告诉 Colar。
#   不设 ALLOW_* 放行前缀：确实要推别人的提交时交给 Colar 自己推，放行口只会被顺手用掉。
#
# 已知边界（宁漏勿误、不追）：
#   - 不经 Claude Bash 工具的 push（Colar 手敲、IDE）；git 别名；wt run 这类包装脚本里的 push；$( ) 里的 push；
#   - 已在任一 remote 上的提交一律不算，包括只在私有 remote 上的：从私有仓往公开仓推旧历史时漏；
#   - 只看提交的作者 / 提交者，不看标签对象的 tagger、提交消息里的 Signed-off-by；
#   - 新建提交时用 GIT_AUTHOR_EMAIL / GIT_COMMITTER_EMAIL 环境变量或 git -c user.email=… 改写的身份；
#   - 参数里有变量 / 命令替换、仓库推断不了、解析不了 → 放行。
#   - 提交时不拦，只在 push 拦（2026-11-06 复核后不做）：某私有项目 2026-11-05 那次是私有仓被 gh 查询失败误拦，不是真泄漏；
#     「每条 commit 自带 -c 身份」已在 memory feedback_privacy_defaults.md 第 7 条。gh 查询可靠之后若再出现 ≥2 例提交时身份事故再议。
#
# fail-open：判定器缺失 / 崩溃 / 输出空、git 查询失败 → 放行（exit 0），绝不因 hook 自身出错阻断工具。
# 性能：payload 里没有 push 字样直接 exit 0，不起 python；只有找到非 noreply 邮箱时才调 gh api。
# 判定器：同目录 push_email_check.py（import 同目录 ai_attribution_check.py / shell_segments.py）。
# 测试接缝：环境变量 PUSH_EMAIL_GH_DIRS 覆盖上面那组回退目录，只给自证测试造「hook 进程 PATH 里没有 gh」用，生产不设。
# 自证测试：bash scripts/hooks/tests/test_push_email_guard.sh

input=$(cat 2>/dev/null || true)
[ -z "$input" ] && exit 0

case "$input" in
  *push*) ;;
  *) exit 0 ;;
esac

checker="$(dirname "${BASH_SOURCE[0]}")/push_email_check.py"
[ -f "$checker" ] || exit 0

out=$(printf '%s' "$input" | python3 "$checker" 2>/dev/null || true)
[ -n "$out" ] && printf '%s' "$out"
exit 0
