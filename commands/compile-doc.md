---
description: md→html(MathJax)→pdf 三产物 compile pipeline（SOUL Math 场景 A 的执行命令）— 输入含 LaTeX 公式的 .md（或先写好 md），产出 .md + .html + .pdf 三件套并 open pdf
argument-hint: "[<path/to/doc.md> 或 一句话描述要写的文档]"
---

# /compile-doc — 公式文档三件套编译

数学公式文档（cheatsheet / 作业 / 笔记 / 报告）**默认走三件套**：源 `.md` + 渲染 `.html`（MathJax）+ 打印 `.pdf`。只给 md = 违反 SOUL Math 场景 A。仅 Colar 明确说"只要 md"才跳过。

## Step 0 — 输入判定

- 参数是已有 `.md` → 直接进 Step 1。
- 参数是"要写的文档"描述 → 先写 md（**文件里公式用 LaTeX**：inline `$...$`，block `$$...$$`；这是场景 A，与 chat 回复的 Unicode 规则相反）。
- 输出目录 = md 同目录；新建文档且位置不确定 → 先问 Colar（SOUL 铁律：新建文件前确认路径）。

## Step 1 — md → html（MathJax + 中文字体 + 打印 CSS）

用 python3 + `markdown` 库（本机已装；`extensions=['tables','fenced_code']`）转 body，套 HTML 模板。模板三要素：

```html
<script>
MathJax = { tex: { inlineMath: [['$','$']], displayMath: [['$$','$$']] },
            svg: { fontCache: 'global' } };
</script>
<script src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-svg.js"></script>
<style>
  body { font-family: "Source Han Serif SC","Noto Serif CJK SC","Songti SC",serif;
         max-width: 800px; margin: 0 auto; padding: 24px; line-height: 1.6; }
  @page { size: A4; margin: 15mm; }
  @media print { h1,h2 { page-break-after: avoid; } pre,table,.MathJax { page-break-inside: avoid; } }
  pre,code { font-family: Menlo,monospace; } table { border-collapse: collapse; }
  th,td { border: 1px solid #999; padding: 4px 8px; }
</style>
```

⚠️ md 转 html 前保护 `$...$`/`$$...$$` 段落不被 markdown 解析器吃掉下划线/星号（先占位替换，转完还原）——公式变乱码九成是这个原因。

## Step 2 — html → pdf（headless 浏览器打印）

**本机（Mac）用 Chrome**（无 Edge；Windows 机器用 Edge 同参数，路径见 reference）：

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless --disable-gpu \
  --print-to-pdf="<abs>/doc.pdf" --no-pdf-header-footer \
  --virtual-time-budget=10000 "file://<abs>/doc.html"
```

- `--virtual-time-budget=10000`：给 MathJax JS 渲染留时间，**不带它公式必缺**。
- 全部用绝对路径；产物落在 md 同目录。

## Step 3 — 验收 + 交付

1. 三文件都存在且 pdf > 10KB（太小 = 渲染失败空页）。
2. `open <path>.pdf`（交付物自动打开，SOUL 规则；三件套只 open pdf，md/html 列路径即可）。
3. 失败排查顺序：html 在浏览器里公式对不对 → 不对是 Step 1（占位保护/语法）；对但 pdf 缺 → Step 2（virtual-time-budget 加大到 20000）。

## Pointer

- 平台路径 / 双机差异 / 历史 generator 脚本：`~/Desktop/colar-memory/reference_md_to_html_pipeline.md`。
  ⚠️ 该 reference 的 Mac 路径（penn 学期文件夹）2026-07-06 已核实失效，本命令的内联模板即当前 Mac 权威实现。
- 产品化封装同源仓：GitHub `wangxuzhou666-arch/ai-cheatsheet`。

---

**用户参数**：$ARGUMENTS
