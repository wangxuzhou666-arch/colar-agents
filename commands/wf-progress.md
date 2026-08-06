---
description: 看正在跑的 Workflow / subagent 编排的实时进度快照 — 从落盘 journal + agent jsonl 重建阶段进度 + 每个在飞 agent 的任务与当前动作。VSCode 扩展里 /workflows TUI 不可用时的替代。
argument-hint: "[wf id 子串 / 目录路径 / --list，可选；省略=自动挑最新活动那个]"
---

# /wf-progress — Workflow 进度快照

VSCode 扩展里 `/workflows` 那个自更新 TUI 画不出来(硬限制)。本命令改从落盘数据重建进度:
`~/.claude/projects/<proj>/<session>/subagents/workflows/wf_*/` 下的 `journal.jsonl`(started/result 事件)
+ 各 `agent-*.jsonl`(每个 subagent 的 prompt 与工具调用)。

**这是「快照式」实时**:调一次 = 打印当次进度。想更新就再调一次。要接近 live 就 `/loop 25s /wf-progress`(每次刷新都烧 token,记得手动停)。

## 执行

直接跑脚本,把参数透传:

```bash
python3 ~/Desktop/colar-agents/scripts/wf_progress.py "$ARGUMENTS"
```

- 无参 → 自动挑「末次写入最新」的 workflow。
- `<wf-id 子串>`(如 `bc4eaadf`)→ 定位那个。
- `<目录绝对路径>` → 直接看这个。
- `--list` → 列出所有 workflow,按活跃度排序(先看有哪些再钻)。

把脚本输出**原样呈现**给 Colar,然后按需补一句解读:
- 有 🟡 静默很久(>几十分钟)但仍算「在飞」的 agent → 提示可能卡住,问要不要 `TaskStop` 或深挖那个 agent 的 jsonl。
- 完成度 100% / 0 在飞 → 编排已结束,主流程该取回合成结果了。

## 边界

- 只读,不动任何编排状态。
- 只反映**已落盘**的事件;agent 刚起、尚未写第一条时会显示「思考中/首轮」。
- 依赖 `~/Desktop/colar-agents/scripts/wf_progress.py`(与现有 hook 体系同源,version-controlled)。
