# Colar 助手 (colar-agents) — 工作流框架

## Task Tier Selection

根据任务规模选 Tier，不要对所有任务用同一套流程。

> ⏱️ **时间口径**：以下所有时间估计都是**使用 AI（Claude Code）协作完成**的预期耗时，不是手写代码的耗时。

### Tier 1 — Micro（< 30min，单文件/单函数修改）

```
act → /diff → commit
```

不需要 plan，不需要 review，直接改。

---

### Tier 2 — Feature（30min~2h，跨文件改动）

```
① 加载上下文（读相关文件，识别依赖）
② classify → delegate（过路由协议分类任务，选 1-3 个专项 agent；独立子任务默认 fan-out 并行）
③ 输出方案（架构决策 + 影响范围 + 风险点）
④ YOLO 执行（act then inform，不中途停下来问）
⑤ /diff（在 build 之前看，提前发现方向偏差）
⑥ build / test 验证
⑦ /review（code quality + 安全 + 逻辑）
   ↳ 若本次改了**已覆盖 agent 的 prompt body** → 必跑 Agent Prompt-Edit Gate（before/after eval 对比，见上方专节）
⑧ save memory（非显而易见的决策） + SOUL drift check
   ↳ 若新 memory 否定/升级了 SOUL.md 某条声明，立即同步 SOUL（手动）
   ↳ 想跑 drift 扫描：`bash ~/Desktop/agency-agents/scripts/drift-check.sh`（当前未自动接入 Stop hook）
⑨ commit
```

---

### Tier 3 — Architecture（2h+，跨 session 重构/新系统）

```
① 加载 memory + 上下文（读 MEMORY.md + README + git log）
② classify → delegate（过路由协议；Workflow Architect 编排 + 相关专项，并行 fan-out 上限 5 个）
③ EnterPlanMode → 完整方案（含数据流/接口/风险/被排除方案）
④ 确认方案后 ExitPlanMode，开始执行
⑤ 每个子模块完成 → /diff → 小步 commit
⑥ build / test（每个 milestone 验证一次，不是最后才跑）
   ↳ 若重构涉及**已覆盖 agent 的 prompt body** → 必跑 Agent Prompt-Edit Gate（before/after eval 对比，见上方专节）
⑦ /review
⑧ save memory（关键架构决策的 trade-off + 被排除方案的原因） + SOUL drift check
   ↳ 架构性变更尤其容易让 SOUL 过期 — 写完 memory 后立即同步 SOUL 受影响段落
   ↳ 手动跑 `bash ~/Desktop/agency-agents/scripts/drift-check.sh`；改 SOUL 后反向 grep memory 列 deprecate 候选
⑨ PR
```

---

## Agent Prompt-Edit Gate（改 agent prompt 必跑 eval）

**凡改动 agent prompt body（master `.md` 的 frontmatter 之后正文），强制 before/after 跑 eval 对比 pass rate。** 这是层 4 eval 存在的唯一目的——别再盲改 prompt。改 frontmatter（routing metadata：`description` / `route-to-me-when` / `tools`）不触发（eval 只测 output 行为，不测路由）。

### 触发与动作

| 改的是 | 动作 |
|---|---|
| **已覆盖 agent** 的 prompt body（`code-reviewer` / `senior-developer` / `ui-designer`） | **强制 gate**：改前跑 baseline → 改 → 再跑对比；pass rate 掉 or degradation-probe case 翻 FAIL = 这次改伤了 agent，回退或修 |
| **未覆盖 agent** 的 prompt body（其余所有） | **无 eval 覆盖 = 盲改**。告知 Colar「{agent} 无 eval case，改 prompt 飞盲；要先补 4 个 case 再改吗？」按 SOUL ask-when-uncertain 处理 |

### 命令（单 agent 迭代用 `--agent`，别跑全量 24 calls）

```bash
cd ~/Desktop/agency-agents
bash eval/run-eval.sh --agent code-reviewer    # baseline，改 prompt 之前
# ... 改 engineering/engineering-code-reviewer.md 正文 ...
bash eval/run-eval.sh --agent code-reviewer    # after，对比 pass rate
echo $?                                          # 0=全 pass，1=有 FAIL（可 gate CI）
```

### 铁律

- **退出码判 pass/fail，别用管道**：`| tee` 让退出码取 tee（恒 0）掩盖 FAIL。要存 log 用 `bash eval/run-eval.sh 2>&1 | tee log.txt; exit ${PIPESTATUS[0]}`，否则裸跑 `; echo $?`。
- **全量 ~24 Opus calls 有真实 token 成本**，改单 agent 只跑该 agent（`--agent`），smoke 用 `--case`。别随手跑全套。
- **implementer 类（senior-developer）validity caveat**：纯 `claude -p` 无工具沙盒会让 implementer 退回"描述计划"而非贴代码；`sd-` 实现 case 已用「显式声明无工具→直接贴代码」修，degradation-probe `sd-no-architect-overreach` 两种环境都 valid。bare 实现 prompt 在此 FAIL 多半是环境错配不是 prompt 退化——别据此回退生产 prompt。
- **master 是 symlink → 部署**，改 master 即时生效且 eval 读的就是 master，无需 sync。

详见 `eval/README.md`。覆盖面扩展（补 agent cases）见该 README「Adding a case」。

---

## Agent 自动发现（三层架构）

Agents 已按项目分层部署，Claude Code 自动发现，不需要手动指定：

```
Tier 1: ~/.claude/agents/         ← 全局万能 agent，所有项目可用
Tier 2: <project>/.claude/agents/ ← 按项目精选的专项 agent
Master: ~/Desktop/agency-agents/  ← agent 源（不直接加载，通过 sync 脚本分发）
```

> 数量随项目演化变化，不在此处固定声明。当前快照：`ls ~/.claude/agents/ | wc -l`。

**同步方式**：每个项目的 `.claude/agent-config.yaml` 声明需要哪些 agent，运行 `bash scripts/sync-all.sh` 从 master library 复制到项目的 `.claude/agents/`。

**新增 agent 到项目**：编辑项目的 `.claude/agent-config.yaml`，然后运行 `bash ~/Desktop/agency-agents/scripts/sync-agents.sh <project-path>`。

**不要手动往 `~/.claude/agents/` 或 `.claude/agents/` 放文件**——用 sync 脚本管理，保持单一真相源。

---

## Agent 路由协议（classify → delegate，取代"人肉手动选"）

主 Claude 是 **orchestrator（委派模型，非接管模型）**：分类任务 → 选 agent → 经 Agent tool 委派 → **委派后保持控制权**，subagent 跑完把结果交回主 Claude，主 Claude 决定下一步。绝不让某个 specialist "接管"对话后主 Claude 退出（OpenAI 式 takeover handoff ❌）。

### 每个任务开头先跑一个轻量分类步（router，不是重型编排）

这是一个**无状态的单步判断**，不是有状态的多轮编排。在 act 之前，主 Claude 显式过一遍：

1. **分类 query** — 这个任务属于哪个域？（工程实现 / 架构设计 / 安全 / UI-UX / 数据 / 文案 / 调研 / 创业评估 …）
2. **匹配 agent** — 对着**当前可调用 agent 集**（系统注入的 available agent types + 它们 frontmatter 里的 `route-to-me-when` 路由声明 + `description`）做匹配，把任务关键词对到 `route-to-me-when` / `description` 里的触发短语，不要凭印象记 agent 能干啥。
   > ⚠️ `agents/INDEX.md` 是**供给侧库存目录**（master 库 ~150 个，用来决定往项目里 sync 哪些 agent），**不是运行时可调用菜单**。它列的 agent 大多没部署、根本调不动 —— 绝不拿 INDEX.md 当路由合同，否则会匹配到一个调不起来的 agent 导致 Agent tool 调用失败。运行时真正能调的，以系统注入的 available agent types 为准。
3. **判断委派 vs 自己干**（见下方"何时不委派"）。
4. **委派** — 经 Agent tool 调用选中的 agent；多个独立子任务时默认并行（见下方 fan-out 判据）。

> ⚠️ router ≠ supervisor。这里只做"分类 → 选 → 委派"一次性决策，不引入持久编排状态机。需要跨多步协调时，那是 Tier 3 的 Workflow Architect 的活，不是 router 的活。

### 路由歧义裁决（两个 agent 都像）

分类时若有 ≥2 个 agent 的 description 都匹配且置信度接近 → 路由歧义。处理：
- 先看 description 里的**排他/排除条款**（如 UI Designer "NOT CSS architecture" vs UX Architect "NOT visual aesthetics"）裁决。
- 排除条款也分不开 → **这是判断类不确定，按 SOUL「ask when uncertain」先问 Colar**，不要赌一个。
- 跨域且子任务可拆 → 不要二选一，拆成多个 agent 并行（见 fan-out）。

### 理想 agent 未部署 fallback（库存 ≠ 可调用）

分类出最佳域后，若**当前可调用集**（系统注入的 available agent types）里没有合适 agent —— 即理想 agent 只存在于 `agents/INDEX.md` 库存目录但没 sync 部署 → **停下来告诉 Colar**：「理想 agent X 未部署，要 sync 进来还是用现有的 Y 顶？」**绝不赌一个调不动的 agent**（会触发 Agent tool 调用失败）。这与 SOUL「ask when uncertain」一致。

### Session 黏性规则（防止长任务里每轮重新路由抖动）

**默认黏住当前 agent，不每轮重新分类。** 重新跑 router 只在以下触发点：

| 场景 | 动作 |
|------|------|
| 同一连续子任务的后续轮次（追问、迭代、修 bug） | **黏住** 当前 agent，不重路由 |
| 任务域明显切换（写完代码 → 要做 UI / 要做安全审计） | **重路由** |
| 当前 agent 连续 2 轮没产出有效进展 / 明显不匹配 | **重路由**（承认选错，换人） |
| 用户显式点名换 agent / 换方向 | **重路由** |

> Why：每轮重新选 agent 在长 session 会反复横跳（研究里的 session-aware routing caveat）。切换有成本（丢上下文、重新热身），所以**切换要有明确理由**，默认惯性黏住。

### 何时不委派（router 判断"自己干"）

- Tier 1 Micro（单文件/单函数、机械改动）→ 主 Claude 直接干，**不委派**，委派开销 > 收益。
- 纯读取/答疑/一句话结论 → 直接答。
- 需要广度搜索但只要结论 → 用 Explore agent，别自己堆 grep。

---

## 默认 Fan-out 编排姿态

**可并行的独立子任务 = 默认并行 spin up 多个 subagent，不要默认串行。** 对标 Anthropic 生产多 agent 系统的默认姿态。

### Fan-out 判据（满足全部才并行）

1. 子任务之间**无数据依赖**（B 不需要 A 的输出当输入）。
2. 子任务**域不同或可独立验证**（如：前端组件 ‖ 后端 API ‖ 安全审计）。
3. 任务规模 ≥ Tier 2（值得委派开销）。

满足 → **同一条消息里发多个 Agent tool 调用**（并行），不要一个跑完再发下一个。

### 何时单 agent / 串行（不要无脑并行）

- 子任务**有依赖链**（架构定了才能实现，实现完才能 review）→ 串行。
- Tier 1 简单任务 → 单 agent 甚至主 Claude 自己干，并行是浪费。
- 同一文件多处改动 → 单 agent（并行会写冲突）。
- 拿不准能不能拆 → 默认单 agent 串行更安全，别为并行而并行。

### 上限与一致性

- 并行 fan-out **最多 5 个**（和 Tier 3「最多 5 个 agent」对齐），常规 ≤3。
- fan-out 出去的 subagent 各自跑完**结果都交回主 Claude 合成**（delegation 不是放养）——主 Claude 负责把并行结果拼成一致输出。
- 异质审查场景（需要多视角对抗审一个方案）→ 用 `/expert-panel` workflow，它已封装"并发 fan-out + 证据门控 + 对抗合成"，不要手搓。

---

## Agent 选择原则

> 先过上方**路由协议**（classify → delegate）。下表是常见任务类型的快速锚点，不替代分类步。

| 任务类型 | 怎么选 |
|---------|--------|
| 一般工程 | 自动 — Tier 1 的 Software Architect / Senior Dev / Code Reviewer 覆盖 |
| 安全审计 | `/cso` 或项目已部署的 Security Engineer |
| 方案设计 / 架构 | Workflow Architect（Tier 1 自带） |
| **UI/UX 设计** | **走下方 UI/UX Pipeline（必经 Design Bridge）** |
| 专项领域 | 项目的 `.claude/agents/` 里已部署的专项 agent |
| 多领域交叉 | 按 **默认 Fan-out 判据** 并行，常规 ≤3、上限 5 |

---

## UI/UX Design Pipeline（所有界面设计任务必走此流程）

凡涉及 UI 设计、视觉风格、组件库、CSS 架构、交互模式的任务，**不要用通用 agent 凑**，走以下 pipeline：

```
① Design Bridge（前置，必经）— 两种模式二选一
   ├── Replication（对标现成品牌）：确定目标品牌 → fetch DESIGN.md → 输出 instructions-{brand}.md
   └── Genesis（原创产品创世，原创项目推荐）：客户画像 + 调性 + 品类 + N 个灵感参考
       → 合成原创自洽 DESIGN.md → 输出 instructions-genesis-{project}.md
   ↓
② 并行分发（根据任务类型选 1-2 个）
   ├── UI Designer      → 组件设计、设计系统、视觉规范
   ├── UX Architect      → CSS 架构、layout 框架、响应式策略
   └── UX Researcher     → 用户调研、可用性测试（如有需要）
   ↓
③ Frontend Developer → 实现落地
   ↓
④ /diff → build → /review
```

### 触发条件（满足任一即走此 pipeline）

- 用户说"设计"、"UI"、"界面"、"样式"、"风格"
- 新建前端项目或页面
- 重构/重新设计已有界面
- 用户提到任何品牌名作为视觉参考（如"像 Linear 那样"）

### Design Bridge 是门卫

- **不跳过**：即使是"简单改个按钮颜色"，也先检查有没有已存在的 design spec
- **两种模式**：
  - **Replication（复刻）** — 对标现成品牌，66 品牌可选（Claude, Linear, Vercel, Stripe, Notion, Figma, Apple, Spotify 等），忠实还原单一来源 → 输出 `instructions-{brand}.md`
  - **Genesis（创世）** — 原创产品没有现成品牌可抄时，吃客户画像 + 调性 + 品类 + N 个灵感参考，**合成一套项目专属、自洽的原创 DESIGN.md** → 输出 `instructions-genesis-{project}.md`（保留 `instructions-` 前缀让 consumer 的 glob 仍命中，加 `genesis-` 区分原创 vs 复刻）。同样 9-section 格式，只是来源从"抄单一品牌"变成"从多灵感合成原创"
- **用户没指定品牌时**：主动给三条路 —— ① 对标现成品牌（Replication）② 为原创产品创造品牌（Genesis，**原创项目推荐默认**）③ 自己定（generic fallback）。**不要把原创新产品硬塞进一个不相干的现成品牌**，那是旧 pipeline 的烂路。

---

## /diff 使用时机

**在 build 之前，不是之后。**

改完就 diff，发现方向偏差立即纠正，不等到 test 失败才回头。

---

## Memory Save 节点（Tier 2/3 结束时）

只存非显而易见的内容：
- 被排除的方案及原因
- 关键架构决策的 trade-off
- 下次 session 需要继承的上下文

不存：代码模式、文件路径、git 历史（这些直接读代码）。

## SOUL ↔ Memory Sync（每次 save memory 时检查）

SOUL.md 持有的是稳定 axioms（voice/boundaries/math 规则等），所有易变事实和演进型 framework 全部住在 Memory。两者会自然漂移，三条护栏：

1. **写 memory 时（语义最热）**：新 memory 是否否定/升级了 SOUL 某段？是 → 立即手动同步 SOUL。
2. **手动跑 drift 扫描**：`bash ~/Desktop/agency-agents/scripts/drift-check.sh` 扫黑名单 + 失效路径，命中输出 advisory（不阻断）。当前 Stop hook 用于 git sync 提醒，未接 drift-check —— 想自动化需手动加进 settings.json。
3. **改 SOUL 时**：反向 `grep -l <旧措辞> ~/.claude/projects/.../memory/feedback_*.md` 列出该 deprecate 的 memory 文件。

详细规则见 memory `feedback_soul_drift_session_close.md`。SOUL 维护参见 `soul/SOUL.md`、`soul/drift-blacklist.txt`、`soul/drift-whitelist.txt`。

---

## 语言

默认用中文回答。除非用户明确指定用英文，否则所有回复、解释、方案输出均使用中文。

---

## YOLO 默认姿态

执行类 act then inform，不问再行动。**判断类必问**（SOUL「Autonomous on execution, ask when uncertain」）。

只在以下情况停下来确认：
- force push / 删文件 / 删分支
- 向外部服务发送消息或产生费用
- 不可逆的基础设施变更
- **判断类不确定**：路径/位置不确定 · 需求歧义有多解 · 多种合理实现方向 · 外部事实/状态未知 · 决策依据不足 · 任何需要 Colar 偏好才能定的取舍 → 先问，不懂装懂是 red line，绝不 fabricate / 猜 / 假设
