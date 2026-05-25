# Hermes Pilot Session Handoff (2026-05-24)

下 session 入口文档。包含完整上下文 + 待办 + 红线。

---

## 已 ship (本 session 2026-05-24)

### 1. Hermes 自我迭代 infra 第一层 (SQLite + FTS5 cross-session recall)
- `~/Desktop/agency-agents/scripts/recall/schema.sql` — DB schema (FTS5 external content + trigger)
- `~/Desktop/agency-agents/scripts/recall/index.py` — jsonl → SQLite indexer (含 secret redaction + race fix)
- `~/Desktop/agency-agents/scripts/recall/recall.py` — CLI (含 `--unsafe` flag, default redact PII)
- `~/Desktop/agency-agents/scripts/recall/redact.py` — 11 类 secret pattern + 3 类 PII
- `~/Desktop/agency-agents/scripts/recall/pilot_audit.py` — pilot 周期审计
- `~/Desktop/agency-agents/scripts/hooks/recall_index.sh` — Stop hook (已接 `~/.claude/settings.json`)
- `~/.claude/recall.db` — 405 session / 21490 message / 26.8MB / chmod 600

### 2. Hermes pilot 3 个 skill (从 5 个 feedback 迁出)
- `~/Desktop/agency-agents/integrations/hermes/skills/nextjs-hmr-proactive-restart/SKILL.md`
- `~/Desktop/agency-agents/integrations/hermes/skills/ui-design-emoji-discipline/SKILL.md`
- `~/Desktop/agency-agents/integrations/hermes/skills/max-mode-protocol/SKILL.md` (合并 3 feedback: idea_eval_max_mode + explicit_trigger + self_ritualization)

### 3. Memory 重组
- 5 个 feedback 删除 (已迁 skill)
- 7 个 feedback rename → 6 个 `user_*` + 1 个 `reference_*`
- MEMORY.md 索引更新

### 4. 3 专家审计 + 7 critical fix
- shell injection / uuid 重复 / FTS5 rebuild / race / chmod 600 / secret redact / FTS5 query escape

### 5. 决策档案
- Triage plan 归档到 `~/.claude/projects/-Users-colar-Desktop-agency-agents/memory/transcripts/2026-05-24_hermes_pilot_triage_plan.md`
- 本文件 = session handoff

---

## 待办 (按优先级)

### P0 — 2026-06-07 必做: Pilot KPI Gate

```bash
python3 ~/Desktop/agency-agents/scripts/recall/pilot_audit.py --window 14d
```

KPI gate (见 `PILOT_BASELINE.md`):
- ≥1 pilot attach-rate ≥30% (cutoff 2026-05-24 之后真 attach) → 通过, 选下 batch 3 个
- 全部 <30% → 硬 kill skill 系统, 检查 SKILL.md description 质量
- 全部 >50% → 加速, 一次扩 10 个 skill

### P1 — Pilot 通过后: 下 batch skill 扩展

从 `triage_plan` 类 A 剩余 26 个挑高频:
- credential-handling-block (61 hits)
- python-ts-schema-drift-sync (51)
- env-file-secret-safe-handling (42)
- auto-sync-memory-to-github (41)
- soul-drift-three-guard-check (34)
- buildinpublic-account-calibration (39)

(完整列表见归档 triage_plan transcripts/2026-05-24_hermes_pilot_triage_plan.md)

### P2 — Pilot 通过 + 下 batch 扩完后: Sprint 2 (auto-emit)

Skill 自动 emit 机制（session 结束 LLM 判定是否生成 SKILL.md 草稿）。
**前提**: discovery 验证 attach rate 真在 work, 否则 auto-emit 就是垃圾自动化。

### P3 — Sprint 3 (DSPy/GEPA-style evolution)

对高频 skill 跑反思式演化优化。**前提**: 至少 1 个 skill 跑通 closed loop (emit → use → patch)。

---

## 红线 (新 session 不要做)

1. **不删 ~/.claude/recall.db** — 26.8MB 历史 transcript 灌库，删了重灌要 3 秒但 redaction pattern 升级后必须 `--rebuild`
2. **不动 settings.json Stop hooks 顺序** — recall_index.sh 必须在 git sync 之后, memory_drift_check 之前
3. **不 add ~/.claude/recall.db 到任何 git repo** — 即使误开发现也立刻 `git rm --cached`
4. **不直接 commit auto-emit 的 SKILL.md 草稿到 master library** — Sprint 2 启动后,草稿必须落 `_drafts/`,Colar 手工 promote
5. **不跑 `pilot_audit.py --window` 之前**先 cutoff 一下日期 — 当前脚本看全窗口,会把 2026-05-24 之前讨论 skill 时的 FTS5 命中算成 attach (false positive)
6. **不在 demo / 录视频 / 屏幕共享时跑 `recall --unsafe`** — 会 dump 历史 secret 真值

---

## 启动新 session 时读的文件 (顺序)

1. `~/.claude/CLAUDE.md` (SOUL, 自动)
2. `~/Desktop/agency-agents/CLAUDE.md` (项目 workflow, 自动)
3. `~/.claude/projects/-Users-colar-Desktop-agency-agents/memory/MEMORY.md` (自动)
4. `~/Desktop/agency-agents/scripts/recall/SESSION_HANDOFF_2026-05-24.md` (本文件)
5. `~/Desktop/agency-agents/scripts/recall/PILOT_BASELINE.md` (KPI gate)
6. (按需) `~/.claude/projects/.../memory/transcripts/2026-05-24_hermes_pilot_triage_plan.md` (历史决策)

---

## 关键决策记录 (防止下 session 翻案)

- **Architect 推荐 pilot 3 的具体名单被 override** — 因为数据 verify 显示 0 重叠。最终选: nextjs HMR / UI emoji / max-mode-protocol
- **max-mode-protocol 合并 3 个 feedback** — 不拆 3 个独立 skill,因功能重叠
- **xhs format 不在 pilot 3** — Colar 自承"稍微保留",优先 ROI 不如 max-mode
- **拆双文件 7 个 pending** — 等 pilot 验证才执行,避免一次性扩展太多 skill
- **DSPy 装不装 pending** — Senior Dev 反对装 DSPy,推荐自写 200 行 reflection loop。Sprint 3 启动时再拍板

---

## 验证 infra 是否还在工作

```bash
# 1. DB 健康
python3 ~/Desktop/agency-agents/scripts/recall/index.py --stats
# 期望: Sessions 400+ / Messages 20000+ / DB ~25-30MB

# 2. recall 工作
python3 ~/Desktop/agency-agents/scripts/recall/recall.py "Hermes pilot" --limit 3

# 3. Stop hook 在
python3 -c "import json; d=json.load(open('/Users/colar/.claude/settings.json')); print(len(d['hooks']['Stop'][0]['hooks']), 'Stop hooks')"
# 期望: 3 Stop hooks

# 4. 3 pilot skill 在位
ls ~/Desktop/agency-agents/integrations/hermes/skills/ | grep -E '(nextjs-hmr|ui-design-emoji|max-mode-protocol)'
# 期望: 3 行
```
