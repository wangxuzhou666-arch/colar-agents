#!/usr/bin/env python3
"""
gen-agent-index.py — Auto-generate agents/INDEX.md from filesystem truth.

Scans colar-agents/*/*.md for agent files (identified by valid YAML frontmatter
with `name:` field), groups by division (parent directory), and writes
agents/INDEX.md with one table per division.

Usage:
    python3 scripts/gen-agent-index.py

Replaces hand-maintained INDEX.md. Run after adding/removing agents.

Frontmatter keys read:
    name        — display name (required, else file is skipped)
    description — column "Specialty" (first 80 chars)
    emoji       — prefix on agent link
    vibe        — column "When to Use" (else fallback to description tail)
"""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent

# Divisions to scan, in display order. Excludes: scripts, soul, cheatsheets,
# agents (output target), examples, integrations, 创业项目 (not agents).
DIVISIONS = [
    ("engineering", "Engineering"),
    ("design", "Design"),
    ("paid-media", "Paid Media"),
    ("sales", "Sales"),
    ("marketing", "Marketing"),
    ("product", "Product"),
    ("project-management", "Project Management"),
    ("testing", "Testing"),
    ("support", "Support"),
    ("spatial-computing", "Spatial Computing"),
    ("specialized", "Specialized"),
    ("game-development", "Game Development"),
    ("academic", "Academic"),
]

FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---", re.DOTALL)


def parse_frontmatter(text):
    m = FRONTMATTER_RE.search(text)
    if not m:
        return None
    body = m.group(1)
    out = {}
    for line in body.splitlines():
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        k = k.strip()
        v = v.strip().strip('"').strip("'")
        if k:
            out[k] = v
    return out if "name" in out else None


def truncate(s, n):
    s = s.strip()
    if len(s) <= n:
        return s
    return s[: n - 1].rstrip() + "…"


def main():
    out_path = ROOT / "agents" / "INDEX.md"
    out_path.parent.mkdir(exist_ok=True)

    lines = [
        "# Agent Index",
        "",
        "> **Auto-generated** by `scripts/gen-agent-index.py`. Do not hand-edit — re-run the script after adding/removing agents.",
        "",
        "底层 agent 池按 division 分类。Claude Code 按任务自动选 1-5 个组合调用,不需要手动从下面这张表里挑。",
        "",
        "> 命名风格 (Whimsy Injector / Rapid Prototyper / Reality Checker 等) 沿用上游 [msitarzewski/agency-agents](https://github.com/msitarzewski/agency-agents)。",
        "",
    ]

    # TOC
    toc = []
    sections = []
    total = 0

    for slug, title in DIVISIONS:
        div_dir = ROOT / slug
        if not div_dir.is_dir():
            continue
        agents = []
        for md in sorted(div_dir.glob("*.md")):
            text = md.read_text(encoding="utf-8")
            fm = parse_frontmatter(text)
            if not fm:
                continue
            agents.append((md, fm))
        if not agents:
            continue
        anchor = title.lower().replace(" ", "-")
        toc.append(f"[{title}](#{anchor})")
        section = [f"## {title}", "", "| Agent | Specialty | When to Use |", "|-------|-----------|-------------|"]
        for md, fm in agents:
            name = fm.get("name", md.stem)
            emoji = fm.get("emoji", "")
            desc = truncate(fm.get("description", ""), 90)
            vibe = truncate(fm.get("vibe", "") or fm.get("description", ""), 90)
            link = f"../{slug}/{md.name}"
            agent_cell = f"{emoji} [{name}]({link})".strip()
            section.append(f"| {agent_cell} | {desc} | {vibe} |")
        section.append("")
        sections.append("\n".join(section))
        total += len(agents)

    lines.append("跳转: " + " · ".join(toc))
    lines.append("")
    lines.append("---")
    lines.append("")
    lines.extend(sections)
    lines.append("---")
    lines.append("")
    lines.append(f"_Total: {total} agents across {len(toc)} divisions. Generated from filesystem — single source of truth is the .md files themselves._")
    lines.append("")

    out_path.write_text("\n".join(lines), encoding="utf-8")
    print(f"Wrote {out_path} — {total} agents across {len(toc)} divisions")


if __name__ == "__main__":
    sys.exit(main())
