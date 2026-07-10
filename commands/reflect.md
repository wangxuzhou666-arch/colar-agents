---
description: 周期性 memory 反思循环（Generative Agents reflection 的工程版）— 聚类蒸馏候选公理 + stale 归档提议 + skill attach 审计 + tool-error 行为审计。全部提议 gated，不自行改 SOUL/删文件
argument-hint: "[可选: --quick 只跑 2/3 步扫描不做蒸馏 / --days N 行为审计窗口，默认 30]"
---

# /reflect — Memory 反思循环（层级化蒸馏 v1）

把「单次经历 → 单条 feedback」的一层记忆升维：定期问一句 **「这 N 条 feedback 背后是不是同一条更深的公理？」**，同时做 stale 回收和行为审计。这是 save-memory（写入时单条 gate）的补集 —— save-memory 管入口质量，/reflect 管存量的蒸馏与衰减。

**Why 需要它**：2026-05 cleanup 发现 5 个 memory 文件与 SOUL 完全重复 —— 根因是只有防重复的写入 gate，没有主动升维的循环。腐烂和平铺膨胀都是「只写不蒸馏」的下游。

**纪律**：
- 所有产出都是**提议**，分四类走 save-memory 的 SOUL Impact Analysis；「升级」类必停等 Colar 拍板 (y/n)，绝不自行改 SOUL、删 memory 文件。
- 过程文件不 open、不在 chat 粘贴原文 —— 只列路径 + 一句话。
- 建议频率：双周手动，或接 cron routine（接法见文末）。

## 触发 / 不触发

- ✅ `/reflect`；Colar 说「蒸馏一下 memory / 反思循环 / memory 大扫除」
- ✅ MEMORY.md 索引明显变长、或 drift check 连续多次报 stale/overlap
- ❌ 单条 memory 的写入（那是 /save-memory）
- ❌ session 交接（那是 /handoff）

## Procedure

### Step 0 — 加载全景（只读）

1. Read `~/Desktop/colar-memory/MEMORY.md`（canonical 索引）；`ls` 实际文件核对计数（以 ls 为准，不信硬编码）。
2. Read `~/.claude/CLAUDE.md`（SOUL）—— 后面蒸馏出的候选公理要对着它做 4-类判断。

### Step 1 — 聚类蒸馏（reflection 升维，核心步）

1. 扫 `feedback_*.md` 的 description（索引行即可，必要时开文件），找**同主题簇**：≥3 条 feedback 指向同一深层模式（例：多条都在讲「N=1 就立 SOP」「sunk cost 包装」→ 深层公理可能是「样本量纪律」）。
2. 每个簇输出一条**候选公理**：`簇成员文件列表 → 候选公理一句话 → 与 SOUL 的 4-类关系（重复/升级/细化/正交）`。
3. 「升级/正交且够格进 SOUL」的 → 按 save-memory 流程提议 SOUL diff，**停等拍板**。拍板通过后：新公理落 SOUL 或新 memory 文件，簇成员文件加 pointer 指向它（不删原文件，保留案例价值）。
4. 找不到簇 → 如实说「本轮无可蒸馏簇」，不硬凑。

### Step 2 — Stale 回收提议

1. 跑 `bash ~/Desktop/agency-agents/scripts/memory_drift_check.sh`，收集 stale candidates / overlap / dead links。
2. 补一层人工判断：time-bound memory（带日期的决策/状态）是否已被后续事实推翻或完结（对照 git log / 近期 session 认知）。
3. 输出**归档/删除提议清单**（文件 + 一句话理由），停等拍板后才动。

### Step 3 — Skill attach 审计

1. 跑 `python3 ~/Desktop/agency-agents/scripts/recall/pilot_audit.py`（Hermes pilot skill 的 attach 率）。
2. 对每个 pilot skill 给去留建议：attach 率为 0 且观察窗已过 → 提议软 kill（对齐 p3-tool-one-battle SOP）；有 attach → 转正。停等拍板。

### Step 4 — 行为审计（tool-error）

1. 跑 `python3 ~/Desktop/agency-agents/scripts/tool_error_audit.py --days {N, 默认 30}`。
2. 对照 SOUL「Tool-Call Discipline」节：新出现的高频错误模式（未被现有纪律/hook 覆盖）→ 提议新纪律一条（走 4-类判断，升级类停等）。已覆盖但仍高频 → 说明纪律失效，提议升级成 hook 硬拦。

### Step 5 — 一页汇报

按固定顺序输出（没有的段写「无」）：
1. 候选公理（Step 1，含 4-类标注 + 待拍板项）
2. 归档提议清单（Step 2，待拍板）
3. Skill 去留（Step 3，待拍板）
4. 新纪律提议（Step 4，待拍板）
5. 本轮改动的文件路径列表（只列路径）

拍板通过的改动由 `/ship` 提交（colar-memory / agency-agents 两仓分开），本命令自身不 commit。

## 接 cron（可选，Colar 说了才接）

用 /schedule 建双周 routine，prompt 就一句 `/reflect --quick`；quick 模式只跑 Step 2/3/4（纯脚本扫描 + 汇报），Step 1 蒸馏留给交互 session 做 —— 升维判断需要 Colar 在场拍板，无人值守跑了也只能攒提议。
