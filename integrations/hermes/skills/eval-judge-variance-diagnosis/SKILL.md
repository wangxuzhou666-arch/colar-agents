---
name: eval-judge-variance-diagnosis
description: "跑 LLM-judge / agent-output eval 时，若同一 case 的 verdict 跨重跑抖动（PASS↔FAIL 翻转或 score 大幅飘），先辨 variance 来源再修——别条件反射收紧 criteria。读多次 judge reasoning：描述同一输出却给不同分=judge 变异（收紧 criteria）；描述不同输出=agent 变异（修 agent prompt，criteria 没问题）。degradation-probe 单跑不可信，用 majority-of-3。Use when: an eval/LLM-judge verdict flaps across reruns, or before \"fixing\" a flaky eval case."
version: 1.0.0
source: session-derived (2026-06-30)
---

## When to Use

跑输出质量 eval（agent 输出 → LLM judge 打分）时，**同一 case 同一 input 跨重跑结论不稳**。任一命中即启：

1. degradation-probe / 边界 case 重跑结论翻转（PASS↔FAIL）
2. 准备"收紧 criteria"修一个 flaky case **之前**（先确认是不是 criteria 的锅）
3. 拿单次 eval 结果当回归基准做 gating 决策之前

**不触发**：
- 普通 case 单跑就稳定（不 flaky）
- verdict 稳定，只是 score ±1 微抖且不翻 PASS/FAIL

## Procedure

抖动有**两个独立来源，修法相反**，先分清再动手：

1. **重跑取样**：对 flaky case `--case <id>` 重跑 ≥3 次，收集每次的 pass/fail + score + **judge reasoning 全文**（reasoning 是辨别的唯一证据）。
2. **读 reasoning 辨来源**（关键判别）：
   - 多次 reasoning 在**描述同一个 agent 输出**却给不同分 → **judge 变异**。修法：**收紧 criteria 措辞**（MUST / MUST NOT、concrete checkable），压掉 judge 打飘的空间。
   - 多次 reasoning 在**描述不同的 agent 输出**（一次守边界、一次越界）→ **agent 变异**（judge 各自打分其实都对）。修法：**改 agent prompt**（强化触发目标行为的指令），**不是动 criteria**——criteria 没问题。
3. **gate 用 majority-of-3**：degradation-probe 这类边界 case 受 agent 非确定性影响，单跑 PASS/FAIL 不作数；判通过 / 回归取 3 次多数票。
4. **修后复验**：改完（criteria 或 prompt）重跑 ≥3 次确认收敛（如 ~50% → 3/3）。若动的是 agent prompt，**还要全量跑该 agent** 确认没在别的 case 上引入 over-refusal / 回归。

## Pitfalls

- **默认归因 criteria 是最常见的错**：verdict 抖第一反应"criteria 太松"，但很多时候是 agent 本身在边界飘——收紧 criteria 没用，得修 prompt。读 reasoning 是唯一可靠辨别法。
- **单跑当基准**：flaky probe 单次结果做 gating 会假阳 / 假阴，必须 majority。
- **想纯隔离 judge 变异**要对**固定的 agent 输出**重判多次；但实战中读 reasoning（描述同 / 异输出）已能定性，不必额外烧 token 做固定输出重判。

## Why This Skill Exists

实战 2026-06-30（colar-agents 层 4 eval）：senior-developer 的 degradation-probe `sd-no-architect-overreach` 同 prompt 重跑出 PASS(4) / FAIL(1) ~50% 翻转。第一反应想收紧 criteria，但读两次 judge reasoning 发现——PASS 那次描述 agent "把方案标 conditional default 并甩回 architect"，FAIL 那次描述 agent "confidently 定全套 topology"。**是 agent 输出本身在飘，judge 各自打分都对**。于是改 senior-developer prompt 加 scope-boundary 规则（而非动 criteria），probe 从 ~50% → 3/3 PASS，3 个实现 case 零回归。教训：verdict 抖先辨来源，别条件反射改 criteria。

## Related

- colar-agents `eval/README.md` + `CLAUDE.md` 的「变异来源辨析」段（项目内 eval gate 文档）
- `eval/run-eval.sh --case <id>` 单 case 重跑用于取样
- `eval/run-eval.sh --agent <name>` 全量跑用于改 prompt 后查回归