# SKILLS Index — Procedural Memory（层 3）

Attach-on-demand 的 procedural skill 索引。每个 skill 是"当 X 触发 → 照 Procedure 走"的可复用打法，按需 attach，正文不 freeze 进 context。

**这是权威工作索引** —— `/capture-skill` 写时扫的就是它（查重 gate 读这里）。`colar-memory/MEMORY.md` 的 `## Skill Pilot` 段是 attach-率监测笔记，defer 到本文件。

> 写时纪律：新 skill 必过 `/capture-skill` 的 4-类查重 gate（重复跳过 / 升级改旧 / 细化加 pointer / 正交新建）。落盘后 `/ship` 提交（skill 住 colar-agents project repo，version-controlled）。

## Skills

- [nextjs-hmr-proactive-restart](./nextjs-hmr-proactive-restart/SKILL.md) — Next.js dev server 跑着时，>3 文件批改 / 改 middleware / 改 server component / 加依赖 / 加路由 / 改 NEXT_PUBLIC_ env 后主动 nuke .next 重启，不依赖 HMR。Source: feedback_nextjs_hmr_restart_proactive
- [ui-design-emoji-discipline](./ui-design-emoji-discipline/SKILL.md) — 做 UI / CTA / 文案 / 状态指示 / 按钮场景默认禁 emoji，含 self-grill 列表 + grep cleanup。Source: feedback_emoji_in_ui_design
- [max-mode-protocol](./max-mode-protocol/SKILL.md) — 评估 idea / 重大方向 / high-stakes 决策走 Maximum Mode 陪审团：SKU 选择 + 显式触发 + 不启动 4 硬规则 + 重复 3 问闸门 + 24h 留白。Source: merged from feedback_idea_evaluation_maximum_mode + feedback_max_mode_explicit_trigger + feedback_max_mode_self_ritualization
- [eval-judge-variance-diagnosis](./eval-judge-variance-diagnosis/SKILL.md) — LLM-judge eval verdict 跨重跑抖动时先辨 variance 来源再修：读 reasoning，同输出→不同分=judge 变异(收紧 criteria)，不同输出→agent 变异(修 prompt)；probe 用 majority-of-3。Source: session-derived 2026-06-30
- [agent-prompt-edit-gate](./agent-prompt-edit-gate/SKILL.md) — 改 agent prompt body 强制跑 before/after eval 对比 pass rate，改 frontmatter 不触发；含四条铁律(退出码判 pass 别用管道 / 只跑 --agent / implementer 无工具沙盒 caveat / probe majority-of-3)。Source: migrated from CLAUDE.md 2026-08-04
- [ui-design-pipeline](./ui-design-pipeline/SKILL.md) — 界面设计任务四段 pipeline：Design Bridge 门卫(Replication 复刻 / Genesis 创世)→ frontend-design plugin 执行 → Frontend Developer 落地 → /diff·build·/review。Source: migrated from CLAUDE.md 2026-08-04
- [3d-intake](./3d-intake/SKILL.md) — 织锦 3D 换料素材入库两分支：A 服装 Block(CLO-SET 散包 → UV/材质槽体检 → 按材质名映射槽位 → dispose 含 origMat 漏网) · B 面料 PBR(ambientCG 整包留四通道，NormalGL 非 DX，AO 强制 channel=0 → 白坯 gain 归一化 → 去饱和+multiply 染色)。治「布料像塑料/染色发灰/换件吃满显存」。Source: session-derived 2026-08-10
- [silent-page-debug](./silent-page-debug/SKILL.md) — 页面打开只剩静态壳、JS 零报错时的诊断阶梯：三件装备(报错上屏含元素级分支 + 启动脚印 + 标题信标) → 自建日志服务器看请求序列(最硬证据) → AppleScript 读信标(不耗用户截图) → 干净 profile 分流 → vendor 依赖闭包(three.core.js 类转发壳)。含 headless 假证据清单。Source: session-derived 2026-08-10
- [spike-to-production](./spike-to-production/SKILL.md) — spike/playground 调通的成果搬进产品并上线的全流程，带人工审核 gate（Colar 肉眼验 playground，不通过就地打回，通过才进移植 loop）；配套 workflow.js 两 phase 编排（survey 只读勘察→【人工 gate】→port 移植+并发验证+部署前置，绝不自动部署）。治「以为搬过了其实产品里一行没落地 / 假设跨版本像素等价 / 资产另起 lane / 拿 build 绿当亲验」。Source: session-derived 2026-08-10
