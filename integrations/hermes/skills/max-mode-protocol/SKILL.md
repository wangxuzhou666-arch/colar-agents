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

### Step 4: 17-agent Full Max Mode 工作流

**Phase 0 — 8 agent 并行信息收集**:
- marketing-zhihu-strategist / marketing-douyin-strategist / marketing-bilibili-content-strategist
- marketing-twitter-engager / marketing-reddit-community-builder / marketing-cross-border-ecommerce
- general-purpose × 2(竞品调研 + 趋势纵深)

**Phase 1 — 6 agent 并行多视角讨论**(每 agent 必须引用 ≥2 份 Phase 0 证据):
- product-trend-researcher(信号 vs 噪音)
- product-feedback-synthesizer(JTBD 合成)
- specialized-behavioral-decision-scientist(决策瓶颈)
- sales-discovery-coach(付费意愿)
- specialized-cultural-intelligence-strategist(跨文化盲点)
- product-manager(problem → MVP)

**Phase 2 — 3 agent 串行对抗筛选**:
- testing-agent-red-team-specialist(红队全力杀 idea)
- testing-reality-checker(默认 NEEDS WORK,VC 五问硬门控)
- general-purpose 扮演 NEXUS(最终战略仲裁)

**Phase 3 — 可选 4 agent 验证资产生成**:
- marketing-xiaohongshu-specialist / marketing-content-creator
- sales-discovery-coach(访谈脚本)/ engineering-rapid-prototyper(MVP 骨架)

### Step 5: 24h 留白(反 automation bias 硬保险)

max mode 跑完后,**SOP / memory / 项目状态变更不立即落盘**(除非 Colar 显式说"立刻执行"):
- 14+ 份报告 + NEXUS 判决信息超载式权威
- 24h 内 Colar 在无 Claude 在场情况下能复述判决和理由(一句话) → 才落盘
- 立即可执行的物理动作(注销 cron / delete file)可现做
- 新 SOP / 新 memory 文件 / 项目降级标注应等 24h

## Verification

执行后必报告:
- 哪个 SKU 选了 + 为什么
- Phase 1 每个 agent 引用了哪些 Phase 0 证据(防纯假设推理)
- Phase 2 A2 (reality checker) 通过门控可能为 0 条,如实报,不为交付硬挑
- 24h 留白状态: 哪些已落盘,哪些 pending

## Pitfalls

- **Phase 2 A1/A2/A3 必须串行**,不要并行 — 否则 NEXUS 没看到 red team 输出
- **token 不省**: max mode 核心价值是判断质量,不是省 token
- **默认 `run_in_background=true`** 启 agent,不阻塞 Colar 对话
- **数据不足时**: 让 max mode 自己判断该不该投入收集 vs kill,不替他延迟
- **agent 列表非标准 idea discovery**(工具评估 / 架构决策): 适配 17 agent 列表到 brief 实际问题,但保持 总数 17 + 三 phase 结构 + 对抗 + reality check

## Why This Skill Exists

合并自 3 个互补 feedback:
- 默认 protocol(被动识别 + 5 SKU 选择): 来自 `feedback_idea_evaluation_maximum_mode`
- 显式触发(关键词立刻启 + 4 条硬规则): 来自 `feedback_max_mode_explicit_trigger` (2026-04-26 Colar 明确说 "我要这个 max mode 我不需要被动触发")
- 自仪式化 gate(重复 max mode 3 问硬闸门): 来自 `feedback_max_mode_self_ritualization` (2026-04-27 trending_aggregator 第 2 次 max mode 实战印证流程仪式化是真陷阱)

## Related

- `feedback_sunk_cost_gate_pre_brief` — 内容投入 gate(本 skill 前置)
- `feedback_p3_tool_one_battle_sop` — 同 pattern 第 3 次的退出 SOP
- `feedback_vc_structural_thinking` / `frameworks/vc-model/spec/v0.6.md` — VC 五问 spec(reality-checker 用)
- `feedback_startup_ideas_confidential` — 所有 agent prompt 顶部注入 CONFIDENTIAL 约束
- `feedback_ai_era_moat` — 原创判断层验证(Phase 0 R7 + Phase 2 A1/A2 共同执行)
