---
name: fabric-loop-pointer
description: 转发指针 → 织锦（fabric-agent-demo）开发循环 skill。当在裸 home lane（cwd=/Users/colar）说「走 fabric loop / 织锦开发循环 / 织锦审核 / 织锦生态体检 / fabric-loop」但项目作用域的真 skill 没 attach 时，用本指针拉起真配方。真配方（L1/L2 分层审核 + findings 分级 + handoff + 深度体检 machinery）在织锦 repo 内，本文件只负责把你导过去。
---

# fabric-loop（转发指针）

真正的 `fabric-loop` skill 是**项目作用域**的，挂在织锦 repo 内，只有 cwd 在 `~/Desktop/创业/fabric-agent-demo/` 下才自动 attach。Colar 常从**裸 home lane**（cwd=`/Users/colar`）说"走 fabric loop"，此时真 skill 不加载——本指针兜底。

**动作**：立即 Read 下面两个文件，按它们执行（别在本指针里现编流程）：

1. 主热路径 runbook（每轮都读）：
   `Read /Users/colar/Desktop/创业/fabric-agent-demo/.claude/skills/fabric-loop/SKILL.md`

2. L2 深度体检 machinery（只在批次/里程碑/体检时读）：
   `Read /Users/colar/Desktop/创业/fabric-agent-demo/.claude/skills/fabric-loop/fabric-loop-l2-checkup.md`

读完就把当前会话当作真 `fabric-loop` skill 在跑——从 Phase 0 开场恢复起（含 `cd $(git rev-parse --show-toplevel)`）。本指针无独立逻辑，唯一职责是转发。
