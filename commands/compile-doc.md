---
description: md→html(MathJax)→pdf 三产物 compile pipeline（SOUL Math 场景 A 的执行命令）— 输入含 LaTeX 公式的 .md（或先写好 md），产出 .md + .html + .pdf 三件套并 open pdf
argument-hint: "[<path/to/doc.md> 或 一句话描述要写的文档]"
---

# /compile-doc — 公式文档三件套编译

数学公式文档（cheatsheet / 作业 / 笔记 / 报告）**默认走三件套**：源 `.md` + 渲染 `.html`（MathJax）+ 打印 `.pdf`。只给 md = 违反 SOUL Math 场景 A。仅 Colar 明确说"只要 md"才跳过。

## Step 0 — 输入判定（这一步是你的活，脚本不管）

- 参数是已有 `.md` → 直接进 Step 1。
- 参数是"要写的文档"描述 → 先写 md（**文件里公式用 LaTeX**：inline `$...$`，block `$$...$$`；这是场景 A，与 chat 回复的 Unicode 规则相反）。
- 输出目录 = md 同目录；新建文档且位置不确定 → 先问 Colar（SOUL 铁律：新建文件前确认路径）。

## Step 1 — 跑编译（一条命令，md→html→pdf 全含）

```bash
bash ~/Desktop/colar-agents/scripts/compile_md.sh <绝对路径.md> --open
```

- 脚本内含：MathJax 模板 + 中文字体 + 打印 CSS + 公式段占位保护 + Chrome headless 打印 + 空页验收。
- `--open` 打开 pdf（三件套只 open pdf，md/html 列路径即可，SOUL 交付规则）。不想自动打开就省掉它。
- 参数必须是**绝对路径**，脚本会拒绝相对路径（SOUL 铁律：不赌 cwd）。

## Step 2 — 失败排查

脚本会自己报错并给排查方向。人工介入顺序：

1. `缺 python markdown 库` → `pip3 install markdown`
2. `pdf 仅 N 字节，疑似空页` → 先在浏览器打开生成的 `.html` 看渲染对不对
   - 公式乱码 → 源 md 的 LaTeX 语法问题（脚本的占位保护只防解析器吃字符，防不了写错的公式）
   - html 正常但 pdf 空 → 把脚本里的 `--virtual-time-budget` 从 10000 加到 20000
3. `找不到 Chrome` → 换机器了（Windows 用 Edge 同参数，见下方 Pointer）

## 权威实现

**`~/Desktop/colar-agents/scripts/compile_md.sh` 是本 pipeline 的唯一实现**（2026-08-28 收敛）。

此前本命令内联 HTML 模板 + 命令行说明，每次调用都要现写一遍 python 转换脚本 —— 同一件事的第 N 份实现，模板各自漂。要改样式/字体/打印参数，**改脚本，不要在这里再写一份模板**。

调用方（都指向同一个脚本，不各自实现）：
- 本命令 `/compile-doc`
- `workflows/expert-panel.js` 的 panel 收尾（meta.whenToUse 里写死了这条命令）

## Pointer

- 平台路径 / 双机差异 / 历史 generator 脚本：`~/Desktop/colar-memory/reference_md_to_html_pipeline.md`。
  ⚠️ 该 reference 的 Mac 路径（penn 学期文件夹）2026-07-06 已核实失效；2026-08-28 起权威实现是上面那个脚本，不再是本文件的内联模板。
- 产品化封装同源仓：GitHub `wangxuzhou666-arch/ai-cheatsheet`。

---

**用户参数**：$ARGUMENTS
