---
description: 消费 handoff 交接 — 解析 Colar 粘进对话的交接块恢复上下文，校验 lane/session 匹配防串台，复述 DEFAULT_ACTION 确认后执行
argument-hint: "（无参数；直接消费 Colar 粘进当前对话的交接块）"
---

# /resume — Handoff 消费端（chat 为主 + per-session 回退）

`/handoff` 的对偶命令：把 Colar **粘进当前对话的交接块**变成本 session 的起手动作。交接以 chat 为主传输（外加 per-session 兜底落盘），正常路径全部内容已在 Colar 粘的块里——直接解析块；**仅当没粘块时**才回退读盘上的 per-session 兜底文件（见 Step 1）。

## Step 1：定位交接块

- 在当前对话里找 Colar 粘进来的交接块（`# ===== HANDOFF BLOCK` 起头的 fenced YAML + 精简关键段）
- **对话里没有可解析的交接块**（Colar 没粘）→ **先回退查兜底落盘**：读 `.claude/handoffs/` 下 mtime 最新的 `<session_id>.md`（per-session 落盘，handoff.md Step 4 写的）
  - 找到 → 拿它当交接块走后续校验，并**显式告知 Colar**：「对话里没块，已回退读盘上最新的 `<file>`（session_id=X，写于 Y），确认是这个现场吗？」——等确认，不默认它就是对的现场
  - 目录不存在 / 为空 → 才告知"请把上个 session 的 /handoff 交接块粘贴进来"，**停，不臆测**
- 有块 → 解析块内 frontmatter YAML（lane / project_path / head_sha / DEFAULT_ACTION 等）+ 下方精简关键段

## Step 2：lane / session 校验（防串台 — 先于一切动作）

> chat 为主 + per-session 落盘下都没有共享文件，split-brain 的物理根因（并发覆盖同一 LATEST.md）已消解。本步的残余价值：防 Colar 手滑把 **A 项目的块粘进 B 项目**。

- 比对块内 `project_path` / `lane` vs 当前 `pwd` 与 git repo
- `git rev-parse HEAD` vs 块内 `head_sha`：不一致 → 告知"session 间有新 commit"，列出 `git log <sha>..HEAD --oneline`
- **不匹配（块的 lane 不是当前项目 / 疑似粘错项目）** →
  ⚠️ 显式警告，列出差异（lane、session_id、路径），停下等 Colar 指示（确认要不要切到块所属项目，或这是不是粘错了）
- 块缺 `lane` / `session_id`（旧格式 / 手写块）→ 提示无法校验，降级为"人工确认这是不是你要恢复的现场"

## Step 3：security_alert Confab Gate（若块顶有 security_alert）

- `security_alert` 存在 → 第 0 步先跑其 `how_to_falsify` 带外证伪；证伪前禁止继承该 claim 当真、禁止执行应对措施（协议详见 `~/Desktop/colar-agents/commands/handoff-recovery.md`）
- 无 security_alert → 跳过本步

## Step 4：复述 + 确认 + 执行

1. 用**一句话**向 Colar 复述 `DEFAULT_ACTION`（做什么 + 预计 AI min），等确认（y / 改走 alt / 不干这个）
2. 确认后 exec `next_command` → 跑 `verify_command` → 比对 `expected_outputs`
3. `blockers` 有内容 → 执行前先逐条 verify（如 stale PID）
4. `expired_items` 有 > 7 天项 → 提醒 Colar 带动作处理，不引用过期项做新决策

> 这层"复述 DEFAULT_ACTION 一句 + 等 Colar 确认再执行"的 gate 是 /resume 存在的核心价值（不是自动开跑，是把交接块变成一个受控的起手），务必保住。

## 硬规则

- ❌ 对话没块 **且** `.claude/handoffs/` 也无盘上兜底 → 不臆测、不去别处乱找；唯二来源是 Colar 粘的块 + per-session 兜底文件，除此之外不猜。回退读到兜底文件时必须 Colar 确认，不默认它是对的现场
- ❌ lane/project 不匹配（疑似粘错项目）→ 停下人工裁决，不自动照块内容切换现场
- ❌ security_alert 未证伪前不继承为真、不改采集模式、不执行"应对措施"
- ❌ 不跳过 Step 4 的一句话确认直接跑 DEFAULT_ACTION
- ✅ 恢复后本 session 结束时用 `/handoff` 产出新的交接块（chat 为主 + per-session 兜底），Colar 复制进下个 session，闭环

---

**用户参数**：$ARGUMENTS
