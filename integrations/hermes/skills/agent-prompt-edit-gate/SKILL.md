---
name: agent-prompt-edit-gate
description: "改动 agent prompt body（master .md frontmatter 之后的正文）时强制跑 before/after eval 对比 pass rate，别盲改。已覆盖 agent（code-reviewer / senior-developer）走强制 gate；未覆盖 agent 属飞盲，先告知 Colar 要不要补 case。含四条铁律（退出码判 pass 别用管道 / 只跑 --agent 省 token / implementer 类无工具沙盒的 validity caveat / degradation-probe 用 majority-of-3）。Use when: editing the prompt body of any agent .md in colar-agents, or before/after running eval/run-eval.sh to judge whether a prompt change regressed an agent."
version: 1.0.0
source: migrated from colar-agents/CLAUDE.md (2026-08-04 /doctor check 4 — 常驻正文迁 attach-on-demand)
---

## When to Use

**凡改动 agent prompt body（master `.md` 的 frontmatter 之后正文），强制 before/after 跑 eval 对比 pass rate。** 这是层 4 eval 存在的唯一目的——别再盲改 prompt。

**不触发**：改 frontmatter（routing metadata：`description` / `route-to-me-when` / `tools`）不触发 gate——eval 只测 output 行为，不测路由。

调用点：Tier 2 流程 ⑦ `/review` 之后、Tier 3 流程 ⑥ build/test 之时，若本次改了已覆盖 agent 的 prompt body。

## 触发与动作

**2026-08-04 起部署的 6 个 agent 全部有 eval 覆盖**（此前只有 2 个，其余 4 个在盲改）。

| 改的是 | 动作 |
|---|---|
| **任一已部署 agent** 的 prompt body | **强制 gate**：改前跑 `--agent <slug>` 存 baseline → 改 → 再跑对比；pass rate 掉 or degradation-probe 翻 FAIL = 这次改伤了 agent，回退或修 |
| **新加的 agent**（还没进 `run-eval.sh` 的 `agent_file()` 注册表） | **无 eval 覆盖 = 盲改**。告知 Colar「{agent} 无 eval case，改 prompt 飞盲；要先补 case 再改吗？」按 SOUL ask-when-uncertain 处理 |

> `run-eval.sh` 的 `agent_file()` **就是覆盖面注册表**——没在里面的 agent 等于没覆盖。加新 agent 时同步加一行 + 一个 `cases/<slug>.jsonl`，否则覆盖面会静默退化回盲改。
>
> slug ↔ agent：`code-reviewer` · `senior-developer` · `agent-infra` · `applied-ai` · `frontend-developer` · `vc-critic`（后者只有纪律 case，原因见 `eval/README.md` 的 validity caveat）

## 命令（单 agent 迭代用 `--agent` = 8 calls，别随手跑全量 44 calls）

```bash
cd ~/Desktop/colar-agents
bash eval/run-eval.sh --agent code-reviewer    # baseline，改 prompt 之前
# ... 改 engineering/engineering-code-reviewer.md 正文 ...
bash eval/run-eval.sh --agent code-reviewer    # after，对比 pass rate
echo $?                                          # 0=全 pass，1=有 FAIL（可 gate CI）
```

## 铁律

- **退出码判 pass/fail，别用管道**：`| tee` 让退出码取 tee（恒 0）掩盖 FAIL。要存 log 用 `bash eval/run-eval.sh 2>&1 | tee log.txt; exit ${PIPESTATUS[0]}`，否则裸跑 `; echo $?`。
- **全量 ~16 Opus calls 有真实 token 成本**，改单 agent 只跑该 agent（`--agent`），smoke 用 `--case`。别随手跑全套。
- **implementer 类（senior-developer）validity caveat**：纯 `claude -p` 无工具沙盒会让 implementer 退回"描述计划"而非贴代码；`sd-` 实现 case 已用「显式声明无工具→直接贴代码」修，degradation-probe `sd-no-architect-overreach` 两种环境都 valid。bare 实现 prompt 在此 FAIL 多半是环境错配不是 prompt 退化——别据此回退生产 prompt。
- **master 是 symlink → 部署**，改 master 即时生效且 eval 读的就是 master，无需 sync。
- **degradation-probe 用 majority-of-3，别信单跑**：probe case 的 verdict 受 agent 输出非确定性影响会偶发翻车（实测 `sd-no-architect-overreach` 同 prompt 单跑 PASS↔FAIL）。判 probe 通过/回归用 `--case <probe-id>` **跑 3 次取多数票**，单次 PASS/FAIL 不作数。普通 case 单跑即可。

## 变异来源辨析（抖了先归因再动手）

eval verdict 跨重跑抖动有 **judge 变异 / agent 变异** 两个独立来源，修法相反。完整辨别与修复流程（读多次 judge reasoning 定性 + probe majority-of-3）见 [eval-judge-variance-diagnosis](../eval-judge-variance-diagnosis/SKILL.md)。

## 延伸

详见 `eval/README.md`。覆盖面扩展（补 agent cases）见该 README「Adding a case」。
