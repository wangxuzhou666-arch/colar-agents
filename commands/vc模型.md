---
description: 启动 VC 模型 Critic — 私人创业 idea 评估对话伙伴（CONFIDENTIAL 模式）
argument-hint: "[idea 描述] [--shadow=v0.7-draft]"
---

# /vc模型 — 启动 idea 评估对话

调用 **VC 模型 Critic** agent（`idea-vc-critic`），进入 CONFIDENTIAL 模式与 Colar 讨论一个创业 idea。

## 用法

- `/vc模型 我有个 idea：XXX` — 直接进入评估
- `/vc模型` — 不带 idea 时由 agent 主动询问
- `/vc模型 XXX --shadow=v0.7-draft` — 双跑 v0.6 stable + v0.7 draft 对比（升级阶段使用）

## Agent 启动行为

1. Read `~/Desktop/colar-memory/frameworks/vc-model/MANIFEST.md` → 取当前 active 版本
2. Read `spec/<current>.md` → 加载 framework
3. 显示 CONFIDENTIAL 横幅
4. 进 Phase 0 反 ritual 闸门 → Phase 1 Job 锚点 → Phase 2 五问 → Phase 3 R1 → Phase 4 verdict

## 保密硬约束（启动即激活）

- ❌ 禁用 WebSearch / WebFetch
- ❌ 禁止 commit 含 idea 内容的文件
- ✅ 对话产物仅落 `frameworks/vc-model/runs/`（gitignored）
- ✅ 调用其他 agent 时 redact idea 关键词

## Spec 实时更新

agent 不内嵌 framework 内容，每次启动从 MANIFEST → spec 实时读取。
升级 v0.6 → v0.7 时只需切 MANIFEST 一行 + 写 v0.7.md，agent 下次启动自动 fire 新版。

完整流程文档见 `~/Desktop/colar-memory/frameworks/vc-model/spec/<current>.md`。

---

请使用 `idea-vc-critic` agent 处理用户的请求：$ARGUMENTS