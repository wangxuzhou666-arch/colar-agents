---
description: 任务收尾一键化 — secret gate → diff → build → review → commit/push（project lane）+ memory/SOUL/drift 后置 lane，按 Tier 自动缩放
argument-hint: "[scope 提示 / --tier1 / --no-memory / --no-push / --dry，均可选]"
---

# /ship — 任务收尾自动化

把 Tier 2/3 收尾流程压成一条命令，但**拆成两条解耦的 lane**：
- **Project lane**（主线，机械、应尽快落地）：secret gate → diff 自检 → build → review → commit → push
- **Memory lane**（后置、judgment-heavy、可能挂起）：save memory（含 SOUL 4-class）→ drift-check → commit → push

> **核心设计：Memory lane 的"停下等确认"（SOUL 升级）绝不阻塞已验证的 project 代码落地。** project 先 ship，memory 后补。

**纪律**：act then inform。机械步骤不问，judgment 步骤（SOUL 升级 / git 冲突 / build 失败 / 凭证命中 / public repo）必停。报告如实——挂了说挂了，跳过了说跳过 + 原因。

## 触发 / 不触发

- ✅ `/ship` / "收尾" / "提交并同步"；feature/fix 改完准备落地；改了 memory 要同步
- ❌ 纯读/探索 session、还没改完（"做完剩下的" → 先做完再 ship）

## 参数

| 参数 | 作用 |
|---|---|
| `<scope 提示>` | 一句话说本次干了啥，喂给 commit message + memory 判断 |
| `--tier1` | Micro 模式：跳 review（但 **secret gate 永不跳**） |
| `--no-memory` | 跳过整条 memory lane |
| `--no-push` | 只 commit 不 push |
| `--dry` | 只跑 Step 0 + secret gate（只读），报告计划后停 |

每步开头打 `[Step N] <name>` 进度行；跳过/失败打 `⏭ skipped (原因)` / `❌ failed`。

---

## Step 0 — Scope 探测 + 全部前置 guard

**先锚定到 repo 根**（子目录跑 `/ship` 时 `git status` 会出 `../` 相对路径误导判断）：
```bash
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "不在 git repo，退出"; exit; }
cd "$ROOT"
BRANCH=$(git branch --show-current)        # 空 = detached HEAD
git status --short && git log --oneline -3
```

**Guard（命中即停，不往下走）**：
- `BRANCH` 为空 → **detached HEAD，停下告知**（无法安全 push）
- `git status --short` + memory repo 都为空 → "**无改动，无可 ship**"，退出
- `gh repo view --json visibility -q .visibility 2>/dev/null` → 记下 `PUBLIC`/`PRIVATE`，**PUBLIC 时 secret gate 升为阻断级**，计划行标 `⚠️ target=PUBLIC`

**同 repo 碰撞检测**（关键）：
```bash
MEM=$(git -C ~/Desktop/colar-memory rev-parse --show-toplevel 2>/dev/null)
# 若 "$ROOT" == "$MEM" → SINGLE-REPO 模式：只跑一条 lane、一个 commit，不做"双 repo 分别提交"
```
- `~/.claude/projects/.../memory` 是软链，**真身是 `~/Desktop/colar-memory`**
- **SOUL.md 住在 project repo（`agency-agents/soul/`），不是 memory repo** —— SOUL 改动走 project lane 的 commit
- ByteDance Mac 路径不同 → memory repo 不存在则"⏭ memory lane skipped (repo 未找到)"

**Lane 判定**：
- 仅 memory dirty、project clean → 跳 Project lane，直走 Memory lane
- 仅 project dirty → 跳 Memory lane（除非 Step 4 判定有可存内容）
- 都 dirty → 两条都跑（先 project 后 memory）

**Tier 判定**：单文件/<~30 行/无逻辑分支 → Tier 1（跳 review）；否则 Tier 2/3。`--tier1` 覆盖。

输出计划行：`Ship: <repo>[PUBLIC?] · mode=<single/dual> · lane=[project?,memory?] · Tier<N>`。`--dry` 跑完 secret gate 后停。

---

## Step 1 — 🔒 Secret Gate（确定性、Tier 无关、永不跳过）

> .env.local 事故的教训：**零信任，不靠模型肉眼读 diff**。这是硬 gate，先于任何 commit，Tier1 也跑。

扫 **staged + 未跟踪新增文件**（`git diff HEAD` 看不到 untracked，新增的 `.env.local` 会漏）：
```bash
# 1) 高危文件名（含 untracked）
{ git diff --cached --name-only; git ls-files --others --exclude-standard; } \
  | grep -iE '\.env|\.pem|\.key$|\.p8$|credential|secret|id_rsa|service.*account' && HIT=1
# 2) 高熵明文 secret（只扫 staged + untracked 内容）
git diff --cached | grep -icE 'AIza[0-9A-Za-z_-]{35}|sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{36}|-----BEGIN.*PRIVATE KEY|xox[baprs]-'
```
**命中处理**：
- **立即停，不 commit**。报告**只给 文件名 + 行号 + 命中规则名**，**绝不把匹配内容贴进 chat**（守 SOUL 凭证铁律，避免二次泄漏）。用 `grep -l`（只出文件名）/ `-c`（只出计数）。
- target=PUBLIC 时这是**阻断级**——推进公开仓库历史不可逆，必须人工处理。
- ⚠️ 诚实标注：PUBLIC repo `agency-agents` 无 CI gitleaks（`.gitleaks.toml` 是死配置），**本地这道 gate 是唯一防线**，别假装有 CI 兜底。

`--dry` 在此 gate 之后停。

## Step 2 — /diff 自检（build 之前，CLAUDE.md 铁律）

读 `git diff HEAD` + 新增文件，自检：改动是否都服务本次目标？有无调试残留/`console.log`/注释代码？有无误删误改？发现偏差先纠正再继续。

## Step 3 — build / test（按项目类型探测）

| 探测信号 | 命令 |
|---|---|
| `package.json` 有 `build` script | `[ -f tsconfig.json ] && npx tsc --noEmit;` + `npm run build` + test（Next/Vite/plain 通用，tsc 仅在有 tsconfig 时跑） |
| `*.xcodeproj` / Swift | `xcodebuild`（项目既定 scheme） |
| `pyproject.toml` 或 `requirements.txt` | `pytest` / `ruff check`（按项目既定） |
| repo == agency-agents | `bash ~/Desktop/agency-agents/scripts/lint-agents.sh`（绝对路径） |
| 无 build 系统（纯 md/脚本） | ⏭ "无 build step，跳过" |

**失败 → 停，贴真实报错，不 commit、不粉饰。** 修完后重敲 `/ship` 即可（Step 0-3 幂等可安全重跑，commit 之前无 git 副作用）。

## Step 4 — /review（Tier 1 跳过）

`/code-review` 扫 diff：correctness + 安全 + 逻辑。命中 high-confidence → 列出 + 问"先修再 commit 吗"；**修完 loop 回 Step 3 重 build**，不带未验证改动直接 commit。仅 info 级 → 一行提示继续。

## Step 5 — Project commit + push

```bash
git push origin "$BRANCH"   # 显式 origin+branch；agency-agents 有 upstream remote，禁裸 push
```
- commit：conventional `feat(scope):…`/`fix(scope):…`（英文）+ 结尾空行后加
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- push 前 `git status` 须 clean；无 upstream → `git push -u origin "$BRANCH"`
- `git pull --rebase origin "$BRANCH" && git push origin "$BRANCH"`；**rebase 冲突 → `git rebase --abort` 回干净点 + 停下告知**（绝不 force push）
- `--no-push` → 只 commit
- **SINGLE-REPO 模式：到此整条流程结束**（不再跑下面的独立 memory 提交）

✅ Project lane 完成即输出：`project ✅ <sha> pushed origin/<branch> · build:pass/skip · review:clean/N/skip@tier1`

---

## Memory lane（后置，`--no-memory` 跳过；SINGLE-REPO 模式不进此 lane）

### Step 6 — Save Memory + SOUL 4-class

**先判值不值得存**：只存非显而易见——被排除方案 + 关键 trade-off + 下次需继承上下文。代码模式/路径/git 可查 → 不存。无可存 → "⏭ memory skipped (无非显而易见决策)"。

**幂等保护**：先 `git -C ~/Desktop/colar-memory status --short`，若本次 memory 已 dirty/已写 → 不重复写、不重复加 pointer。

**有可存内容 → 强制跑 SOUL 4-class Impact Analysis**：

| 关系 | 判断 | 处理 | 话术 |
|---|---|---|---|
| **重复** | SOUL 已有同 axiom | 不写 | "SOUL § X 已 cover，跳过" |
| **升级** | 否定/替代 SOUL | 写 + 提议 SOUL diff | "升级 § X：旧=… 新=… 同步吗?(y/n)" → ⛔ **停等拍板（只阻塞本 lane，project 已 ship）** |
| **细化** | SOUL axiom 的实现细节 | 写 + 加 'See SOUL § X' 反向 link | "细化 § X，已加 link" |
| **正交** | 与 SOUL 无交集 | 正常写 | "SOUL impact: 无 · 写入" |

写文件：frontmatter（name/description/type）+ feedback/project 补 `**Why:**`/`**How to apply:**`；`MEMORY.md` 加/更新一行 pointer 归到对应 section。
**时间锚点**：日期取自 `[time-context::hook-only]` 注入行，time-bound 事实戳绝对 `YYYY-MM-DD`，timeless axiom 不戳；hook UNAVAILABLE 则拒绝戳日期。
过程文件**只列路径 + 一句话**，不 open、不粘原文。

### Step 7 — Memory drift + commit + push

```bash
bash ~/Desktop/agency-agents/scripts/drift-check.sh          # SOUL 黑名单措辞 + 失效路径
bash ~/Desktop/agency-agents/scripts/memory_drift_check.sh   # unindexed / dead link / stale
```
命中只报 **文件名 + 问题类型**，不贴文件内容（drift 可能扫到含凭证的 `reference_*.md`）。clean 时静默。

commit + push（memory repo）：
```bash
git -C ~/Desktop/colar-memory add <本次具体文件路径>   # 禁 add -A / add . —— 防 over-stage 未 review 的凭证草稿
git -C ~/Desktop/colar-memory diff --cached --stat       # 自检范围
git -C ~/Desktop/colar-memory commit -m "sync memory: <one-line>"   # 本地 commit = pre-authorized YOLO
git -C ~/Desktop/colar-memory pull --rebase origin main && git -C ~/Desktop/colar-memory push origin main
```
冲突 → `rebase --abort` + 停下告知（远端是双机权威源，绝不强推）；gitleaks CI 失败 → 立即告知。

---

## 收尾摘要（两条 lane 分别报）

```
✅ Shipped
  project: <sha> · pushed origin/<branch> · build:pass · review:clean
  memory:  <sha> · pushed · N files · drift:clean   (或 ⏸ 等你确认 SOUL § X 升级)
```

## 硬规则

- ❌ secret gate 命中 → 停，只报文件名不贴原文；PUBLIC repo 阻断级
- ❌ build/test 失败 → 停，贴真实报错，不假装通过
- ❌ SOUL「升级」类 → 停等确认（只阻塞 memory lane，不连坐 project）
- ❌ git 冲突 → `rebase --abort` + 停，绝不 `push --force`
- ❌ 禁裸 `git push` / `git add -A`（agency-agents 有 upstream remote；over-stage 会带出凭证草稿）
- ✅ secret gate / build 是 Tier 无关的；review 才按 Tier 缩放
- ✅ 过程产物只列路径不 open、不粘原文；报告如实标跳过+原因
- ✅ recall 索引交给 Stop hook，本命令不重复跑

## 反 pattern（执行后自检）

| 反 pattern | 为什么坏 |
|---|---|
| 靠肉眼读 diff 找 secret | 大 diff/untracked 会漏，退回事故前失效面 |
| 命中凭证把原文贴进 chat | 二次泄漏，违反 SOUL 凭证铁律 |
| SOUL 升级连坐 project commit | judgment 步骤卡死已验证的机械步骤 |
| 同 repo 双重 commit | cwd==memory 时一个 repo 提交两次，历史脏 |
| 裸 push / add -A | 推错 remote / 带出未 review 凭证 |
| build 没过就 commit | 把坏代码 ship，信任崩 |
| 每次硬塞一条 memory | 动态/显而易见内容入 memory = 内容腐烂 |

## 不该做的

- ❌ 不替你决定「升级 SOUL」——只提 diff，你拍板
- ❌ 不生成 handoff 文档——那是 `/handoff` 的事；`/ship` 只管落盘
- ❌ 不在没改完时凑"已完成"；不为纯读 session 触发
- ❌ 不把 memory 内容写进 project repo（反之亦然）

---

**用户参数**：$ARGUMENTS
