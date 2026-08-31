# SKILLS Index — Procedural Memory（层 3）

Attach-on-demand 的 procedural skill 索引。每个 skill 是"当 X 触发 → 照 Procedure 走"的可复用打法，按需 attach，正文不 freeze 进 context。

**这是权威工作索引** —— `/capture-skill` 写时扫的就是它（查重 gate 读这里）。`colar-memory/MEMORY.md` 的 `## Skill Pilot` 段是 attach-率监测笔记，defer 到本文件。

> 写时纪律：新 skill 必过 `/capture-skill` 的 4-类查重 gate（重复跳过 / 升级改旧 / 细化加 pointer / 正交新建）。落盘后 `/ship` 提交（skill 住 colar-agents project repo，version-controlled）。

## Workflow 标准格式（Colar 2026-08-10 拍板：此后所有 workflow 照这个格式做）

参照实现：[spike-to-production](./spike-to-production/)。**一个 skill 目录 = 两个文件**：

```
<slug>/
  SKILL.md      # 人读的流程：When to Use / Procedure / Pitfalls / Verification / Why / Related
  workflow.js   # 机器跑的编排：同一套流程的可执行版
```

两件套的分工与硬约束：

- **SKILL.md 是唯一真相源**，`workflow.js` 是它的可执行投影。流程改了要同步改两处，
  别让编排和文档漂移。
- **workflow.js 顶部必须写 args 契约**（注释块），因为调用方只读得到 `meta`，读不到脚本正文。
  必填项缺失要**在脚本开头就抛错**，不要跑到一半才发现。
- **人工 gate 决定 phase 怎么切**：凡是需要人肉判断的环节（画质、观感、方向取舍），
  workflow 停不下来等人 → 就在那里切 phase，gate 落在两个 phase 之间的缝里。
  gate 后的 phase **必须硬性拒绝**无 gate 产物的调用（如 `phase:"port"` 不传 `plan` 直接抛错），
  否则那道 gate 形同虚设。
- **gate 前只读，gate 后才写**。survey 类 phase 不改任何文件，这样人还没点头之前跑一百遍都安全。
- **并发/串行按写冲突分**：只读勘察并发（`parallel`），改同一文件的必须单写者串行，
  验证类再并发。
- **绝不自动执行不可逆动作**（部署、push、删数据）。workflow 的终点是产出一份
  go/no-go 清单 + 交给 Colar 的完整命令。
- 教训沉淀进 SKILL.md 的 `## Pitfalls` 表（表格三列：坑 / 表现 / 解），同时把对应检查
  写进 workflow 相应 agent 的 prompt —— **只写文档不写进 prompt 的教训，下次不会被执行**。

## Skills

- [nextjs-hmr-proactive-restart](./nextjs-hmr-proactive-restart/SKILL.md) — Next.js dev server 跑着时，>3 文件批改 / 改 middleware / 改 server component / 加依赖 / 加路由 / 改 NEXT_PUBLIC_ env 后主动 nuke .next 重启，不依赖 HMR。Source: feedback_nextjs_hmr_restart_proactive
- [ui-design-emoji-discipline](./ui-design-emoji-discipline/SKILL.md) — 做 UI / CTA / 文案 / 状态指示 / 按钮场景默认禁 emoji，含 self-grill 列表 + grep cleanup。Source: feedback_emoji_in_ui_design
- ~~max-mode-protocol~~ — **已退役 2026-08-30**（目录已删）。内容 2026-08-05 已并回 memory `~/Desktop/colar-memory/feedback_max_mode_protocol.md`，那里是权威来源且更新（含 SKU→expert-panel 参数映射，旧 SKILL.md 没有）。SOUL § Strategic Frameworks 的 max mode 入口指向的也是该 memory 文件。**别重建同名 skill** —— 这条留着就是给查重 gate 看的。
- [eval-judge-variance-diagnosis](./eval-judge-variance-diagnosis/SKILL.md) — LLM-judge eval verdict 跨重跑抖动时先辨 variance 来源再修：读 reasoning，同输出→不同分=judge 变异(收紧 criteria)，不同输出→agent 变异(修 prompt)；probe 用 majority-of-3。Source: session-derived 2026-06-30
- [agent-prompt-edit-gate](./agent-prompt-edit-gate/SKILL.md) — 改 agent prompt body 强制跑 before/after eval 对比 pass rate，改 frontmatter 不触发；含四条铁律(退出码判 pass 别用管道 / 只跑 --agent / implementer 无工具沙盒 caveat / probe majority-of-3)。Source: migrated from CLAUDE.md 2026-08-04
- [ui-design-pipeline](./ui-design-pipeline/SKILL.md) — 界面设计任务四段 pipeline：Design Bridge 门卫(Replication 复刻 / Genesis 创世)→ frontend-design plugin 执行 → Frontend Developer 落地 → /diff·build·/review。Source: migrated from CLAUDE.md 2026-08-04
- [3d-intake](./3d-intake/SKILL.md) — 织锦 3D 换料素材入库两分支：A 服装 Block(CLO-SET 散包 → UV/材质槽体检 → 按材质名映射槽位 → dispose 含 origMat 漏网) · B 面料 PBR(ambientCG 整包留四通道，NormalGL 非 DX，AO 强制 channel=0 → 白坯 gain 归一化 → 去饱和+multiply 染色)。治「布料像塑料/染色发灰/换件吃满显存」。Source: session-derived 2026-08-10
- [silent-page-debug](./silent-page-debug/SKILL.md) — 页面打开只剩静态壳、JS 零报错时的诊断阶梯：三件装备(报错上屏含元素级分支 + 启动脚印 + 标题信标) → 自建日志服务器看请求序列(最硬证据) → AppleScript 读信标(不耗用户截图) → 干净 profile 分流 → vendor 依赖闭包(three.core.js 类转发壳)。含 headless 假证据清单。Source: session-derived 2026-08-10
- [spike-to-production](./spike-to-production/SKILL.md) — spike/playground 调通的成果搬进产品并上线的全流程，带人工审核 gate（Colar 肉眼验 playground，不通过就地打回，通过才进移植 loop）；配套 workflow.js 两 phase 编排（survey 只读勘察→【人工 gate】→port 移植+并发验证+部署前置，绝不自动部署）。治「以为搬过了其实产品里一行没落地 / 假设跨版本像素等价 / 资产另起 lane / 拿 build 绿当亲验」。Source: session-derived 2026-08-10
- [style3d-resource-sync](./style3d-resource-sync/SKILL.md) — 官方导出不可用的 SaaS（Style3D Cloud 面料/样衣/订单库）→ 织锦平台的同步打法：Copy as cURL 取 Bearer（不必搬 cookie）→ 列表+详情双拉合并 → 外部编码翻译 → 图片过 imaging 守卫 → 灌 sqlite 带备份。治九坑：端点名不可推导(猜 4 变体全 404) · 详情 data.data 双层只剥一层静默落空 · 列表有图无价/详情有价无图 · 成分缩写与中文词表断链致派生 tag 零命中(只在覆盖率统计里看得见) · normalize_for_provider 的 max_side 下界 960 不能拧松 · CC0 判据方向反了会挡掉真图 · stock_meters 映射清零既有库存 · 降质到底该退尺寸档 · 凭证 7 天过期让"全自动定时"成伪需求。Source: session-derived 2026-08-21
- [chinese-voice-input](./chinese-voice-input/SKILL.md) — macOS 中文语音输入 daemon（补 Claude Code 内置 `/voice` 不支持中文的缺口）：按住右 Option → sounddevice 采集 → 本地 mlx-whisper(`language=zh` 写死) → pynput `type()` 走 CGEventKeyboardSetUnicodeString 直插 Unicode 到聚焦窗口。音频只在内存、不写盘不上传，唯一网络行为是首次下权重（下完可 `HF_HUB_OFFLINE=1` 硬断网）。治：辅助功能权限没给/给了没 Cmd+Q 重启终端导致**静默失效**(最高频) · 权限按终端 App 授予不跨 App 继承 · 热键不能占 Ctrl+Space/Caps Lock(输入法切换) · 按需开麦致开头吃字 · Electron 应用掉字要调 TYPE_DELAY · 短句语言自动检测会判成日语。刻意不做 TTS / 双向语音 / hook 集成 / 多语言（2026-08-27 拍板）。Source: 照抄 jvosloo/claude-voice 核心链路 2026-08-27
- [wt-discipline](./wt-discipline/SKILL.md) — git worktree 纪律：一律走 `scripts/wt` 包装（new/run/ls/rm/gc/main），落点固定 ~/.wt/<repo>-<用途>；三条铁律=不 cd 进 worktree（只用 wt run，子 shell 隔离 cwd）· 要留存的产物写 `wt main` 指的主仓 · rm 被拒先看别条件反射 --force。治六类实证坑：cwd 悬空满屏 ENOENT(6 次) · /tmp↔/private/tmp 别名让 remove 失配 · 防御式 rm -rf+prune 仪式(33 次)/worktree list(113 次) · 部署史随 worktree 永久丢失(2026-08-18 实证) · 落点四处开花 · .venv/node_modules 每次手搭。Source: session-derived 2026-08-18（全量扫 5297 session / 288 次调用）
