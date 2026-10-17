---
name: pattern-cad-pointer
description: 转发指针 → 织锦（fabric-agent-demo）项目的 pattern-cad 制版链执行 agent。当在裸 home lane（cwd=/Users/colar）要做织锦制版链相关任务——改制版链代码、出交付件、问「这条链现在到哪了 / 这个坑是不是踩过」——但项目作用域的 agent 没 attach 时，用本指针拉起真配方。真身在织锦 repo 内，本文件只负责把你导过去，无独立逻辑。与 fabric-architect-pointer 的分工：全仓架构与影响面咨询走那个，制版链的任何活走这个。
---

# pattern-cad（转发指针）

真正的 `pattern-cad` 是**项目作用域** agent，挂在织锦 repo
`.claude/agents/pattern-cad.md`，只有 cwd 在该 repo 内的 session 才自动进入可调用列表。
Colar 常从裸 home lane（cwd=`/Users/colar`）起制版的活，此时真身不在列表——本指针兜底。

**动作**（别在指针里现编流程）：

1. `Read /Users/colar/Desktop/创业/fabric-agent-demo/.claude/agents/pattern-cad.md`
2. 用 Agent tool 起一个 general-purpose subagent：prompt = 该文件 frontmatter 之后的**正文全文**
   + Colar 的任务，并写明工作目录是 `/Users/colar/Desktop/创业/fabric-agent-demo`
   （所有相对路径以它为根）。
3. **已知降级，必须知会**：真身在项目内被调用时 `tools:` 白名单是平台级强制；
   经本指针走 general-purpose 时白名单不生效。对本 agent 这意味着两件事：
   - **真身的版域边界段从平台强制退化成 prompt 约束** —— 委派 prompt 必须原样保留该段全文，
     否则 subagent 可能改到制版域外、属于其他链路的共享文件。
   - general-purpose 还多出真身没有的工具（起子 agent、联网）。prompt 里显式禁掉。
   - **真身的停机规则段必须原样保留** —— 这是全权执行 agent 的那道保险，丢了它 subagent 会
     自己猜默认值填进去，而「猜一个默认值」是本项目的红线。
   给 Colar 的结果末尾注明「本次经 pointer 降级通道（版域边界为 prompt 约束非平台强制）」。
4. 例外：**纯查询类**小问题（「这条链现在到哪了」「这个坑踩过吗」——一次 grep / 读一个切片
   就能答）可由主循环直接按真身写明的切片读法自己跑，不必起 subagent。
   **但凡涉及改文件、跑门、出交付件，一律起 subagent 走完整配方。**

真身文件路径若变动，以织锦 repo 内实际位置为准，并同步更新本指针。
