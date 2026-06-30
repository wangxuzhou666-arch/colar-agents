# SKILLS Index — Procedural Memory（层 3）

Attach-on-demand 的 procedural skill 索引。每个 skill 是"当 X 触发 → 照 Procedure 走"的可复用打法，按需 attach，正文不 freeze 进 context。

**这是权威工作索引** —— `/capture-skill` 写时扫的就是它（查重 gate 读这里）。`colar-memory/MEMORY.md` 的 `## Skill Pilot` 段是 attach-率监测笔记，defer 到本文件。

> 写时纪律：新 skill 必过 `/capture-skill` 的 4-类查重 gate（重复跳过 / 升级改旧 / 细化加 pointer / 正交新建）。落盘后 `/ship` 提交（skill 住 agency-agents project repo，version-controlled）。

## Skills

- [nextjs-hmr-proactive-restart](./nextjs-hmr-proactive-restart/SKILL.md) — Next.js dev server 跑着时，>3 文件批改 / 改 middleware / 改 server component / 加依赖 / 加路由 / 改 NEXT_PUBLIC_ env 后主动 nuke .next 重启，不依赖 HMR。Source: feedback_nextjs_hmr_restart_proactive
- [ui-design-emoji-discipline](./ui-design-emoji-discipline/SKILL.md) — 做 UI / CTA / 文案 / 状态指示 / 按钮场景默认禁 emoji，含 self-grill 列表 + grep cleanup。Source: feedback_emoji_in_ui_design
- [max-mode-protocol](./max-mode-protocol/SKILL.md) — 评估 idea / 重大方向 / high-stakes 决策走 Maximum Mode 陪审团：SKU 选择 + 显式触发 + 不启动 4 硬规则 + 重复 3 问闸门 + 24h 留白。Source: merged from feedback_idea_evaluation_maximum_mode + feedback_max_mode_explicit_trigger + feedback_max_mode_self_ritualization
- [eval-judge-variance-diagnosis](./eval-judge-variance-diagnosis/SKILL.md) — LLM-judge eval verdict 跨重跑抖动时先辨 variance 来源再修：读 reasoning，同输出→不同分=judge 变异(收紧 criteria)，不同输出→agent 变异(修 prompt)；probe 用 majority-of-3。Source: session-derived 2026-06-30