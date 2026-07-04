# Workflows — 真身目录（repo + symlink deploy）

Workflow 脚本的单一真相源。`~/.claude/workflows/*.js` 是软链回本目录，
和 commands/ 与 agent 的 master-symlink 部署模式一致（见 e4303ec）。

新增 workflow：文件写这里 → `ln -s "$(pwd)/workflows/<name>.js" ~/.claude/workflows/<name>.js`

- `expert-panel.js` — 多专家并发 fan-out + 证据门控 + 对抗验证 + 保留异见合成。
  args 契约见脚本头注释 + memory `feedback_expert_panel_args_contract.md`。
