---
name: max-mode-protocol
description: 评估创业 idea / 重大方向 / high-stakes 决策时,走 Maximum Mode 多 agent 陪审团。本 skill 含完整 protocol — SKU 选择 (17/7/4/3/2 agent) + 显式触发关键词 + 不启动的 4 条硬规则 + 重复 max mode 的 3 问硬闸门 + 24h 留白原则。Use when: Colar 提评估 idea / 求职选择 / 创业方向 / 回国留美决策 / 重新评估已 PAUSE/KILL 项目,或显式说出 "max mode" / "陪审团" 等关键词。
version: 1.0.0
source: merged from feedback_idea_evaluation_maximum_mode + feedback_max_mode_explicit_trigger + feedback_max_mode_self_ritualization (migrated 2026-05-24)
---

## When to Use

### A. 显式触发(关键词命中即立刻启,不询问不延迟)

| 类别 | 关键词 |
|---|---|
| max mode 名称 | `max mode` / `Maximum Mode` / `启 max` / `启动 max` / `上 max` / `走 max` |
| 强调式 | `这个 max mode` / `我要 max` |
| 数量名称 | `17 agent` / `17 个 agent` / `陪审团` / `专家陪审团` |

### B. 被动识别(命中触发词时主动提议升级)

- "分析这个 idea" / "讨论一下我的方向" / "这个想法值不值得做"
- "帮我验证 XX 是不是真需求" / "评估机会" / "仔细讨论" / "重新讨论"
- "我有个新想法" / "能不能做 XX" / "XX 值得花时间吗"
- 涉及 VC 三问任一维度的判断(位置 / 止痛药 / 铲子 / 护城河 / 付费意愿)

## Procedure

### Step 1: 先过两个 gate(都不通过则降级或拒启)

**Gate 1 — Sunk-Cost Gate**(项目层): 见 `feedback_sunk_cost_gate_pre_brief`
- brief ≥ 1500 字 OR 项目 ≥ 4h 投入 → 必答 3 问才允许启 max mode

**Gate 2 — Self-Ritualization Gate**(流程层,本 skill 内嵌):
触发条件(任一命中即启 gate):
- 该对象历史已跑过 ≥1 次 max mode
- 上次 max mode 结论是 PAUSE / KILL / NO-GO
- 距上次 max mode < 30 天且无新外部事实

3 问硬闸门(必须 Colar 文字回答,不是 Claude 推断):

| Q | 问题 | 通过条件 | 不通过 → |
|---|---|---|---|
| Q1 | 信息增益: 这次能跑出什么是上次不可能跑出的结论? | 答出 ≥1 条具体新事实/新对照 | 直接套用上次结论 |
| Q2 | 对照替代: 有没有比再跑一次 max mode 更高 ROI 的方式?(platform mining / 单 agent 验证 / 1 周实测) | 答"没有更高 ROI 替代" | 走替代方案 |
| Q3 | 仪式化自检: 如果不启动会不会焦虑? 是不是 sunk cost 的延续? | 答"不会焦虑/能放下" | 24h 冷静期 |

### Step 2: 选 SKU(按 brief 类型 + 投入)

| SKU | agent 数 | 适用场景 | 耗时 |
|---|---|---|---|
| **17-agent Full Max Mode** | 17 | 全新 idea 商业评估 / 重大方向决策(创业 / 求职 / 回国留美) | 1-2h |
| **7-agent MVMM** | 7 | P2/P3 项目方向评估 / 已知部分背景 | 30-45min |
| **4-agent P3 工具评估** | 4 (R7+D1+D3+A3) | 自用 P3 工具的 kill/maintain/invest(trending_aggregator 类) | 15-25min |
| **3-agent Quick Mode** | 3 (R7+D1+D3) | 快速 idea sanity check | 10-15min |
| **2-agent mini-quick** | 2 (D3+R7) | sunk-cost gate 不通过的降级路径 | 5-10min |

### Step 3: 不启 max mode 的 4 条硬规则(即使关键词命中也降级)

1. **轻投入**: 项目 < 2h 且 brief < 800 字 → 直接 D3 单 agent
2. **用户已自查**: 用户已能说出 ≥2 条 abort 条件 → 已具备自我诊断,max mode 是仪式
3. **同 pattern 第 3 次**: 同类项目第 3 次启 max mode → 不跑流程,套已有 SOP(`feedback_p3_tool_one_battle_sop`),问"为什么又来到这里"
4. **P0 红灯**: Colar 主线 P0(毕业 / 实习 onboarding)当周 → 降级 mini-quick mode

### Step 4: 执行层 — SKU 映射到 /expert-panel(不再照名单手动 spawn)

> ⚠️ **下方视角配方是 master library 库存名单,不是可 spawn 菜单。** 当前部署仅 ~16 个 agent(以 `ls ~/.claude/agents/` 和系统注入的 available agent types 为准),配方中大多数 agent 未部署——未部署的直接 spawn 必然 Agent tool 连环失败。编排一律走 `/expert-panel` workflow(已封装并发 fan-out + 证据门控 + 对抗验证 + 保留异见合成);未部署的视角用 `general-purpose` + lens 扮演,或先 `ln -s` 部署再 spawn。

**SKU → expert-panel 参数映射**(SKU 选择纪律与 gate 决策不变,只换执行层):

| SKU | experts(显式 cast,agentType 必须已部署) | maxRounds | verifyVotes | budget |
|---|---|---|---|---|
| 17-agent Full Max | 5-6 个 lens(按下方视角配方裁剪,缺位视角用 general-purpose + lens 顶) | 不传(给 budget 跑到耗尽) | 2-3 | "+500k" 级 |
| 7-agent MVMM | 4 | 2 | 2 | "+200k" 级 |
| 4-agent P3 工具评估 | 3(R7/D1/D3/A3 对应 lens 合并) | 1 | 1 | 不传 |
| 3-agent Quick Mode | 2-3(R7/D1/D3 lens) | 1 | 1 | 不传 |
| 2-agent mini-quick | 不走 panel——直接 2 个 Agent 调用(D3+R7 lens),panel 开销不值 | — | — | — |

args 完整契约见 `workflows/expert-panel.js` 头注释:`question` 必传;`experts: [{agentType, lens}]` / `agentRoster`(传运行时可调用集,让 selector cast)/ `verifyVotes` / `maxRounds` / `budgetFloor`。

**原三 phase 结构 → panel 机制对应**(纪律保留,机制换壳):
- Phase 0 证据收集 + "每 agent 必须引用 ≥2 份证据" → panel 内建**证据门控**(每条 claim 过 gate)
- Phase 1 多视角并行讨论 → panel 并发 fan-out(experts × lens)
- Phase 2 红队/reality-check 串行对抗 + NEXUS 仲裁 → panel **对抗验证**(verifyVotes 个 skeptic)+ **保留异见合成**(verify 先于 synthesize,顺序内建)
- Phase 3 验证资产生成(可选) → panel 结束后按需单独 spawn **已部署** agent(如 marketing-xiaohongshu-specialist)

**Full Max 视角配方**(lens 素材库,供撰写 experts 的 lens 字段用;⚠️ 非 spawn 名单,见上方警告):
- 信息收集 lens:知乎/抖音/B站/Twitter/Reddit/跨境电商平台信号 + 竞品调研 + 趋势纵深
- 讨论 lens:信号 vs 噪音 / JTBD 合成 / 决策瓶颈 / 付费意愿 / 跨文化盲点 / problem → MVP
- 对抗 lens:红队全力杀 idea / VC 五问 reality check(默认 NEEDS WORK)/ NEXUS 最终战略仲裁

### Step 5: 24h 留白(反 automation bias 硬保险)

max mode 跑完后,**SOP / memory / 项目状态变更不立即落盘**(除非 Colar 显式说"立刻执行"):
- 14+ 份报告 + NEXUS 判决信息超载式权威
- 24h 内 Colar 在无 Claude 在场情况下能复述判决和理由(一句话) → 才落盘
- 立即可执行的物理动作(注销 cron / delete file)可现做
- 新 SOP / 新 memory 文件 / 项目降级标注应等 24h

## Verification

执行后必报告:
- 哪个 SKU 选了 + 为什么 + 映射成的 expert-panel 参数(experts / maxRounds / verifyVotes / budget)
- 证据门控结果(panel 每条 claim 过 gate 情况,防纯假设推理)
- reality-check lens 通过门控可能为 0 条,如实报,不为交付硬挑
- 24h 留白状态: 哪些已落盘,哪些 pending

## Pitfalls

- **spawn 前先查部署列表**: `ls ~/.claude/agents/` + 系统注入的 available agent types 才是可调用集;视角配方/库存名单里的 agentType 不在其中 = 不可 spawn,用 general-purpose + lens 顶或先 `ln -s` 部署
- **对抗必须先于合成**: /expert-panel 已内建(verify → synthesize 顺序);若在 panel 外手动补跑红队 lens,其输出必须进合成输入,不得与合成并行 — 否则仲裁没看到 red team 输出
- **token 不省**: max mode 核心价值是判断质量,不是省 token
- **默认 `run_in_background=true`** 启 panel / agent,不阻塞 Colar 对话
- **数据不足时**: 让 panel 自己判断该不该投入收集 vs kill,不替他延迟
- **brief 非标准 idea discovery**(工具评估 / 架构决策): 适配 lens 配方到 brief 实际问题,保持"证据 → 多视角 → 对抗 → reality check"结构不变,不必凑 agent 总数

## Why This Skill Exists

合并自 3 个互补 feedback（三者均已 migrate 进本 skill 后归档，源文件不再单独存在，下列仅记历史来源）:
- 默认 protocol(被动识别 + 5 SKU 选择): 来自 `feedback_idea_evaluation_maximum_mode`
- 显式触发(关键词立刻启 + 4 条硬规则): 来自 `feedback_max_mode_explicit_trigger` (2026-04-26 Colar 明确说 "我要这个 max mode 我不需要被动触发")
- 自仪式化 gate(重复 max mode 3 问硬闸门): 来自 `feedback_max_mode_self_ritualization` (2026-04-27 trending_aggregator 第 2 次 max mode 实战印证流程仪式化是真陷阱)

## Related

- `feedback_sunk_cost_gate_pre_brief` — 内容投入 gate(本 skill 前置)
- `feedback_p3_tool_one_battle_sop` — 同 pattern 第 3 次的退出 SOP
- `feedback_vc_structural_thinking` / `frameworks/vc-model/spec/v0.6.md` — VC 五问 spec(reality-checker 用)
- `feedback_privacy_defaults`（原 feedback_startup_ideas_confidential，2026-07-06 三合一） — 所有 agent prompt 顶部注入 CONFIDENTIAL 约束
- `feedback_ai_era_moat` — 原创判断层验证(Phase 0 R7 + Phase 2 A1/A2 共同执行)
