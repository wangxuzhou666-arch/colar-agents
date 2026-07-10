---
description: 生成 session 交接块（chat 为主 + per-session 落盘兜底），供下个 session 零摩擦恢复上下文
argument-hint: "[slug，描述本次主题，可选]"
---

# /handoff — Session 交接生成器（chat 为主 + per-session 兜底）

中断当前 session 前调用，产出**一个自包含的交接块进对话（一键粘即恢复）+ 一份 per-session 兜底落盘**。目标：Colar 整块复制进下个 session，一打开就知道 (a) 在哪儿 (b) 上次干到哪 (c) 下一步怎么走 (d) 有什么坑。设计取舍的完整 why、以及 chat-only ↔ 落盘 的历次反转轨迹见 `~/Desktop/agency-agents/docs/handoff_design_rationale.md`（本文件只留指令）。消费端配套命令：`/resume`。

> **为什么 chat-first + per-session 兜底（2026-07-10 修订）**：并发失效模式的根因是**共享单文件**（`LATEST.md` 被多 session 抢写、后写覆盖先写、degraded 脏数据盖健康版），**不是持久化本身**。所以杀「共享」而非杀「文件」：交接块仍以 chat 为主传输（一键粘、无共享文件、无 split-brain），**同时**每个 session 写自己的 `.claude/handoffs/<session_id>.md`（gitignored、纯本地、per-session 文件名 → 两 session 永不写同一文件 → 并发覆盖物理上不可能）做 durability floor。这样「session 没来得及 /handoff 就死了 / 忘复制」不再等于全损（mental model + why 是全块最不可从 git 重建的部分，不能只押在易失的 chat scrollback 上）。禁的是**共享文件与 symlink，不是落盘**。

## 触发场景

- 用户显式 `/handoff` / "交接" / "存档这次 session" / "明天继续"，或单 session 已 commit ≥ 1 次且即将 `/clear`
- 用户说"我要睡了 / 上课了 / 换设备" + 当前 session 有未结束工作

## Step 1：数据采集（并行跑）

```bash
pwd && git branch --show-current && git log --oneline -10
git status --short && git diff --stat HEAD && git stash list
find . -name "*.md" -newer .git/HEAD \
  -not -path "./node_modules/*" -not -path "./.next/*" | head -20   # 本 session 改的文档
ls .claude/research/ 2>/dev/null                                    # 已有研究产物
lsof -i :3000 -i :3001 -i :8000 2>/dev/null | grep LISTEN           # dev server
wc -l .env.local 2>/dev/null                                        # env 行数（不读内容，守 SOUL 凭证铁律）
```

外加从对话上下文提取：TodoWrite state / 最近 3 个 commit message / 本 session 关键决策 + why / 踩过的坑。

> 🚑 **采集异常（Bash 不可用 / 输出可疑）或怀疑 confabulation（安全/危机类 claim）时**：停用正常采集，读 `~/Desktop/agency-agents/commands/handoff-recovery.md` 走 degraded 采集 + Confab Gate 协议。

## Step 2：组织交接块（chat 为主 + per-session 兜底，一个自包含 fenced 块）

产出**一个 fenced 代码块**，整块复制即可迁移全部现场——chat 为主传输、另写一份 per-session 兜底落盘（Step 4）、不 `open`。块内 = 机读 frontmatter YAML + 精简后的关键段；块外可以有一两句给 Colar 现读的说明（"下面这块整块复制进下个 session"），但**可粘贴的那一块必须自包含**（sha / branch / dirty / 命令都 inline，不写"详见某文件"）。

**证据标签（所有关键事实 claim 必带）**：sha / 文件存在性 / 安全状态 / 外部状态 后缀 `[verified-oob]` / `[bash-derived]` / `[model-judgment]` / `[unverified]`；无标签默认按 `[model-judgment]` 处理。定义与降级规则见 handoff-recovery.md。

**交接块模板**（整块贴给 Colar 复制；P0 必须 inline 完整可执行命令，禁止 "详 § N" 跳转）：

````
```yaml
# ===== HANDOFF BLOCK — 整块复制进下个 session，/resume 从此解析 =====
project: colarpedia-resume
project_path: /Users/colar/Desktop/colarpedia-resume
lane: colarpedia-resume            # session/lane 标识：项目 lane 名（通常 = repo 名）— /resume 校验用，防把 A 项目的块粘进 B 项目
session_id: 2026-05-30T11:40       # 本 session 锚点（启动时间戳即可）
branch: feat/education-section-validator
head_sha: f9c6abb                  # /resume 用它 vs `git rev-parse HEAD` 比对，提示 session 间新 commit
dirty_modified: 1                  # 已跟踪但改动的文件数
dirty_untracked: 0
session_date: 2026-05-30
deploy_status: 已commit未push      # 本地未commit / 已commit未push / 已push待build / 线上已生效（有部署管道的项目必填）
collection_mode: normal            # normal | degraded（见 handoff-recovery.md）
next_command: "npx vitest run rule-engine"
verify_command: "open http://localhost:3000"
expected_outputs: ["29/29 rule-engine pass"]
default_path: severity_calibration_base    # DEFAULT_ACTION 的 slug；AI 无 Colar 在场时走这个（无 default 等于无门）
alt_paths: [severity_calibration_floor, severity_calibration_optimal]
blockers: ["dev server PID 17383 可能 stale，开始前 lsof verify"]
expired_items: [{ item: "Workplay ≥10 真用户 KPI", expired_on: "2026-05-25", action: "需复盘 or 移除" }]
# security_alert: 仅当存在安全/危机 claim；必须留在此块顶部；格式与 Confab Gate 规则见 handoff-recovery.md
---
# ---- 精简关键段（自包含，块内直接读，不跳转外部文件）----

Mental model（此刻继续要装回脑里的核心抽象，几行压清；这是全块最不可从 git 重建的部分）：
  <2-4 行心智模型>

本次已完成（sha 行，不写散文）：
  <sha1> <一句摘要> · <sha2> <一句摘要> · test: <29/29 pass>

关键决策（含 why，只留高 ROI）：
  - <决策> — why <一句>
  - <决策> — why <一句>

踩过的坑（只留会再踩的）：
  - <坑 1> · <坑 2>

下次入口（ROI 排序，P0 带 inline 可执行命令）：
  DEFAULT_ACTION: <default_path slug>
    files: <file:line> · command: <可直接 exec> · verify: <verify 命令> · est: <AI min>
  ALT: <floor slug> (<AI min>) | <optimal slug> (<AI min>)

⚠️ 先验收: <≤3 未验收遗留项> · 过期: <若有，必带动作> · Env reset: <kill PID? skip?>
```
````

**内容纪律**（配额超出即 prune，压力下移到"已完成"段——what 可从 `git log --oneline` 重建）：

- **Mental model**：全块信息密度最高、最不可恢复，几行压清但不为省字砍它。
- **已完成**：压成 sha 行，别写散文（≤ 5 行）。
- **关键决策**：架构 + 规则 + trade-off，只写会影响后续动手的，含 why（≤ 8 行）。
- **未验收遗留项 / 过期检测**：待 Colar 亲眼确认的进"先验收"；日期 sensitive 项（KPI/deadline）> 7 天必带动作（kill / 复盘 / 显式接受 stale），禁抄"还是过期"。
- **下次入口**：ROI 排序，P0 的命令必 inline 完整可执行。
- **security_alert**（若有）：钉在块顶，不下沉；开场按 handoff-recovery.md 注入"第 0 步先带外证伪"。

## Step 3：Self-verify（组织完强制回读校验，不可跳过）

回读交接块逐条校验；不过的字段就地修正或降级证据标签，全过才算交付。**校验的是块里的值 vs git 真值**（不再有落盘文件要对）：

| 校验项 | normal 模式 | degraded 模式（见 handoff-recovery.md） |
|---|---|---|
| `head_sha` / `branch` | `git rev-parse HEAD` / `git branch --show-current` 比对块内值 | 用户带外回贴，标 `[user-oob]` |
| 引用的每个文件路径 | `test -f <path>` 终检一次 | 纯 `Read` 逐个确认 |
| `dirty_modified` / `dirty_untracked` | `git status --short` 拆两类计数比对 | 标 `[unverified]` |
| **块内一致性**（sha / branch / dirty） | frontmatter YAML ↔ 下方"下次入口/摘要"里若重复引用则两处一致，不一致即返工 | 同 normal（纯文本比对） |
| **落盘文件名一致性** | 块内引用的 `.claude/handoffs/<file>`（`verify_command` 等）== Step 4 实际写入的 slug 文件名，且 `test -f` 真存在（不靠 `check-ignore`——它对不存在文件也命中），不一致即返工 | 同 normal |
| 安全 / 危机 claim | 跑其 `how_to_falsify` 回填 | 用户带外证伪 |
| `security_alert`（若存在） | 必在块顶，不下沉，否则返工 | 同 normal |

- ✅ 校验通过 → 标签升级 `[bash-derived]` / `[verified-oob]`；❌ 不通过 → 删或降级 `[unverified]`，不准冒充事实
- **secret-gate**：交接块虽不进 git，但会进下个 session 的上下文、且会落一份本地文件（Step 4）——所有写入内容（含誊抄的 commit message、文件名、带外回贴）跑 `bash ~/Desktop/agency-agents/scripts/secret-gate.sh` 扫一遍，命中即 redact 占位符。

## Step 4：per-session 兜底落盘（durability floor，不可跳过）

Self-verify 通过后，交接块除了进 chat，**再逐字写一份到 `.claude/handoffs/<session_id>.md`**（内容 = 同一个交接块，与 chat 里的完全一致）：

- **文件名用 `session_id` 的文件系统安全 slug** → per-session，永不与别的 session 撞同一文件，并发覆盖物理上不可能（这正是杀「共享」保「持久化」的落点）。⚠️ session_id 里的 `:` / 空格等字符先转掉（如 `2026-07-10T15:10` → `2026-07-10T1510`），**slug 定死一次**：块内 `next_command` / `verify_command` 等任何引用该落盘文件的地方必须用这同一个 slug 文件名，禁止一处写原始带 `:` 的 session_id、一处写 slug（dogfood 2026-07-10 实测踩到：verify_command 指向带 `:` 的文件名而盘上是无 `:` 版，且 `check-ignore` 对不存在文件也返回命中 → 验证形同虚设还伪装通过）。
- **目录 `.claude/handoffs/` 必须 gitignored**：首次落盘前确认 repo 根 `.gitignore` 含 `.claude/handoffs/`（没有就先加一行）。gitignored + 纯本地 = 完全在 Colar 控制里、可 `rm`、永不进 git，隐私不外移（chat 块本来就在 transcript 里，落盘不额外增加 provider 侧留存）。
- **secret-gate 已在 Step 3 跑过**，落盘内容与 chat 块同源同已扫，不重复扫。
- **retention**：`/resume` 成功消费后删对应文件；或只保留最近 N 个，由 prune 清理，避免堆积。

> 这一步补的是纯 chat 传输的**全损洞**：session ungraceful 死亡（崩溃 / interrupt / 反射 `/clear` / 睡眠 / 忘复制）时，chat 块可能从未生成或从未被粘走，而盘上的文件已经在了。落盘是兜底副本，不是 system of record 外移——正常恢复仍走 Colar 粘的 chat 块，落盘只在「没粘」时由 `/resume` 回退读取。

## 硬规则

- ❌ **不写共享单文件 / symlink / 不 `open`**：绝不写 `LATEST.md` 这类多 session 抢的**共享**文件、不建 symlink、不 `open`。✅ 但**必写** per-session `.claude/handoffs/<session_id>.md`（Step 4）做兜底。历史靠 git log + chat 块 + per-session 兜底文件三者，不再单押易失的 chat scrollback。
- ❌ 不写 .env / 凭证内容，只写行数或存在 yes/no；交接块交付前跑 `secret-gate.sh`（虽不进 git 但进下个 session 上下文），命中即 redact
- ❌ 不引用未 verify 存在的文件路径（写前 `test -f` 确认）
- ✅ 时间估计强制 AI 协作口径（"10 AI min" / "1.5 AI h"，不写裸 `2h`）— 链回 CLAUDE.md ⏱️ 锚点
- ✅ `session_date` 与过期判断只采信 `[time-context::hook-only]` 注入行；过期 = 距 `expired_on` > 7 天 → 强制带 action；写绝对日期，禁相对词；hook `UNAVAILABLE` → 显式标"无法确定当前时间，过期判断挂起"
- ✅ 任何"选 X / Y / Z"的 step 必带 `DEFAULT_ACTION`（无 default 的决策门 = 阻塞新 session 等于无门）
- ✅ frontmatter 必填：`head_sha` / `lane` + `session_id` / `next_command` + `verify_command` + `expected_outputs` / `dirty_modified` + `dirty_untracked` 两个 int / `deploy_status`（有部署管道时）
- ✅ 安全 / 危机类 claim（注入 / 污染 / 入侵 / 数据丢失）一律走 handoff-recovery.md 的 Confab Gate，status 不准直接写 `ACTIVE`
- ❌ 不把 handoff 内容写进 MEMORY.md（临时交接 ≠ 稳定 axiom）；不在当前 session commit dirty files 凑"已完成"（除非用户明确说）

## 反 pattern（交付前逐条自检，命中即返工）

| 反 pattern | 为什么坏 |
|---|---|
| 全是抽象总结无 file path / line number | 无法直接动手 |
| 只写 what 不写 why | 推理链丢，重复讨论已决问题 |
| 块内指向另一文档不 inline 决策 | 摩擦 +1，Colar 粘完还要跳转 |
| 可粘贴块不自包含（sha/命令写"详见某处"） | 块（及其 per-session 落盘副本）就是全部现场，指向别处 = 粘完还要跳转、可能已失效 |
| 一个块跨多个不相关项目 | 单一职责违反；一主题一块，别混 |
| 落盘写**共享** `LATEST.md`（多 session 抢同一文件） | 重新引入并发覆盖失效模式（per-session `<session_id>.md` 不在此列，反而是必需的兜底） |
| 缺 `lane` / `session_id` 就交付 | 多 session 并行时 /resume 无从校验，误把 A 项目的块粘进 B 项目 |

---

**用户参数**：$ARGUMENTS
