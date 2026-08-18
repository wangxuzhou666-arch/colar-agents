---
name: wt-discipline
description: 用 git worktree 做隔离验证/部署/并行分支时的纪律 —— 一律走 `wt` 包装脚本（scripts/wt），落点固定 ~/.wt/<repo>-<用途>，绝不 cd 进 worktree、绝不把要留存的产物写在 worktree 里。治六类实证踩坑：cwd 悬空后满屏 ENOENT · /tmp↔/private/tmp 别名让 remove 失配 · 防御式 rm -rf+prune 仪式 · 产物随 worktree 蒸发（部署史丢过一条）· 落点四处开花 · .venv/node_modules 每次手搭。Use when: creating a throwaway worktree to verify a build/test at a specific ref, running a clean-tree deploy, working two branches in parallel, or debugging "worktree remove 删不掉 / 目录已存在 / No such file or directory / 部署记录不见了".
version: 1.0.0
source: session-derived (2026-08-18)。全量扫 5297 个 session、200 个含真实 git worktree 操作的会话、288 次调用统计得出；六类失败模式均有现场证据。
---

# worktree 纪律

worktree 的价值是**在不扰动主工作树的前提下拿到某个 ref 的干净副本**——验构建、跑测试、做部署。
它的代价是**你多了一个会凭空消失的文件系统位置**，而所有翻车都来自忘记这一点。

机械层已由 `~/Desktop/colar-agents/scripts/wt` 承担，本文件只讲脚本替你挡不掉的判断。

## 一、命令

```bash
wt new <用途> [ref]     # 建到 ~/.wt/<repo>-<用途>，默认 detach，自动继承 .venv / node_modules
wt run <用途> <命令...> # 在 worktree 里跑；调用方 cwd 不动
wt ls                   # 一屏看全：净 / 脏 / 悬空 / 不在 ~/.wt
wt rm <用途>            # 拆；有未提交内容会拒绝并摊开给你看，要丢得显式 --force
wt gc                   # prune 失联记录 + 清 ~/.wt 下干净的孤儿目录
wt main                 # 打印主工作树根（在 worktree 里调用也返回主仓）
```

不在 PATH 里就用绝对路径 `bash ~/Desktop/colar-agents/scripts/wt ...`。

## 二、三条铁律

**1. 不 cd 进 worktree，只用 `wt run`。**
Claude Code 的 Bash cwd 跨调用持久。`cd` 进去干活、下一条命令把它删掉，shell 就卡在一个不存在的目录里，
之后每条命令都 `No such file or directory`——历史上 6 次，而且每次都要浪费两三轮才反应过来是 cwd 的问题。
`wt run` 用子 shell 执行，从根上不存在这个状态。

**2. 要留存的东西写主仓，不写 worktree。**
worktree 是**一次性**的。部署日志、生成的报告、临时写的验证脚本，只要下一轮还想要，就必须落在 `wt main` 指的地方。

> 实证（2026-08-18）：`update.sh` 里部署史写 `REPO_ROOT`，而干净部署流程让 REPO_ROOT 指向 `/tmp/deploy-xxx`，
> 于是当天三次部署的记录，一条随 worktree 被删而**永久丢失**，另两条散在两个临时目录，主仓的部署史停在八天前。
> 同形事故：`mutation_check.py` 随 scratchpad 消失——"纪律留在 memory 里、工具却没了，下一轮从零重建"。

脚本里要推主仓根，用 `git rev-parse --git-common-dir` 的父目录（主仓返回 `.git`，worktree 返回主仓的 `.git`，两种都对），
不要用 `$(dirname $0)/..` 那种相对推断。

**3. `wt rm` 被拒绝时，先看，别条件反射加 `--force`。**
拒绝的意思是那里面有你没提交的东西。搬回主仓再拆。

## 三、什么时候不该用 worktree

- **只是想看某个 ref 的某个文件** → `git show <ref>:<path>`，不用建目录。
- **只是想跑一次测试且主树是干净的** → 直接在主仓跑。worktree 的成本（环境继承、清理、记得产物落点）只有在
  "主树脏 / 要并行 / 要 detach 到历史 ref" 时才划算。
- **要长期存在的第二个开发环境** → 那不是 throwaway worktree，用正经 clone 或长期分支，别塞进 `~/.wt`
  （`~/.wt` 的语义是"随时可以 gc 掉"）。

## 四、历史落点，遇到了就迁

老的 worktree 散在四处：`/tmp/*`、`/private/tmp/*`、session scratchpad、仓内 `.claude/worktrees/`、
以及 `~/Desktop/创业/` 下和真项目混在一起的（`fabric-fabrics`、`deploy-9225960` 都是 worktree 不是项目）。
`wt ls` 会把不在 `~/.wt` 的标出来。清理前先 `wt ls` 看脏不脏——尤其 `~/Desktop` 下那些，长得像项目，误删代价高。
