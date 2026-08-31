# Agent Index

> **Auto-generated** by `scripts/gen-agent-index.py`. Do not hand-edit — re-run the script after adding/removing agents.

底层 agent 池按 division 分类。Claude Code 按任务自动选 1-5 个组合调用,不需要手动从下面这张表里挑。

> 命名风格 (Whimsy Injector / Rapid Prototyper / Reality Checker 等) 沿用上游 [msitarzewski/agency-agents](https://github.com/msitarzewski/agency-agents)。

跳转: [Engineering](#engineering) · [Design](#design) · [Specialized](#specialized)

---

## Engineering

| Agent | Specialty | When to Use |
|-------|-----------|-------------|
| 🔧 [Agent Infra Engineer](../engineering/engineering-agent-infra.md) | Specialist for Colar's Claude Code AI system maintenance and evolution. Use when modifyin… | Builds the systems that make the other agents work better. |
| ⚗️ [Applied AI Engineer](../engineering/engineering-applied-ai.md) | LLM application engineering specialist for LangGraph orchestration (idempotent pure-funct… | Builds LLM pipelines that hold their output contract — graph nodes, prompts, and evals th… |
| 👁️ [Code Reviewer](../engineering/engineering-code-reviewer.md) | Expert code reviewer who provides constructive, actionable feedback focused on correctnes… | Reviews code like a mentor, not a gatekeeper. Every comment teaches something. |
| 🖥️ [Frontend Developer](../engineering/engineering-frontend-developer.md) | Frontend specialist for React/Next.js UI components, client-side performance, and browser… | Builds responsive, accessible web apps with pixel-perfect precision. |
| 💎 [Senior Developer](../engineering/engineering-senior-developer.md) | Full-stack implementation specialist for Next.js/React/TypeScript/Tailwind projects. Hand… | Senior full-stack craftsperson — Next.js, React, TypeScript, Python. |

## Design

| Agent | Specialty | When to Use |
|-------|-----------|-------------|
| \U0001F308 [Design Bridge](../design/design-bridge.md) | DESIGN.md translator with two modes — REPLICATION: fetches an existing brand's design sys… | Translates any brand's design DNA into pixel-perfect implementation specs. |

## Specialized

| Agent | Specialty | When to Use |
|-------|-----------|-------------|
| 🧪 [VC 模型 Critic](../specialized/idea-vc-critic.md) | Colar 私人创业 idea 评估对话伙伴 — 走 VC 五问 + JTBD lens + R1 reality check（v0.6）。启动即进 CONFIDENTIAL 模… | 不是 yes-man，也不是怀疑论。在结构位上推一把，在 sunk cost 上拉一把。 |

---

_Total: 7 agents across 3 divisions. Generated from filesystem — single source of truth is the .md files themselves._
