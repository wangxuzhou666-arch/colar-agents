---
description: 把本 session 提炼出的可复用 procedure 蒸馏成 version-controlled SKILL.md（层 3 procedural memory）— 带写时 4-类查重 gate（重复跳过 / 升级改旧 / 细化加 pointer / 正交新建）+ 更新 SKILLS 索引 + 提议 SOUL pointer（gated）
argument-hint: "[一句话描述要 capture 的 procedure，可选 / --dry 只跑查重不写]"
---

# /capture-skill — Procedural Memory Capture（层 3 v1）

把"这次踩通的一套可复用打法"从易失的 session 上下文，蒸馏成 attach-on-demand 的 SKILL.md。

**核心纪律（Colar 拍板）：主动遗忘 > 无脑累积。** 不是每个 session 都该 capture —— 先过「值不值得固化」gate（Step 0），再过「写时查重」gate（Step 2），最后才落盘。研究里 self-evolving agent 的通病就是只存成功、无脑累积导致噪声/爆上下文 —— 这两道 gate 就是防它。

**纪律**：act then inform。机械步骤不问；judgment 步骤（升级已有 skill / wire SOUL）必停等拍板。报告如实——跳过了说跳过 + 原因。

## 触发 / 不触发

- ✅ `/capture-skill`；本 session 跑通了一套**可重复、跨 session 有复用价值**的 procedure（触发条件明确 + 步骤可固化 + 下次还会遇到）
- ✅ 把一条已有 feedback memory「升格」成 procedural skill（带 `source` 指回该 feedback）
- ❌ 一次性 / 高度 context-specific 的操作（下次不会重演）
- ❌ 纯事实 / 偏好 / 决策（那是 semantic memory → 走 `/ship` 的 save memory，不是 skill）
- ❌ git log / 代码就能重建的机械步骤

> 判据口诀：**skill = "当 X 触发条件出现 → 照这套 Procedure 走"**。说不出稳定触发条件的，不是 skill。

## 参数

| 参数 | 作用 |
|---|---|
| `<描述>` | 一句话锚定要 capture 啥，喂给蒸馏 + 查重 |
| `--dry` | 只跑 Step 0–2（值得 gate + 蒸馏草稿 + 查重判定），报告计划后停，**不写任何文件** |

每步开头打 `[Step N] <name>` 进度行；跳过打 `⏭ skipped (原因)`。

---

## Step 0 — 值不值得固化 gate（先于一切）

从本 session 自检 3 条，**全 yes 才继续**；任一 no → `⏭ 不 capture (原因)` 退出：

1. **可复用**：能说出稳定的"当 X 时触发"条件？（说不出 → 一次性操作，不是 skill）
2. **非显而易见**：不是读代码 / git log 就能重建的？
3. **跨 session 价值**：下个 session / 未来的我真的会再用到？

> 这是「主动遗忘」纪律的第一道闸——宁可不 capture，不要攒垃圾 skill。

## Step 1 — 从 session 蒸馏 SKILL.md 草稿（先成稿，不写盘）

从当前对话上下文提炼，填模板（对齐 `integrations/hermes/skills/*/SKILL.md` 现有 3 个）：

- `name`：kebab-case slug（如 `nextjs-hmr-proactive-restart`），= 目录名
- `description`：**= When-to-Use 的触发语**，双语：中文为主 + 末尾一句 `Use when: ...` 英文触发条件（对齐现有 skill）。这是 attach 时唯一被读到的字段，必须把"何时该 attach 我"讲清
- `version`：新建 = `1.0.0`
- `source`：本 session 蒸馏 → `session-derived (YYYY-MM-DD)`；来源是已有 feedback → `feedback_<name> (migrated YYYY-MM-DD)`。**日期取自 `[time-context::hook-only]` 注入行**；hook 输出 UNAVAILABLE → 不戳日期
- 正文段：`## When to Use`（触发 / 不触发清单）+ `## Procedure`（step-by-step，可 exec，带 ```bash``` 如适用）+ 按需 `## Verification` / `## Pitfalls` / `## Why This Skill Exists`（写明从哪个 session/feedback 蒸馏 + 实战场景与日期，用叙事补 session 无持久 id 的缺口）/ `## Related`

> 蒸馏原则：Procedure 要"下个 session 照着能直接 exec"，不是抽象总结。

## Step 2 — 🚧 写时查重 gate（核心：filter + normalize + dedup）

**写盘前必扫现有 procedural skills**，套 SOUL 的 4-类关系判断。这是研究要的「写入时 filter+normalize+dedup」（不是事后 drift-check）。

### 2a 扫描（只读）

读 `~/Desktop/agency-agents/integrations/hermes/skills/SKILLS.md` 索引 → 拿每个现存 skill 的 slug + 一句话 hook。
对**语义相近的候选**（name/description 关键词重叠），再 Read 其 `SKILL.md` 的 frontmatter `description` 做精判。
> 分层读取：先用索引行粗筛，命中候选才展开读 description，不盲读全部 SKILL.md 正文。

### 2b 4-类判定（复用 SOUL § SOUL↔Memory Sync 事前表）

| 关系 | 判断 | 处理 | 告知 Colar 话术 |
|---|---|---|---|
| **重复** | 已有 skill 同触发 + 同 procedure | **不写新文件**，跳过 | "skill `<x>` 已 cover '{触发}'，跳过 capture" |
| **升级** | 本次 procedure 否定 / 替代已有 skill | **改已有 SKILL.md（version bump）+ 提议 diff** | "升级 `<x>` vN→vN+1：旧=… 新=…。改吗?(y/n)" → ⛔ **停等 Colar 拍板** |
| **细化** | 本次是已有 skill 的子情形 / 实现细节 | **不新建独立 skill**，往已有 SKILL.md 加子节 / pointer | "细化 `<x>`，已加 pointer，不另开 skill" |
| **正交** | 与所有现存 skill 无交集 | **新建** SKILL.md | "SKILL impact: 无 · 新建 `<slug>`" |

- **只有「升级」类必须停下等确认**（改已有产物 = judgment）；其余 3 类一行告知后继续 YOLO。
- **「升级」vs「细化」两类都像、分不开 → 按 SOUL「ask when uncertain」停下问 Colar**，不自赌。
- `--dry` 在此 gate 之后停，报告落在哪一类 + 计划动作。

## Step 3 — 写盘（按 2b 判定动作）

- 路径：`~/Desktop/agency-agents/integrations/hermes/skills/<slug>/SKILL.md`（version-controlled，与现有 3 个一致）
- **新建前 guard**：`test -d <slug>` —— 目录已存在但 2b 判成了「正交」= dedup 漏判，停下回 Step 2 重判，**绝不覆盖**
- **正交（新建）**：建目录 + 写 SKILL.md
- **升级**（Colar 已 y）：Edit 已有 SKILL.md + `version` bump（`1.1.0` 细节增强 / `2.0.0` procedure 替换）
- **细化**：Edit 已有 SKILL.md 加子节 / pointer
- **重复**：不写盘，直接到 Step 6

## Step 4 — 更新 SKILLS 索引

往 `integrations/hermes/skills/SKILLS.md` 加 / 改一行 pointer（格式 `- [<slug>](./<slug>/SKILL.md) — <hook>。Source: …`）：
- 新建 → 加一行
- 升级 / 细化 → hook 措辞变了才更新该行，否则不动
- 重复 → 不动

## Step 5 — SOUL pointer 建议（gated，绝不自动写 SOUL）

判断本 skill 是否**全局相关**（跨项目通用、属 axiom 级触发，如 `max-mode-protocol` 已进 SOUL）：

- **是** → 产出**一条建议 pointer 行**让 Colar 决定，话术：
  > 此 skill 全局相关，建议往 SOUL（`agency-agents/soul/SOUL.md` § Strategic Frameworks）加 pointer：
  > `- <一句话触发>：see integrations/hermes/skills/<slug>/SKILL.md`
  > 要 wire 进 SOUL 吗?(y/n)
  → ⛔ **停等拍板，不自动改 `soul/SOUL.md`**（它 symlink 到 `~/.claude/CLAUDE.md`，是 axioms 层）
- **否**（项目局部 / attach-on-demand 足够）→ "SOUL impact: 无，靠 SKILLS 索引按需 attach 即可"

> ⚠️ Step 5 是 v1 唯一的 retrieval 接线点（retrieval 半边沿用 pointer 模式，本版不做自动发现）。**别弱化它**——全局 skill 不 wire 进任何 pointer = capture 了但永远不被 attach，成孤儿。

## Step 6 — 收尾摘要

```
✅ Captured: <slug> (<新建 / 升级 vN / 细化 / 重复跳过>)
  SKILL.md:    integrations/hermes/skills/<slug>/SKILL.md
  SKILLS 索引:  +1 行 (或 不变)
  SOUL pointer: ⏸ 等你确认 (或 无需)
  → 记得 /ship 把 agency-agents 这次改动 commit/push（skill 是 version-controlled）
```

> capture 只管"蒸馏 + 落盘 + 去重"，**不自己 commit/push**——那是 `/ship` 的 project lane 的事（skill 住 agency-agents project repo）。

## 硬规则

- ❌ 「升级」类改已有 SKILL.md → 停等 Colar 拍板，绝不自动覆盖
- ❌ 绝不自动改 SOUL（`agency-agents/soul/SOUL.md`）——只提议 pointer，Colar 拍板
- ❌ Step 0 值得 gate 不过 → 不 capture，宁缺毋滥（主动遗忘纪律）
- ❌ `source` 日期只采信 `[time-context::hook-only]`；hook UNAVAILABLE → 不戳日期
- ❌ 不在 chat 粘 SKILL.md 全文——只列路径 + 一句话（SOUL 过程产物纪律）
- ✅ 查重 gate（Step 2）永不跳过，即使 `--dry` 也跑
- ✅ skill = procedure（触发→步骤）；事实 / 偏好 / 决策 → 退回 semantic memory（`/ship` save memory）
- ✅ name/description 双语对齐现有 3 个 skill（中文 + 末句 `Use when:` 英文）

## 反 pattern（落盘前自检）

| 反 pattern | 为什么坏 |
|---|---|
| 把一次性操作 capture 成 skill | 攒垃圾，违反主动遗忘纪律 |
| 跳过查重直接新建 | 与已有 skill 重复 / 语义重叠，索引腐烂 |
| description 写成"这个 skill 干啥"而非"何时 attach 我" | attach 判断失效，永远不被触发 |
| 自动改 SOUL / 自动 commit | 越权，judgment 步骤未 gated |
| Procedure 写成抽象总结无可 exec 步骤 | 下个 session 照不了，等于没 capture |
| 把事实 / 偏好塞进 skill | 该进 semantic memory，类型错位 |
| `source` 字段空 / 戳相对日期 | 蒸馏来源丢失，无法回溯 |

## 不该做的

- ❌ 不替 Colar 决定升级已有 skill / wire SOUL——只提 diff，他拍板
- ❌ 不 commit/push——那是 `/ship` 的事
- ❌ 不 capture 一次性 / 显而易见操作——主动遗忘
- ❌ 不把 skill 内容写进 semantic memory（反之亦然）——procedural vs semantic 分离

---

**用户参数**：$ARGUMENTS