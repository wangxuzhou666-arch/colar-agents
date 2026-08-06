#!/usr/bin/env bash
# PostToolUse(Write|Edit) guard —— 检测刚写入的文本文件是否混入 NUL 字节(0x00)。
#
# 背景:Write 工具的 \u00xx 转义求值坑会把字面 NUL 写进文件
#   (见 memory feedback_write_tool_unicode_escape_nul.md),文件表面正常,
#   下游 git / 编辑器 / 解析器把它当二进制,静默炸。写完立刻检出 → 让模型当场修。
#
# 机制:stdin JSON 取 tool_input.file_path;扩展名白名单内的文本文件扫 0x00,
#       命中 → exit 2 + stderr(反馈给模型);否则 exit 0。
# fail-open:stdin 解析异常 / 文件不存在 / 读失败 / 任何不确定 → exit 0,绝不阻断。
#       二进制文件按扩展名白名单跳过(只扫 .md .txt .json .js .ts .tsx .py .sh
#       .yaml .yml .toml .css .html),文件读取上限 20MB 兜性能底。

input=$(cat 2>/dev/null || true)
[ -z "$input" ] && exit 0

HOOK_INPUT="$input" python3 -c '
import json, os, sys

try:
    d = json.loads(os.environ.get("HOOK_INPUT", "{}"))
    fp = (d.get("tool_input") or {}).get("file_path", "")
except Exception:
    sys.exit(0)

if not fp or not os.path.isfile(fp):
    sys.exit(0)

# 只扫文本类扩展名(白名单);其余(图片/二进制/无扩展名)跳过
TEXT_EXTS = {".md", ".txt", ".json", ".js", ".ts", ".tsx", ".py", ".sh",
             ".yaml", ".yml", ".toml", ".css", ".html"}
if os.path.splitext(fp)[1].lower() not in TEXT_EXTS:
    sys.exit(0)

try:
    with open(fp, "rb") as fh:
        data = fh.read(20 * 1024 * 1024)  # 20MB 上限兜性能底
except Exception:
    sys.exit(0)

if b"\x00" in data:
    print("检测到写入文件含 NUL 控制字符（\\u00xx 求值坑，见 feedback_write_tool_unicode_escape_nul.md），"
          "立即用 python 重写该文件修复", file=sys.stderr)
    sys.exit(2)
sys.exit(0)
'
rc=$?

# 只透传"确定命中"的 exit 2;python 崩溃等其他非零码一律 fail-open
[ "$rc" -eq 2 ] && exit 2
exit 0
