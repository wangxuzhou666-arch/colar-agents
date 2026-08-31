---
name: ui-design-emoji-discipline
description: "做 UI / 产品设计 / 文案 / CTA / 状态指示 / 按钮 / 错误提示时,默认禁用 emoji 和 pictographic 符号。SOUL \"no emoji\" 规则在视觉 affordance 场景最易被违反 — 本能上想加 ✨🚀📋 增加感知度,Colar 明确不要。Use when: writing React/Vue/Svelte JSX, CSS `::before content`, marketing copy, button labels, status badges, README, or any user-facing text."
version: 1.0.0
source: feedback_emoji_in_ui_design (migrated 2026-05-24；**该 memory 文件 2026-08-30 复核时两个 lane 均已不存在**，内容已全部升格进本文件，此行仅存溯源)
---

## When to Use

写任何**用户可见**的文案 / 标签 / 图标 / 状态指示前,**先 self-check** 这个字符是 typography 还是 pictograph。命中以下场景必跑 check:

- React/Vue/JSX 文案 (button label / heading / placeholder / error message)
- CSS `::before content:` / `::after content:`
- Marketing landing copy / hero text / feature list
- README.md 标题 prefix / warning prefix
- 按钮 / CTA / close button / 进度步骤
- 状态指示 (error / success / warning / info badge)

**例外**: Colar 自己用了 emoji 或显式说"加 emoji" → 跟随。

## Procedure

### Step 1: 字符分类自检

| 类型 | 例子 | 允许? |
|---|---|---|
| Typography arrows | → ← ↑ ↓ | ⚠️ 尽量避免,优先用 CSS |
| Typographic marks | × · — — | ✅ 允许 (close button 用 `×` U+00D7 而不是 emoji `✕` U+2715) |
| Pictographic emoji | ✨🚀🌐📋📎📄👁💡 | ❌ **禁用** |
| Emoji 符号 | U+1F300–U+1FAFF | ❌ **全禁** |
| Misc symbols | ✓✗⚠⚡🔥 (U+2600–U+27BF) | ❌ **大部分禁** (pictographic) |

### Step 2: 视觉 affordance 用 CSS 替代

| 想加 emoji 的本能场景 | 替代方案 |
|---|---|
| 主 CTA 按钮 ✨🚀 | 用强 background color + bold font,不加图标 |
| 错误前缀 ⚠ | `color: #d00; font-weight: 600;` + 文字 "错误:" |
| 成功前缀 ✓ | `color: #0a0;` + 文字 "完成" |
| 关闭按钮 ✕ | typographic `×` (U+00D7),或 CSS 画 `::before` 用 transform: rotate(45deg) line |
| 进度步骤 done | `background-color: #0a0; border-radius: 50%;` (CSS dot),不用字符 |
| PDF 缩略图 📄 | 文字 "PDF" 或纯 layout 框 |
| 提示前缀 💡 | "提示:" + 不同 color |

### Step 3: 批量清理 trick

```bash
# 一次性扫到所有违规位置(扩展任意发现的新 emoji)
grep -rn '[✨🚀🌐📋📎📄👁👀📍✓✗✕⚠⚡💡🔥🎯🆕🆗📌🔴🟡🟢💬🎉🎊]' src/ components/ app/
```

## Verification

写完任何 UI 文件后,在 commit / ship 前:

```bash
# verify zero pictographic emoji in user-facing code
git diff --cached | grep -E '[\x{1F300}-\x{1FAFF}\x{2600}-\x{27BF}]' && echo "❌ FOUND EMOJI, fix before commit" || echo "✅ clean"
```

> **2026-08-30 复核（90 天未动触发）**：上面这条命令**实测有效**，别照直觉判它坏。
> macOS BSD `grep -E` 确实解析 `\x{...}` codepoint 范围（一度被怀疑是 PCRE-only 语法，已证伪）。
> 判别力三分实测：纯中文「上线公告」(U+4E0A…) **放行** · 箭头 `→` (U+2192，在 2600-27BF 外) **放行** ·
> 🚀 (U+1F680，在 1F300-1FAFF 内) **报警**。即它不会对中文项目全量假阳性——这是它能用的前提。
> 本次复核同时确认：SOUL § Communication Style 的 "No emoji" 规则仍在（`soul/SOUL.md:41`），
> 本 skill 全部规则依然成立，无需修订。

## Pitfalls

- **`×` vs `✕`**: 看着像但是两个 codepoint。U+00D7 (`×`) 是 typographic math sign,allowed。U+2715 (`✕`) 是 emoji-rendered heavy multiplication,**禁用**。
- **`✓` 在 Mac Chrome 渲染成 emoji,在 iOS Safari 渲染成 typography**: 跨平台不一致,所以一律避免,用 CSS。
- **README.md / docs/** 也守同一条 — 之前 README 里 `⚠️ admin warning prefix` 都改成 `注意:`。
- **三方库(如 shadcn/ui icons)** 用 SVG 不在禁列内 — 允许 lucide-react / heroicons 等 SVG component icon。禁的是 unicode emoji 字符。

## Why This Skill Exists

2026-05-09 Colar 在 Yourpedia hosted 路径做完 M3 后明确说"所有 ai 生成的图标都帮我删掉吧"。M1 / M3 改造里违规加了 ~18 处 emoji,全部需要批量清理。

SOUL 已有"no emoji unless Colar uses them first",但 self-check 触发点不够 — 做 UI 设计时本能想加 visual affordance(✨🚀 表达"惊喜 / 上线感"),这条 skill 补 self-grill 触发列表。

## Related

- SOUL.md "Communication Style" § "No emoji"
- 触发 self-grill 的关键词: "设计 CTA" / "加状态指示" / "close button" / "按钮文案" / "成功提示" / "warning prefix" / "loading state"
