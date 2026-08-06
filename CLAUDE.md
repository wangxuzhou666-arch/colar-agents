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
   ↳ 若本次改了**已覆盖 agent 的 prompt body** → 必跑 Agent Prompt-Edit Gate（before/after eval 对比，见下方同名专节 → skill `agent-prompt-edit-gate`）
⑧ save memory（非显而易见的决策） + SOUL drift check
   ↳ 若本 session 产出可复用 procedure（稳定触发 + 可固化步骤）→ 跑 /capture-skill（层 3，带写时查重，见下方「收尾节点」）
   ↳ 若新 memory 否定/升级了 SOUL.md 某条声明 → **升级类必须先提议 SOUL diff（旧 = … / 新 = …）等 Colar 拍板 (y/n)，不得自行改 SOUL**（权威版本：SOUL §「SOUL ↔ Memory Sync Discipline」#1）
   ↳ drift 扫描：`memory_drift_check.sh` 已接 Stop hook 自动跑（advisory，clean 时静默）；SOUL 措辞黑名单扫描仍手动 `bash ~/Desktop/colar-agents/scripts/drift-check.sh`
⑨ commit
```

---

### Tier 3 — Architecture（2h+，跨 session 重构/新系统）

```
① 加载 memory + 上下文（读 MEMORY.md + README + git log）
② classify → delegate（过路由协议选相关专项 agent，主 Claude 自任编排者，并行 fan-out 上限 5 个）
③ EnterPlanMode → 完整方案（含数据流/接口/风险/被排除方案）
④ 确认方案后 ExitPlanMode，开始执行
⑤ 每个子模块完成 → /diff → 小步 commit
⑥ build / test（每个 milestone 验证一次，不是最后才跑）
   ↳ 若重构涉及**已覆盖 agent 的 prompt body** → 必跑 Agent Prompt-Edit Gate（before/after eval 对比，见下方同名专节 → skill `agent-prompt-edit-gate`）
⑦ /review
⑧ save memory（关键架构决策的 trade-off + 被排除方案的原因） + SOUL drift check
   ↳ 若本 session 产出可复用 procedure → 跑 /capture-skill（层 3 procedural capture，带写时查重，见下方「收尾节点」）
   ↳ 架构性变更尤其容易让 SOUL 过期 — 发现受影响段落时**提议 SOUL diff 等 Colar 拍板 (y/n)，不得自行改**（权威版本：SOUL §「SOUL ↔ Memory Sync Discipline」#1）
   ↳ `memory_drift_check.sh` 已接 Stop hook 自动跑；SOUL 黑名单扫描手动 `bash ~/Desktop/colar-agents/scripts/drift-check.sh`；改 SOUL 后反向 grep memory 列 deprecate 候选
⑨ PR
```

---

## Agent Prompt-Edit Gate（改 agent prompt 必跑 eval）

**凡改动 agent prompt body（master `.md` frontmatter 之后正文），强制 before/after 跑 eval 对比 pass rate——别盲改。** 改 frontmatter（routing metadata）不触发。

完整流程（触发表 / `run-eval.sh --agent` 命令 / 四条铁律 / 变异来源辨析）见 skill **`agent-prompt-edit-gate`**（attach-on-demand，此处不复述全文）。

> 2026-08-05：该 skill 此前只以 `integrations/hermes/` build 产物形式存在，从不在可调用列表里、加载失败还不报错（静默降级）。现已 symlink 进 `~/.claude/skills/`，按名字即可调起。

---

## Agent 自动发现（三层架构）

Agents 已按项目分层部署，Claude Code 自动发现，不需要手动指定：

```
Tier 1: ~/.claude/agents/         ← 全局 agent，所有项目可用（symlink → master，手动 ln -s 管理）
Tier 2: <project>/.claude/agents/ ← 按项目精选的专项 agent（sync 脚本从 master 复制）
Master: ~/Desktop/colar-agents/  ← 单一真相源（全局走 symlink、项目走 sync 复制）
```

> 数量随项目演化变化，不在此处固定声明。当前快照：`ls ~/.claude/agents/ | wc -l`。

**全局 agent（Tier 1）机制**：`~/.claude/agents/*.md` 是指向 master 的 **symlink**，手动创建：`ln -s ~/Desktop/colar-agents/<domain>/<file>.md ~/.claude/agents/<file>.md`。**只编辑 master 文件**——symlink 让改动即时对 Claude Code 生效；绝不在 `~/.claude/agents/` 放非 symlink 文件（破坏单一真相源）。

**项目 agent（Tier 2）机制**：项目的 `.claude/agent-config.yaml` 声明需要哪些 agent，运行 `bash scripts/sync-all.sh` 从 master library 复制到项目的 `.claude/agents/`；新增单项目：编辑该项目 `agent-config.yaml` 后跑 `bash ~/Desktop/colar-agents/scripts/sync-agents.sh <project-path>`。**不要手动往项目 `.claude/agents/` 放文件**——项目层用 sync 脚本管理。

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

> ⚠️ router ≠ supervisor。这里只做"分类 → 选 → 委派"一次性决策，不引入持久编排状态机。需要跨多步协调时，那是 Tier 3 编排（主 Claude 自任编排者，或 `/expert-panel` 类 workflow）的活，不是 router 的活。

### 路由歧义裁决（两个 agent 都像）

分类时若有 ≥2 个 agent 的 description 都匹配且置信度接近 → 路由歧义。处理：
- 先看 description 里的**排他/排除条款**（如 Senior Developer "NOT LLM-pipeline 层" vs Applied AI Engineer "NOT 通用 full-stack CRUD"）裁决。
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
| 一般工程 | 自动 — Tier 1 的 Senior Developer / Code Reviewer 覆盖 |
| 架构 / 方案设计 | 内置 `Plan` agent 或 EnterPlanMode（2026-08-04 起 Software Architect 已退役，与内置 Plan 重合）；需多视角对抗走 `/expert-panel` |
| 安全审计 | 内置 `/security-review` skill（2026-08-04 起 Security Engineer agent 已退役）；威胁建模等重判断走 `/expert-panel` 挂安全席位 |
| **UI/UX 设计** | **走下方 UI/UX Pipeline（必经 Design Bridge；视觉/UI 执行走 skill 方案，主 loop 直接处理）** |
| 专项领域 | 项目的 `.claude/agents/` 里已部署的专项 agent |
| 多领域交叉 | 按 **默认 Fan-out 判据** 并行，常规 ≤3、上限 5 |

---

## UI/UX Design Pipeline（所有界面设计任务必走此流程）

**触发**：用户说"设计 / UI / 界面 / 样式 / 风格" · 新建前端项目或页面 · 重构已有界面 · 提到任何品牌名作为视觉参考。命中即走 pipeline，**不要用通用 agent 凑**。

**四段**：Design Bridge（门卫，必经，Replication 复刻 / Genesis 创世 二选一）→ frontend-design plugin 执行 → Frontend Developer 落地 → `/diff` → build → `/review`。

完整流程（两种模式判据 / 66 品牌 / Genesis 产出格式 / 「没指定品牌时给三条路，别把原创产品硬塞现成品牌」）见 skill **`ui-design-pipeline`**（attach-on-demand，此处不复述全文）。

---

## /diff 使用时机

**在 build 之前，不是之后。**

改完就 diff，发现方向偏差立即纠正，不等到 test 失败才回头。

---

## 收尾节点（Tier 2/3 结束时）— semantic 与 procedural 分开走

- **save memory**（semantic：事实 / 决策）— 只存非显而易见的：被排除的方案及原因 · 关键架构决策的 trade-off · 下次 session 需继承的上下文。**不存**代码模式 / 文件路径 / git 历史（直接读代码）。流程走 `/save-memory`。
- **`/capture-skill`**（procedural：可复用打法）— 判据是"当 X 触发 → 照 Procedure 走"，说不出稳定触发条件的不是 skill。**主动遗忘 > 无脑累积**，宁可不 capture 也别攒垃圾。写时 4-类查重由命令自身负责。索引：`integrations/hermes/skills/SKILLS.md`（权威）。落盘后由 `/ship` 提交，命令自身不 commit。
  > ⚠️ **新 skill 必须接线才可调用**：写进 `integrations/hermes/skills/<name>/` 只是落盘，Claude Code **不从那里发现 skill**（Hermes runtime 已放弃，`~/.hermes` 从未生成）。必须 `ln -s ~/Desktop/colar-agents/integrations/hermes/skills/<name> ~/.claude/skills/<name>` 才会出现在可调用列表。2026-08-05 前有 6 个 skill 因缺这一步长期不可调用且**加载失败不报错**（静默降级），已全部补接。
- **SOUL ↔ Memory Sync** — 新 memory 若否定/升级 SOUL 某段，**升级类必须先提议 SOUL diff 等 Colar 拍板 (y/n)，不得自行改 SOUL**。4-类关系判断表的**权威全文在 `/save-memory`**（`commands/save-memory.md` § Step 1）——2026-08-05 拍板：此前 SOUL / save-memory / 本文件三方互相声称权威，现统一归 save-memory，SOUL 与此处只持 pointer。drift 扫描：`memory_drift_check.sh` 已接 Stop hook 自动跑；`scripts/drift-check.sh`（SOUL 黑名单措辞 + 失效路径）仍手动。改 SOUL 后反向 `grep -l <旧措辞>` memory 列 deprecate 候选。
- 延伸：memory `feedback_soul_drift_session_close.md` · `soul/SOUL.md` · `soul/drift-blacklist.txt` · `soul/drift-whitelist.txt`

---

## YOLO 默认姿态

执行类 act then inform，不问再行动。**判断类必问**（SOUL「Autonomous on execution, ask when uncertain」）。

只在以下情况停下来确认：
- force push / 删文件 / 删分支
- 向外部服务发送消息或产生费用
- 不可逆的基础设施变更
- **判断类不确定**：路径/位置不确定 · 需求歧义有多解 · 多种合理实现方向 · 外部事实/状态未知 · 决策依据不足 · 任何需要 Colar 偏好才能定的取舍 → 先问，不懂装懂是 red line，绝不 fabricate / 猜 / 假设
