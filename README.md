# colar-agents

我自己跑 Claude Code 的工作流框架。底层 agent 池 fork 自 [msitarzewski/agency-agents](https://github.com/msitarzewski/agency-agents)，上面这一层 —— Tier 1/2/3 任务分流、Money Finder 4 平台深挖、SOUL ↔ Memory 双层人格、UI/UX Design Bridge 门卫 —— 是我跨设备同步个人 AI 助手时长出来的，跨多个项目 daily driver。

朋友路过想抄哪段直接拿，issue 我可能不回。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

---

## 三层"分层"

这个 repo 真正区别于上游 fork 的不是 agent 数量,是三套完全不同的"分层"机制叠在一起。看完这一节基本就知道值不值得抄。

### 1. Tier 1/2/3 — 按任务规模分流执行节奏

起因是早期对所有任务都跑 plan→review 流程,改个 typo 都要 5 分钟开场白。后来按预期耗时拆三档:

| Tier | 适用场景 | 流程 |
|---|---|---|
| **Tier 1** (< 30min) | 单文件 / 单函数修改 | `act → /diff → commit`,不 plan 不 review |
| **Tier 2** (30min~2h) | 跨文件改动 | 加载上下文 → 选 1-3 agent → YOLO 执行 → /diff → build → /review → save memory → commit |
| **Tier 3** (2h+) | 跨 session 重构 / 新系统 | EnterPlanMode 出完整方案 → 子模块小步 commit → 每 milestone 验证 → /review → PR |

完整规则在 [CLAUDE.md](CLAUDE.md) 顶部。时间口径都是用 Claude Code 协作的预期耗时,不是手写代码的耗时。

> 配套规则:Memory Save 节点只存非显而易见的内容(被排除的方案及原因 / 关键架构决策的 trade-off / 下次 session 需要继承的上下文)。代码模式、文件路径、git 历史这些直接读代码,不进 memory。

### 2. 三层 agent 自动发现 — 单一真相源 + 项目分层

agent 文件按以下结构分布,Claude Code 自动发现,调用时不用手动指定:

```
~/.claude/agents/                ← Tier 1: 全局万能 agent,所有项目可用
<project>/.claude/agents/        ← Tier 2: 按项目精选的专项 agent
~/Desktop/colar-agents/         ← Master library: agent 源(不直接加载)
```

> agent 数量随项目演化变化,不在此处声明。当前快照: `ls ~/.claude/agents/ | wc -l`。

**Master library 是单一真相源**。每个项目的 `.claude/agent-config.yaml` 声明需要哪些 agent,跑 [scripts/sync-all.sh](scripts/sync-all.sh) 从 master 复制到项目。不在 master 之外手写 agent,避免 N 份漂移。

新加 agent 到项目: 编辑 `.claude/agent-config.yaml` → `bash scripts/sync-agents.sh <project-path>`。

### 3. SOUL ↔ Memory 双层人格 — 稳定 axioms vs 易变事实

跨 session 维持一致人格的最大坑是: 把易变事实(评估中的方向、求职状态、portfolio 数字)写进 SOUL,导致 6 个月后 SOUL drift 还不自知。我的拆法:

| 层 | 职责 | 例子 |
|---|---|---|
| **SOUL.md** | 不变的 axioms: voice / boundaries / 数学公式输出格式 / 时间锚点纪律 | "默认中文"、"no emoji unless first"、"chat 里不准用 LaTeX 源码" |
| **Memory** | 易变事实 + 演进型 framework: 项目状态、feedback、reference、predictions | "VC 五问 v0.6 正在评估 idea X"、"2026-04-21 AgentEval PAUSED" |

**三条防漂移护栏**:

1. **写 memory 时**(语义最热): 新 memory 否定 / 升级了 SOUL 某段?立即手动同步
2. **手动跑 drift 扫描**: `bash scripts/drift-check.sh` 扫黑名单 + 失效路径,命中输出 advisory(不阻断)。当前 Stop hook 用于 git sync 提醒,**未**接 drift-check
3. **改 SOUL 时**: 反向 grep memory 列出该 deprecate 的旧措辞

判断口诀: 如果一条声明在 6 个月后可能变,它就该住 Memory 不住 SOUL。

---

## Repo layout

```
colar-agents/
├── CLAUDE.md                ← Tier 分流 + UI/UX pipeline + agent 发现机制
├── soul/
│   ├── SOUL.md              ← 稳定 axioms (voice / 边界 / 公式输出 / 时间锚点)
│   ├── drift-blacklist.txt
│   └── drift-whitelist.txt
├── scripts/
│   ├── sync-all.sh          ← 同步所有项目的 agent 配置
│   ├── sync-agents.sh       ← 同步单个项目
│   ├── drift-check.sh       ← 手动跑 (未自动接 Stop hook)
│   ├── convert.sh           ← 多工具集成转换
│   └── install.sh           ← 多工具集成安装
├── engineering/             ← 工程类 agent
├── design/                  ← UI/UX/品牌
├── marketing/               ← 多平台内容运营
├── sales/                   ← B2B 销售
├── paid-media/              ← 付费投放
├── product/                 ← 产品管理
├── project-management/      ← 项目协调
├── testing/                 ← 测试 / QA
├── support/                 ← 运营 / 财务 / 法务
├── spatial-computing/       ← AR/VR/XR
├── specialized/             ← 跨界专项
├── academic/                ← 学术 / 世界观构建
├── game-development/        ← 游戏开发 (Cross-engine + Unity / Unreal / Godot / Blender / Roblox)
└── integrations/            ← Cursor / Aider / Windsurf 等导出
```

完整 agent 列表 (按 division 分类带 specialty + 使用场景): [agents/INDEX.md](agents/INDEX.md)

---

## Quick Start

只走 Claude Code 主路径。其他 IDE (Cursor / Aider / Windsurf / Copilot 等 10 种) 看 [integrations/README.md](integrations/README.md)。

```bash
# 1. clone master library
git clone https://github.com/wangxuzhou666-arch/colar-agents.git ~/Desktop/colar-agents

# 2. 同步全局通用 agent 到 ~/.claude/agents/
bash ~/Desktop/colar-agents/scripts/sync-all.sh

# 3. 在项目里声明专项 agent
cd <your-project>
mkdir -p .claude
# 创建 .claude/agent-config.yaml,写入需要的 agent slug
bash ~/Desktop/colar-agents/scripts/sync-agents.sh "$(pwd)"
```

如果你 fork 自用: 每个项目我只声明 4-7 个 agent,多了 Claude 选不准。

---

## 几个真跑过的 pipeline

每周都在用的三个,触发词驱动。其他还有 Money Finder Lite/Mid/Max 三档、Sunk Cost 闸门 等,慢慢补。

### Money Finder (4 平台深挖)

触发词: `money finder`。在小红书 / 抖音 / B 站 / 微信公众号四个平台同时挖一个 idea 的真实信号 —— 不是搜"有没有人做过",是看用户在哪发牢骚、什么场景下愿意付费。

锁死英文触发词是因为之前用"机会扫描"之类的中文词,Claude 总把它理解成搜券找补贴。

### Idea Maximum Mode (17-agent 陪审团)

触发词: `max mode`。评估创业 idea 默认走 17 个对抗性 agent 的并行陪审团模式,反 yes-man 是硬保险。Lite 模式 (3 agent) 会被 Claude 自身的讨好倾向带歪。

带闸门: ≥1500 字 brief 或 ≥4h 投入才允许启动 max mode,避免流程仪式化。

### UI/UX Design Bridge (设计前置门卫)

任何 UI 设计任务必经的前置 agent。它先确定目标品牌 (74 个可选: Linear / Stripe / Notion / Apple / Vercel / Spotify ...) → fetch 对应的 DESIGN.md → 输出 `instructions-{brand}.md` → 后续消费方是主 loop 的 skill 方案 (frontend-design plugin) 和 Frontend Developer。

不跳过。即使是"改个按钮颜色",也先检查 design spec 存不存在。

---

## 致谢

底层 agent 池原型来自 [msitarzewski/agency-agents](https://github.com/msitarzewski/agency-agents),命名风格 (Whimsy Injector / Rapid Prototyper / Reality Checker) 我直接保留了 —— 当 placeholder 比我自己想 12 个 division 名字省脑。

真正改造的是上面那一层: Tier 分流、三层发现、SOUL/Memory、Design Bridge、Money Finder、Idea Maximum Mode 这些工作流,跟原 repo 已经没什么关系。

---

## License

MIT。

---

> 这是个人工作系统不是 OSS 产品。issue / PR 我会看但响应慢,主要因为修一个跨 repo 的 sync 脚本对我有 ROI,对 fork 我的人不一定。
