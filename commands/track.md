---
description: 长线任务防漂移编排器 — 冻结计划成 artifact + 绑 TodoWrite + 每 checkpoint 强制 re-grounding，收尾接 verify-gate
argument-hint: "[task slug，一句话描述任务，可选]"
---

# /track — 长线任务防漂移编排器

给**多步、跨若干轮、容易中途跑偏**的任务用。解决三件事:
1. **计划外置冻结** — 把目标+步骤+验收标准写成文件,对抗 context 冲刷(工作记忆漂移的物理根因)。
2. **注意力串行化** — 从 plan 播种 TodoWrite,每个执行步配一个 verify 步。
3. **中途 re-grounding** — 每到 checkpoint 强制回读 plan、自检"是否还在服务原目标"。

与 BACKLOG 系统互锁:plan 文件是**单任务**的;session 中断时未完成 todo 由 Stop hook 自动落进 `colar-memory/BACKLOG.md`,下次 SessionStart 自动召回。所以 /track 管"这一仗怎么打不跑偏",BACKLOG 管"跨 session 别忘了还有这一仗"。

## 触发场景

- 用户显式 `/track` / "开个长线任务" / "这个别做着做着跑偏了"
- 任务 ≥ 4 个实质步骤,或预计跨多轮对话 / 需并行多 agent
- 任务有明确验收标准但执行链长,中途容易被岔开

**不该用**:单步/机械任务(直接做);纯探索无固定目标(那是 research,走 /deep-research)。

## 执行流程

### Step 1:冻结计划(写 artifact)

在项目 `.claude/plans/` 下写 `plan-<slug>.md`(不存在则建目录):

```markdown
# PLAN: <task 一句话>
_frozen: <YYYY-MM-DD> · status: active_

## 北极星(North Star)
<一句话。执行中每次 re-grounding 对照这句,不是对照"我刚才在想啥">

## Scope / Non-Goals(冻结边界)
- IN:  <明确要做的>
- OUT: <明确不做的 —— 防 scope creep,冒出来的"顺手也做了 X"先扔 BACKLOG 不塞进来>

## 步骤(有序契约)
1. <step> → verify: <客观信号:build/test/命中某输出>
2. ...

## 已知坑 / 风险
- <踩过的雷 / 依赖的外部未知>

## Checkpoint 日志(执行中追加)
- <YYYY-MM-DD HH:MM> done N/M · <一句话进展 + drift 自检结论>
```

写完告诉 Colar plan 路径 + 北极星那句,让他有机会**在冻结前 challenge 方向**(方向错了,后面步骤全白跑)。

### Step 2:从 plan 播种 TodoWrite

- 每个 plan 步骤 → 一个 execution todo。
- **每个 execution todo 后紧跟一个 `verify: <客观信号>` todo**(这是 self-critic 的默认闸门:不靠"我觉得对了",靠 build/test/独立 review)。
- 任何时刻只 1 个 in_progress。

### Step 3:执行 + Checkpoint re-grounding

每完成一个里程碑(或每 ~3 个 subtask,取先到),**强制**做一次 re-grounding,不许顺着惯性冲:

1. 回读 `plan-<slug>.md` 的北极星 + Scope。
2. 追加一行 Checkpoint 日志:`done N/M · <进展> · drift 自检:<还在服务北极星? 有没有滑出 Scope?>`。
3. 若发现漂移 → 停,明确告诉 Colar「偏了,原目标 X,现在滑向 Y,拉回还是改 plan?」。

**中途冒出的新任务**:阻塞当前 → 插到当前 subtask 后;独立 → 不塞进本 plan,扔 TodoWrite 尾部或口头记「进 BACKLOG」。绝不"待会儿记得做"——凡"待会儿"必落盘。

### Step 4:收尾(verify-gate + 沉淀)

- 跑完所有 verify todo,客观信号全绿才算完。关键改动过 `/code-review` 或独立 review agent(同 context 自审有确认偏误)。
- 把 plan status 改 `done`。
- **回顾**:这次有没有返工/踩雷?有 → 一句话 lesson,`/capture-skill` 或写 `feedback_*.md`(把"想起来总结"变成默认动作,喂给 gap D)。
- 收尾一键化可直接走 `/ship`。

## 与其他机制的接口

| 机制 | /track 怎么用它 |
|---|---|
| BACKLOG hooks | 中断时 open todo 自动落盘 → 下 session 召回,不依赖记忆 |
| TodoWrite | plan 步骤的运行时投影,单 in_progress 串行化注意力 |
| /code-review · review agent | Step 4 verify-gate 的独立审 |
| /capture-skill · feedback_*.md | Step 4 回顾把 lesson 固化,防重蹈覆辙 |
| /ship | Step 4 收尾一键化 |
| Workflow 工具 | 步骤多且可并行/扇出时,把 plan 编译成确定性 pipeline 而非靠我记着串 |
