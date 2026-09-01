---
name: fabric-architect-pointer
description: 转发指针 → 织锦（fabric-agent-demo）项目的 fabric-architect 只读架构咨询 agent。当在裸 home lane（cwd=/Users/colar）问织锦的架构类问题——「这块当初怎么设计的 / 为什么这样」「改 X 影响面多大 / 牵连哪些模块」「现在有哪些域/表/端点/工具，状态如何」「这个模块归谁管」——但项目作用域的 agent 没 attach 时，用本指针拉起真配方。真身在织锦 repo 内，本文件只负责把你导过去，无独立逻辑。
---

# fabric-architect（转发指针）

真正的 `fabric-architect` 是**项目作用域** agent，挂在织锦 repo `.claude/agents/fabric-architect.md`，只有 cwd 在该 repo 内的 session 才自动进入可调用列表。Colar 常从裸 home lane（cwd=`/Users/colar`）问织锦架构问题，此时真身不在列表——本指针兜底。

**动作**（别在指针里现编流程）：

1. `Read /Users/colar/Desktop/创业/fabric-agent-demo/.claude/agents/fabric-architect.md`
2. 用 Agent tool 起一个 general-purpose subagent：prompt = 该文件 frontmatter 之后的正文全文 + Colar 的问题，并写明工作目录是 `/Users/colar/Desktop/创业/fabric-agent-demo`（所有相对路径以它为根）。
3. **已知降级，必须知会**：真身在项目内被调用时，`tools:` 白名单是平台级只读强制；经本指针走 general-purpose 时白名单不生效，只读退化为 prompt 约束。委派 prompt 里必须原样保留真身的「三不做」段，且给 Colar 的结果末尾注明「本次经 pointer 降级通道（只读为 prompt 约束非平台强制）」。
4. 例外：单条小问题（一次 grep / 读一个 JSON 就能答）可由主循环直接按真身文件的程序自己跑，不必起 subagent——同样恪守只读与证据强度标注。

真身文件路径若变动，以织锦 repo 内实际位置为准，并同步更新本指针。
