#!/usr/bin/env python3
"""tool-error 行为审计 — 把 2026-07-09 那次人肉 147-session 审计固化成可重复脚本。

扫 ~/.claude/projects/*/*.jsonl 里 is_error 的 tool_result，按错误模式分类计数，
输出「模式 × 工具 × 项目」三视图 + 每类一条样例，供 /reflect Step 4 对照 SOUL
Tool-Call Discipline 节判断:新高频模式 → 提议新纪律;旧模式仍高频 → 纪律失效,升级 hook。

只读,不写任何文件。stdlib only。

用法:
  python3 tool_error_audit.py --days 30          # 默认近 30 天
  python3 tool_error_audit.py --days 7 --top 5   # 每类样例数
  python3 tool_error_audit.py --json             # 机器可读输出
"""
import argparse
import glob
import json
import os
import re
import sys
import time
from collections import Counter, defaultdict

PROJECTS_DIR = os.path.expanduser("~/.claude/projects")

# 分类规则:自上而下第一个命中生效。新模式浮现时在此加一行,别改老 key(报告跨期可比)。
PATTERNS = [
    ("input-validation",   re.compile(r"InputValidationError|input_validation|did not match|is not valid under|required property", re.I)),
    ("edit-before-read",   re.compile(r"edit_read_guard|read the file|has not been read|Read it first|必先.*Read", re.I)),
    ("file-not-found",     re.compile(r"ENOENT|no such file|does not exist|not found in file|找不到", re.I)),
    ("edit-string-miss",   re.compile(r"old_string|string to replace.*not found|not unique|multiple matches", re.I)),
    ("permission-denied",  re.compile(r"permission denied|not allowed|denied by|requires approval|EACCES|user (declined|rejected|doesn)", re.I)),
    ("timeout",            re.compile(r"timed? ?out|ETIMEDOUT|deadline", re.I)),
    ("interrupt",          re.compile(r"interrupted|aborted|cancell?ed", re.I)),
    ("network",            re.compile(r"ECONNREFUSED|ECONNRESET|fetch failed|network|getaddrinfo|502|503", re.I)),
    ("hook-block",         re.compile(r"hook.*(block|exit 2)|blocked by hook", re.I)),
    # 普通命令非零退出(grep 无命中/构建失败等工作流常态),单列以免淹没 other 真信号
    ("bash-exit-nonzero",  re.compile(r"^Exit code \d+")),
]
FALLBACK = "other"


def classify(text):
    for name, rx in PATTERNS:
        if rx.search(text):
            return name
    return FALLBACK


def iter_transcripts(days):
    cutoff = time.time() - days * 86400
    for p in glob.glob(os.path.join(PROJECTS_DIR, "*", "*.jsonl")):
        try:
            if os.path.getmtime(p) >= cutoff:
                yield p
        except OSError:
            continue


def audit(days, sample_cap):
    by_pattern = Counter()
    by_tool = defaultdict(Counter)      # pattern -> tool -> n
    by_project = defaultdict(Counter)   # pattern -> project -> n
    samples = defaultdict(list)         # pattern -> [(tool, excerpt)]
    sessions_scanned = 0
    errors_total = 0

    for path in iter_transcripts(days):
        project = os.path.basename(os.path.dirname(path))
        sessions_scanned += 1
        tool_names = {}  # tool_use_id -> tool name(错误归到发起它的工具上)
        try:
            fh = open(path, encoding="utf-8")
        except OSError:
            continue
        with fh:
            for line in fh:
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                content = (obj.get("message") or {}).get("content")
                if not isinstance(content, list):
                    continue
                for b in content:
                    if not isinstance(b, dict):
                        continue
                    if b.get("type") == "tool_use":
                        tool_names[b.get("id")] = b.get("name", "?")
                    elif b.get("type") == "tool_result" and b.get("is_error"):
                        raw = b.get("content")
                        if isinstance(raw, list):
                            text = " ".join(x.get("text", "") for x in raw if isinstance(x, dict))
                        else:
                            text = str(raw or "")
                        text = text.strip()
                        if not text:
                            continue
                        errors_total += 1
                        pat = classify(text)
                        tool = tool_names.get(b.get("tool_use_id"), "?")
                        by_pattern[pat] += 1
                        by_tool[pat][tool] += 1
                        by_project[pat][project] += 1
                        if len(samples[pat]) < sample_cap:
                            samples[pat].append((tool, re.sub(r"\s+", " ", text)[:160]))
    return {
        "days": days,
        "sessions_scanned": sessions_scanned,
        "errors_total": errors_total,
        "by_pattern": dict(by_pattern.most_common()),
        "by_tool": {p: dict(c.most_common(5)) for p, c in by_tool.items()},
        "by_project": {p: dict(c.most_common(5)) for p, c in by_project.items()},
        "samples": {p: s for p, s in samples.items()},
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=30)
    ap.add_argument("--top", type=int, default=3, help="每类样例条数")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    r = audit(a.days, a.top)
    if a.json:
        json.dump(r, sys.stdout, ensure_ascii=False, indent=2)
        print()
        return

    print(f"tool-error 审计: 近 {r['days']} 天 · {r['sessions_scanned']} 个 transcript · {r['errors_total']} 条错误\n")
    if not r["errors_total"]:
        print("窗口内无 tool error。")
        return
    for pat, n in r["by_pattern"].items():
        tools = " ".join(f"{t}×{c}" for t, c in r["by_tool"][pat].items())
        projs = " ".join(f"{p}×{c}" for p, c in r["by_project"][pat].items())
        print(f"■ {pat}: {n}")
        print(f"  工具: {tools}")
        print(f"  项目: {projs}")
        for tool, ex in r["samples"].get(pat, []):
            print(f"  例[{tool}]: {ex}")
        print()


if __name__ == "__main__":
    main()
