# colar-agents 仓规则

> 全局身份 / 行为规则在 SOUL（`soul/SOUL.md`，即 `~/.claude/CLAUDE.md`），冲突时以 SOUL 为准。本文件只管「在本仓里改东西」。

## 任务规模速记

- **Tier 1（单文件 / 单函数、机械改动）**：act → `/diff` → commit。
- **Tier 2/3（跨文件 / 新系统 / 跨 session 重构）**：plan（架构级用 EnterPlanMode）→ 执行 → `/diff`（build 之前看，提前发现方向偏差）→ build / test → `/code-review` → `/ship` 收尾。
- 主 loop 自己干还是派 agent、判断类何时停下来问（走 `AskUserQuestion` 弹窗），一律按 SOUL § Personality 与 § Tool-Call Discipline「薄编排」，本文件不另立规则。
- 改了 agent prompt body → 必过下方 Agent Prompt-Edit Gate。
- 界面 / 视觉类任务 → skill `ui-design-pipeline`（Design Bridge：Replication 复刻 74 品牌 / Genesis 原创）。

## Agent Prompt-Edit Gate（改 agent prompt 必跑 eval）

凡改动 agent prompt body（master `.md` frontmatter 之后的正文），强制 before/after 跑 eval 对比 pass rate——别盲改。改 frontmatter（routing metadata）不触发。完整流程（触发表 / `eval/run-eval.sh --agent` / 四条铁律 / 变异来源辨析）见 skill `agent-prompt-edit-gate`；基线读数在 `eval/BASELINE.md`。

## Agent 配置纪律

- **只编辑 master**（`engineering/` · `design/` · `specialized/` 下的 `.md`）。`~/.claude/agents/` 只放指向 master 的 symlink：`ln -s ~/Desktop/colar-agents/<domain>/<file>.md ~/.claude/agents/<file>.md`，绝不放非 symlink 文件。
- frontmatter 里不写行内 `#` 注释（整行会被当成 model ID 发给 API）——`scripts/hooks/agent_frontmatter_guard.sh` 硬拦。
- 增删 agent 后跑 `python3 ~/Desktop/colar-agents/scripts/gen-agent-index.py` 重生成 `agents/INDEX.md`（自动生成，勿手改）。2026-10-17 读数：master 8 个，全部已 symlink 部署到全局；以 `ls ~/.claude/agents/` 现查为准。运行时可调用集以系统注入的 available agent types 为准。
- **项目层**：项目 `.claude/agent-config.yaml` 声明要哪些 agent，由 sync 脚本从 master 复制进该项目 `.claude/agents/`（见下方脚本速查）。不手动往项目 `.claude/agents/` 放文件。
- **单项目破例**：知识 100% 绑定单一项目、对其他项目零复用价值的 agent，可手写进该项目 `.claude/agents/`（master 不留副本——sync 机制不支持这类物种，master 收了会在清理中被当死库存砍掉），并在该项目文档记录破例。现有两例都在织锦（`~/Desktop/创业/fabric-agent-demo`）：`fabric-architect` · `pattern-cad`，破例记录在织锦仓自己的文档里。裸 home lane 靠本仓的 pointer skill 桥接过去：`fabric-architect-pointer` · `pattern-cad-pointer` · `fabric-loop-pointer`。
- 路由兜底（理想 agent 未部署 / 两个 agent 都像）：见 memory `feedback_agent_routing_fallback_ladder.md`。

## Skill 接线

- skill 真身住 `integrations/hermes/skills/<name>/`，索引 `integrations/hermes/skills/SKILLS.md`（权威）。新 skill 走 `/capture-skill`。
- **新 skill 必须接线才可调用**：Claude Code 不从 `integrations/hermes/skills/` 发现 skill（Hermes runtime 已放弃），必须 `ln -sn ~/Desktop/colar-agents/integrations/hermes/skills/<name> ~/.claude/skills/<name>`（`-n`：链接已存在时报错，而不是顺着旧链接在仓内目录里再建一个自指链接）。缺这一步 skill 不出现在可调用列表，且加载失败不报错（静默降级）。

## Hooks 开发

- hook 脚本在 `scripts/hooks/`，每条规则的判据写在脚本头部注释；接线以 `~/.claude/settings.json` 为准。
- 判别力自证测试在 `scripts/hooks/tests/`，改规则前后都要跑，必须全过。
- 新增 hook 前先过 SOUL § Tool-Call Discipline 的「机械 → hook / 判断 → 文本」判据。

## 脚本速查

- `scripts/sync-all.sh` — 同步 `~/.claude/agent-config.yaml` + 所有 `~/Desktop/*/.claude/agent-config.yaml` 项目（其余路径加进脚本内 `EXTRA_PROJECTS`）。
- `scripts/sync-agents.sh <project-path>` — 只同步单个项目；用户级走 symlink，项目级走 cp 快照。
- `scripts/gen-agent-index.py` — 重生成 `agents/INDEX.md`。
- `scripts/memory_drift_check.sh` — memory 语料漂移扫描，已接 Stop hook（advisory，clean 时静默）。
- `scripts/drift-check.sh` — SOUL 黑名单措辞 + 失效路径扫描，手动跑（配置 `soul/drift-blacklist.txt` / `soul/drift-whitelist.txt`）。

## 收尾

- 提交 / 推送：`/ship`（按 Tier 自动缩放）。
- **本仓 origin 是 PUBLIC**（`wangxuzhou666-arch/colar-agents`）：push 前先做隐私扫描（织锦业务细节、个人信息、memory 内容），扫完由 Colar 定哪些可以公开，再 push。
- 可复用 procedure：`/capture-skill`（含接线步骤）。
- 非显而易见的决策：`/save-memory`；SOUL ↔ memory 同步规则见 SOUL § SOUL ↔ Memory Sync Discipline。
