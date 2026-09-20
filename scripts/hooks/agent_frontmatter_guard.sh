#!/usr/bin/env bash
# PreToolUse(Write|Edit|MultiEdit) 机械坑硬拦 —— agent 配置 frontmatter 里的行内 # 注释。
#
# 要拦的坑（2026-09-20 实测）：
#   agent .md 的 YAML frontmatter 里写 `model: sonnet  # 为什么这么配`，
#   整行连注释一起被当成 model ID 发给 API → model_not_found / HTTP 404，agent 直接起不来。
#   错误信息里 `model sent to the API:` 那行会原样回显整个带注释的字符串。
#   症状有迷惑性：报的是 404 model_not_found，第一反应会怀疑模型权限或模型名过期，
#   不看 `model sent to the API` 根本想不到是配置解析问题。
#   实测受害面 5 个文件（engineering-explore / idea-vc-critic / engineering-agent-infra /
#   engineering-senior-developer / engineering-frontend-developer），全是 2026-09-18、09-20
#   两次「显式钉死 model」时埋的，已手工修完（注释一律另起一行）。
#
# 为什么必须是机械层而不是文本层：
#   这条完全落在 SOUL 的机械判据上（每次都成立 · 与任务无关 · 零歧义）。
#   更关键的是文本层对它【结构性无效】：出错的动作本身就是「写注释解释为什么这么配」，
#   在 model: 旁边再写一句「别写行内注释」，下次钉 model 时还是会顺手写在同一行 ——
#   这个 bug 就是注释自己把自己搞坏的。
#   代价也比一般配置错误高：agent 定义只在 session 启动时载入、改文件不热重载，
#   中招后当前 session 无法自愈，必须重启 —— 所以「事后发现再修」这条路特别贵。
#
# 机制：exit 2 + stderr（同 edit_read_guard.sh / nul_byte_guard.sh 的姿势，
#       PreToolUse 下 exit 2 阻断调用并把 stderr 回灌给模型，让它当场改写重发）。
#
# 判定口径（三道收窄，任何一道不满足即放行）：
#   1. 路径必须落在 ~/Desktop/colar-agents/**/*.md 或 ~/.claude/agents/**/*.md（含 realpath）；
#   2. 只扫 frontmatter 区 —— 且【必须以第 1 行的 --- 开头】。不能用「首个 --- 到次个 ---」，
#      因为库里 78 个 .md 有 43 个根本没有 frontmatter，正文里的 --- 分隔线会被误当开界符
#      （CONTRIBUTING.md 与 integrations/opencode/README.md 正文就各有一处 color: "#hexcode"）；
#   3. 字段白名单 model|name|tools|color|emoji|description，且值后的 # 必须是【真注释】。
#
# 「真注释」= 引号感知：# 只有在【不在引号内】且【前一个字符是空白】且【它前面有非空值】时才算。
#   这条引号感知不是洁癖，是硬需求 —— specialized/idea-vc-critic.md:4 写的就是
#   `color: "#7C3AED"`，色值的 # 在引号内，误拦它会把合法配置打回。
#   反过来 `model: "sonnet" # 注释` 这种「值有引号、注释在引号外」的必须照拦，
#   所以不能用「先无脑剥掉引号片段再找 #」的写法（那会把它漏掉）。
#   概念版正则是 ^(model|name|tools|color|emoji|description):\s*\S.*\s+# ，
#   下面的扫描器是它的引号感知精确版。
#
# 覆盖面：Write 用 tool_input.content 直接扫；Edit/MultiEdit 先读盘上原文、套用替换后再扫
#   （只看 new_string 判不出它落不落在 frontmatter 区）。
#
# fail-open：stdin 解析异常 / 路径不在范围 / 文件读不到 / old_string 对不上 /
#   没有合法 frontmatter / 任何不确定 → exit 0 放行，绝不因 guard 自身出错阻断工具。
#
# 自证测试：bash scripts/hooks/tests/test_agent_frontmatter_guard.sh
#   —— 真阳性（必拦）与真阴性（必放行，含色值、正文 # 标题、非 agent 路径）各有用例。改规则先跑它。

input=$(cat 2>/dev/null || true)
[ -z "$input" ] && exit 0

HOOK_INPUT="$input" python3 -c '
import json, os, re, sys

FIELD_RE = re.compile(r"^(model|name|tools|color|emoji|description):(.*)$")
ROOTS = (os.path.expanduser("~/Desktop/colar-agents"),
         os.path.expanduser("~/.claude/agents"))


def in_scope(path):
    """路径必须是 agent 配置目录下的 .md。软链也算（realpath 一并判）。"""
    if not path or not path.endswith(".md"):
        return False
    cands = {os.path.abspath(path)}
    try:
        cands.add(os.path.realpath(path))
    except Exception:
        pass
    for c in cands:
        for r in ROOTS:
            if c == r or c.startswith(r + os.sep):
                return True
    return False


def frontmatter_lines(content):
    """返回 [(行号, 行文本)]，只含 frontmatter 内部行。
    必须以第 1 行的 --- 开界；找不到闭合界符则判为无合法 frontmatter（放行）。"""
    lines = content.splitlines()
    if not lines or lines[0].lstrip("﻿").strip() != "---":
        return []
    for i in range(1, min(len(lines), 300)):
        if lines[i].strip() in ("---", "..."):
            # 第 1 行是开界符，所以正文行号从 2 起
            return list(enumerate(lines[1:i], start=2))
    return []


def inline_comment_pos(rest):
    """在字段值部分里找真正起注释作用的 # 的下标；没有则 -1。
    同 YAML 口径：# 不在引号内、且前一个字符是空白，才是注释。"""
    in_s = in_d = False
    for i, ch in enumerate(rest):
        if ch == "\x27" and not in_d:
            in_s = not in_s
        elif ch == "\x22" and not in_s:
            in_d = not in_d
        elif ch == "#" and not in_s and not in_d:
            if i > 0 and rest[i - 1].isspace():
                return i
    return -1


def apply_edits(content, edits):
    """把 Edit/MultiEdit 的替换套到原文上；任何对不上一律 None（放行）。"""
    for e in edits:
        old = e.get("old_string")
        new = e.get("new_string")
        if old is None or new is None or old == "":
            return None
        if old not in content:
            return None  # Edit 工具自己会报错，不归本 guard 管
        if e.get("replace_all"):
            content = content.replace(old, new)
        else:
            content = content.replace(old, new, 1)
    return content


try:
    d = json.loads(os.environ.get("HOOK_INPUT", "{}"))
    tool = d.get("tool_name") or ""
    ti = d.get("tool_input") or {}
    fp = ti.get("file_path") or ""
except Exception:
    sys.exit(0)

if not in_scope(fp):
    sys.exit(0)

if tool == "Write":
    content = ti.get("content")
    if not isinstance(content, str):
        sys.exit(0)
elif tool in ("Edit", "MultiEdit"):
    try:
        with open(fp, "r", encoding="utf-8") as fh:
            content = fh.read()
    except Exception:
        sys.exit(0)
    edits = ti.get("edits") if tool == "MultiEdit" else [ti]
    if not isinstance(edits, list) or not edits:
        sys.exit(0)
    content = apply_edits(content, edits)
    if content is None:
        sys.exit(0)
else:
    sys.exit(0)

hits = []
for lineno, line in frontmatter_lines(content):
    m = FIELD_RE.match(line)
    if not m:
        continue
    field, rest = m.group(1), m.group(2)
    p = inline_comment_pos(rest)
    # 注释前必须有非空值（对应概念正则里的 \S）：整行只有注释的不算本坑
    if p > 0 and rest[:p].strip():
        hits.append((lineno, field, line.strip()))

if not hits:
    sys.exit(0)

out = sys.stderr
first_field = hits[0][1]
print("agent-frontmatter-guard：frontmatter 里有字段的值后面跟了行内 # 注释 —— 本次写入已拦截。", file=out)
for lineno, field, text in hits:
    print("  第 %d 行 `%s:` → %s" % (lineno, field, text), file=out)
print("为什么会炸：Claude Code 解析 agent frontmatter 不剥行内注释，整行连注释一起被当成字段值。", file=out)
print("  model 字段中招 → API 报 model_not_found / HTTP 404，agent 直接起不来（2026-09-20 实测 5 个文件）。", file=out)
print("  且 agent 定义只在 session 启动时载入、改文件不热重载 —— 中招后当前 session 无法自愈，必须重启。", file=out)
print("正确写法：注释另起一行 ——", file=out)
print("  %s: <值>" % first_field, file=out)
print("  # 你的注释写这里", file=out)
print("（引号内的 # 不算注释，color: \x22#7C3AED\x22 这类色值本 guard 会放行。）", file=out)
sys.exit(2)
'
rc=$?

# 只透传"确定命中"的 exit 2；python 崩溃等其他非零码一律 fail-open
[ "$rc" -eq 2 ] && exit 2
exit 0
