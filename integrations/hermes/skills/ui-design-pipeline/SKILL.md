---
name: ui-design-pipeline
description: "所有界面设计任务必走的四段 pipeline —— Design Bridge（门卫，Replication 复刻 66 品牌 / Genesis 原创创世 二选一，产出 instructions-*.md）→ 设计执行（frontend-design plugin，主 loop 直接处理）→ Frontend Developer 实现 → /diff·build·/review。含触发词清单与「用户没指定品牌时给三条路、别把原创产品硬塞现成品牌」的判据。Use when: the task involves UI design, visual style, component libraries, CSS architecture, or interaction patterns — including \"设计 / UI / 界面 / 样式 / 风格\", new frontend pages, redesigns, or any brand named as a visual reference (\"像 Linear 那样\")."
version: 1.0.0
source: migrated from colar-agents/CLAUDE.md (2026-08-04 /doctor check 4 — 常驻正文迁 attach-on-demand)
---

## When to Use — 触发条件（满足任一即走此 pipeline）

- 用户说"设计"、"UI"、"界面"、"样式"、"风格"
- 新建前端项目或页面
- 重构/重新设计已有界面
- 用户提到任何品牌名作为视觉参考（如"像 Linear 那样"）

凡涉及 UI 设计、视觉风格、组件库、CSS 架构、交互模式的任务，**不要用通用 agent 凑**。

## Pipeline

```
① Design Bridge（前置，必经）— 两种模式二选一
   ├── Replication（对标现成品牌）：确定目标品牌 → fetch DESIGN.md → 输出 instructions-{brand}.md
   └── Genesis（原创产品创世，原创项目推荐）：客户画像 + 调性 + 品类 + N 个灵感参考
       → 合成原创自洽 DESIGN.md → 输出 instructions-genesis-{project}.md
   ↓
② 设计执行 — skill 方案，主 loop 直接处理（不再路由给专门 design agent）
   └── frontend-design plugin（Anthropic 官方）→ 组件设计、设计系统、视觉规范、CSS 架构
   ↓
③ Frontend Developer → 实现落地
   ↓
④ /diff → build → /review
```

> 2026-07-04 起 UI Designer / UX Architect 两个 design agent 已退役，视觉与 CSS 架构职能由 skill 方案接管。Design Bridge 的门卫地位不变，产出的 instructions 由主 loop（带 skill）+ Frontend Developer 消费。
>
> 2026-08-04 起 `ui-ux-pro-max` skill 已移除（与 frontend-design plugin / dataviz 在同一触发点上互相冲突，且它的目录式选型与「对齐现有设计系统、不自造风格」相悖）。CSS 架构 / layout / 响应式策略统一由 frontend-design plugin 承担；图表另见官方 `dataviz` skill。

## Design Bridge 是门卫

- **不跳过**：即使是"简单改个按钮颜色"，也先检查有没有已存在的 design spec
- **两种模式**：
  - **Replication（复刻）** — 对标现成品牌，66 品牌可选（Claude, Linear, Vercel, Stripe, Notion, Figma, Apple, Spotify 等），忠实还原单一来源 → 输出 `instructions-{brand}.md`
  - **Genesis（创世）** — 原创产品没有现成品牌可抄时，吃客户画像 + 调性 + 品类 + N 个灵感参考，**合成一套项目专属、自洽的原创 DESIGN.md** → 输出 `instructions-genesis-{project}.md`（保留 `instructions-` 前缀让 consumer 的 glob 仍命中，加 `genesis-` 区分原创 vs 复刻）。同样 9-section 格式，只是来源从"抄单一品牌"变成"从多灵感合成原创"
- **用户没指定品牌时**：主动给三条路 —— ① 对标现成品牌（Replication）② 为原创产品创造品牌（Genesis，**原创项目推荐默认**）③ 自己定（generic fallback）。**不要把原创新产品硬塞进一个不相干的现成品牌**，那是旧 pipeline 的烂路。

## 相关 skill

- [ui-design-emoji-discipline](../ui-design-emoji-discipline/SKILL.md) — UI / CTA / 文案 / 状态指示 / 按钮场景默认禁 emoji
