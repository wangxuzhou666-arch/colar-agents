# commands/ — 自定义 slash 命令真身（version-controlled）

这里是 Claude Code 自定义 slash 命令的**单一真相源**。`~/.claude/commands/*.md` 是软链回这里的真身，和 agent 的 master-symlink 部署模式一致（改这里即时生效，无需 sync）。

## 部署模式

```
commands/<name>.md            ← 真身（本 repo，version-controlled）
   ↑ symlink
~/.claude/commands/<name>.md   ← Claude Code 实际读取处（软链）
```

## 当前命令

| 命令 | 用途 |
|---|---|
| `capture-skill.md` | 层 3 procedural memory — 蒸馏可复用 procedure 成 SKILL.md（带写时 4-类查重） |
| `handoff.md` | 生成 session 交接文档 + 开场白 |
| `ship.md` | 任务收尾一键化（secret gate → diff → build → review → commit/push） |
| `vc模型.md` | 启动 VC 模型 Critic（私人创业 idea 评估，CONFIDENTIAL） |

## 新增命令

1. 写 `commands/<name>.md`（真身）
2. 软链部署：`ln -s "$PWD/commands/<name>.md" ~/.claude/commands/<name>.md`
3. commit 真身（软链本身不入库，是本地部署产物）
