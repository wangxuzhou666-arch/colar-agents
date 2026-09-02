#!/usr/bin/env bash
# compile_md.sh — md → html(MathJax) → pdf 三件套，SOUL Math 场景 A 的可执行实现。
#
# 为什么存在（2026-08-28）：/compile-doc 命令此前只有内联的 HTML 模板与命令行说明，
# 每次调用都要现写一遍 python 转换脚本 —— 同一件事的第 N 份实现，模板会各自漂。
# 这里固化成单一入口，命令与 workflow 收尾都调它。
#
# 用法：bash compile_md.sh <绝对路径.md> [--open]
# 产物：同目录下的 .html 与 .pdf。--open 时打开 pdf（三件套只 open pdf，SOUL 交付规则）。
set -euo pipefail

MD="${1:-}"
[ -n "$MD" ] || { echo "❌ 用法：bash compile_md.sh <绝对路径.md> [--open]"; exit 1; }
case "$MD" in /*) ;; *) echo "❌ 必须传绝对路径（SOUL 铁律：不赌 cwd）。收到：$MD"; exit 1 ;; esac
[ -f "$MD" ] || { echo "❌ 文件不存在：$MD"; exit 1; }

BASE="${MD%.md}"
HTML="${BASE}.html"
PDF="${BASE}.pdf"

python3 - "$MD" "$HTML" <<'PY'
import sys, re, pathlib
try:
    import markdown
except ImportError:
    sys.exit("❌ 缺 python markdown 库：pip3 install markdown")

src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = src.read_text(encoding='utf-8')

# 先把公式段抠出来占位 —— 否则 markdown 解析器会吃掉 LaTeX 里的下划线/星号，
# 渲染出来就是乱码。这是本 pipeline 历史上最高频的失败原因。
stash = []
def _keep(m):
    stash.append(m.group(0))
    return f"@@MATH{len(stash)-1}@@"
text = re.sub(r'\$\$.+?\$\$', _keep, text, flags=re.S)
text = re.sub(r'(?<!\$)\$[^\$\n]+?\$(?!\$)', _keep, text)

body = markdown.markdown(text, extensions=['tables', 'fenced_code'])
for i, s in enumerate(stash):
    body = body.replace(f"@@MATH{i}@@", s)

TPL = """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<title>%(title)s</title>
<script>
MathJax = { tex: { inlineMath: [['$','$']], displayMath: [['$$','$$']] },
            svg: { fontCache: 'global' } };
</script>
<script src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-svg.js"></script>
<style>
  body { font-family: "Source Han Serif SC","Noto Serif CJK SC","Songti SC",serif;
         max-width: 860px; margin: 0 auto; padding: 24px; line-height: 1.65; color:#1a1a1a; }
  @page { size: A4; margin: 14mm; }
  @media print { h1,h2,h3 { page-break-after: avoid; } pre,table,blockquote,.MathJax { page-break-inside: avoid; } }
  h1 { font-size: 1.75em; border-bottom: 2px solid #333; padding-bottom: .3em; }
  h2 { font-size: 1.35em; margin-top: 1.6em; border-bottom: 1px solid #ccc; padding-bottom: .2em; }
  h3 { font-size: 1.1em; margin-top: 1.3em; }
  pre,code { font-family: Menlo,monospace; font-size: .88em; }
  code { background:#f4f4f4; padding:1px 4px; border-radius:3px; }
  pre { background:#f7f7f7; padding:10px; border-radius:4px; overflow-x:auto; }
  pre code { background:none; padding:0; }
  table { border-collapse: collapse; width:100%%; margin: 1em 0; font-size:.92em; }
  th,td { border: 1px solid #999; padding: 6px 9px; vertical-align: top; }
  th { background:#eee; text-align:left; }
  blockquote { border-left: 4px solid #888; margin-left:0; padding: .4em 0 .4em 1em; color:#444; background:#fafafa; }
  hr { border:none; border-top:1px solid #ddd; margin:2em 0; }
  li { margin: .25em 0; }
</style></head><body>
%(body)s
</body></html>"""

title = next((l.lstrip('# ').strip() for l in text.splitlines() if l.startswith('# ')), src.stem)
out.write_text(TPL % {'title': title, 'body': body}, encoding='utf-8')
PY

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "❌ 找不到 Chrome：$CHROME"; exit 1; }

# --virtual-time-budget 给 MathJax 留渲染时间。不带它，公式必缺。
"$CHROME" --headless --disable-gpu \
  --print-to-pdf="$PDF" --no-pdf-header-footer \
  --virtual-time-budget=10000 "file://$HTML" >/dev/null 2>&1

# 验收：pdf < 10KB 基本等于渲染成空页，别当成功报出去。
SIZE=$(stat -f%z "$PDF" 2>/dev/null || echo 0)
if [ "$SIZE" -lt 10240 ]; then
  echo "❌ pdf 仅 ${SIZE} 字节，疑似空页。排查：先在浏览器开 $HTML 看渲染对不对；对但 pdf 缺 → 把 virtual-time-budget 加到 20000。"
  exit 1
fi

echo "✅ $HTML"
echo "✅ $PDF (${SIZE} 字节)"
[ "${2:-}" = "--open" ] && open "$PDF"
exit 0
