# Hermes Pilot Skill Baseline (2026-05-24)

3 个 pilot SKILL.md 创建于 **2026-05-24 18:30 PT**。这是 attach-rate 验证的起点 anchor。

## Baseline (今日之前 7 天 trigger 密度, 真实使用频率)

| Skill | trigger sessions (7d) | trigger sessions (30d) |
|---|---|---|
| nextjs-hmr-proactive-restart | 16 | 154 |
| ui-design-emoji-discipline | 11 | 105 |
| max-mode-protocol | 4 | 49 |

(attach 数 = 0, 因为 skill 今天才创建。`pilot_audit.py` 报的非零 attach 是 false positive — FTS5 命中 SKILL.md 创建/讨论时的字符串)

## 验证流程

```bash
# 每周跑 (推荐周日晚)
python3 ~/Desktop/colar-agents/scripts/recall/pilot_audit.py --window 7d

# 2 周 final report
python3 ~/Desktop/colar-agents/scripts/recall/pilot_audit.py --window 14d
```

**对比策略**: 看 `attach` 列在 cutoff (2026-05-24) **之后**的增量。`pilot_audit.py` 看的是全窗口,需手动剪掉 cutoff 之前的 trigger 数。下次升级 audit 脚本时加 `--cutoff 2026-05-24` 参数。

## 2 周后 (2026-06-07) KPI Gate

| 结果 | 行动 |
|---|---|
| ≥1 pilot attach-rate ≥30% (cutoff 之后真 attach) | pilot 通过, 选下 batch 3 个 (从 triage_plan 类 A 剩余 26 个里挑高频) |
| 所有 pilot attach-rate <30% | 硬 kill: 检查 SKILL.md description 质量 / Claude Code skill discovery 机制是否真在 work / 删 skill 回滚 |
| 3 pilot 全部 attach-rate >50% | 加速: 一次扩到 10 个 skill, 不走 2 周观察 |

## 备注

- pilot 期间 Claude Code 不会主动告知 attach 哪个 skill,需通过 transcript 关键词 grep 间接观察
- 如果 cutoff 后没有 attach 信号但你在 dev 时确实"用到"了规则(纯 memory recall),说明 skill 系统对你的工作流可能不是真 ROI
- Sprint 2 (auto-emit) 必须等 pilot 通过才启动
