#!/usr/bin/env python3
"""Memory recall audit — 把 Hermes pilot 的 attach-rate 方法论套到 memory 文件上。

目标: 找出"死重"memory —— 长期从不被真正引用/使用的文件,作为 prune 候选。
复用 ~/.claude/recall.db (Stop hook 增量灌的全 transcript FTS5 索引)。

核心信号设计 (mirror pilot_audit 的 trigger≠attach):
- surfaced(any) : slug 出现在任意消息 —— 含 MEMORY.md index dump 污染,信号脏
- used(asst)    : slug 出现在 *assistant* 消息 —— 我真的引用/用了它 = memory 版 "attach"
                  (MEMORY.md dump 在 user/system 侧, 不会进 assistant 输出, 天然排除)
- recall(inject): 该 session 出现 recall wrapper "This memory is" —— 注入证据(best-effort, 含 Read 噪声)

判读:
- used==0 且 age>30d           -> 强 prune 候选 (创建 1 个月没被用过一次)
- used==0 但 surfaced>0        -> 只在 index dump 里露脸, 没真正发挥作用
- used>0                       -> 在工作, 留

用法:
    python3 memory_audit.py                 # 全量, 90d 窗口
    python3 memory_audit.py --window 30d
    python3 memory_audit.py --dead-only     # 只列 prune 候选
    python3 memory_audit.py --sort used     # 按使用次数升序 (默认)
"""
import argparse, sqlite3, time, pathlib, re

DB = pathlib.Path.home() / ".claude/recall.db"
MEM_DIR = pathlib.Path.home() / ".claude/projects/-Users-colar-Desktop-colar-agents/memory"
NOW = int(time.time())

# 这些文件是 index / 模板 / 入口, 不参与 prune 评估
EXCLUDE = {"MEMORY.md", "_template.md"}


def fts_quote(s: str) -> str:
    """FTS5 phrase query: 双引号包起来当 phrase, 内部双引号转义。"""
    return '"' + s.replace('"', '""') + '"'


def dsess(conn, slug, since, role=None):
    """slug 出现的 distinct session 数, 可选限定 role。"""
    q = fts_quote(slug)
    if role:
        sql = ("SELECT COUNT(DISTINCT m.session_id) FROM msg_fts "
               "JOIN messages m ON msg_fts.rowid=m.rowid "
               "WHERE msg_fts MATCH ? AND m.ts>=? AND m.role=?")
        args = (q, since, role)
    else:
        sql = ("SELECT COUNT(DISTINCT m.session_id) FROM msg_fts "
               "JOIN messages m ON msg_fts.rowid=m.rowid "
               "WHERE msg_fts MATCH ? AND m.ts>=?")
        args = (q, since)
    try:
        return conn.execute(sql, args).fetchone()[0]
    except sqlite3.OperationalError:
        return -1


def file_age_days(p: pathlib.Path) -> int:
    return int((NOW - p.stat().st_mtime) / 86400)


def read_lifecycle(p: pathlib.Path) -> str:
    """读 frontmatter 的 lifecycle 字段。cold-storage = lookup-on-demand,
    used 信号对它系统性失效(查值用,不引用),永不 PRUNE。"""
    try:
        head = p.read_text(errors="ignore")[:600]
    except Exception:
        return ""
    m = re.search(r"^lifecycle:\s*(\S+)", head, re.MULTILINE)
    return m.group(1).strip() if m else ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--window", default="90d", help="时间窗 (default 90d)")
    ap.add_argument("--dead-only", action="store_true", help="只列 used==0 的 prune 候选")
    ap.add_argument("--sort", default="used", choices=["used", "surfaced", "name"])
    args = ap.parse_args()

    n = int(re.sub(r"\D", "", args.window))
    unit = args.window[-1]
    since = NOW - {"d": 86400, "h": 3600, "m": 60}[unit] * n

    if not DB.exists():
        print(f"recall.db 不存在: {DB} — 先跑 index.py"); return

    conn = sqlite3.connect(DB)
    files = sorted(p for p in MEM_DIR.glob("*.md") if p.name not in EXCLUDE)

    rows = []
    for p in files:
        slug = p.stem  # e.g. feedback_jtbd_lens
        used = dsess(conn, slug, since, role="assistant")
        surfaced = dsess(conn, slug, since)
        rows.append({"slug": slug, "used": used, "surfaced": surfaced,
                     "age": file_age_days(p), "lifecycle": read_lifecycle(p)})

    if args.sort == "used":
        rows.sort(key=lambda r: (r["used"], r["surfaced"]))
    elif args.sort == "surfaced":
        rows.sort(key=lambda r: r["surfaced"])
    else:
        rows.sort(key=lambda r: r["slug"])

    win_start = time.strftime("%F", time.localtime(since))
    print(f"\n=== Memory Recall Audit (window={args.window}, since={win_start}) ===")
    print(f"信号: used=slug 进 assistant 消息的 session 数 (真用了) | surfaced=任意消息(含 dump)\n")
    print(f"{'memory':<52}{'used':>6}{'surfaced':>10}{'age(d)':>8}  flag")
    print("-" * 90)

    dead = 0
    exempt = 0
    for r in rows:
        flag = ""
        cold = r["lifecycle"] == "cold-storage"
        if cold:
            exempt += 1
        if r["used"] == 0 and not cold:
            if r["surfaced"] == 0:
                flag = "💀 0-recall (从未出现)"
            else:
                flag = "⚠ dump-only (只在 index 露脸)"
            if r["age"] > 30:
                flag += " · age>30d → PRUNE"
                dead += 1
        elif cold and r["used"] == 0:
            flag = "❄ cold-storage (豁免, lookup-on-demand)"
        if args.dead_only and not (r["used"] == 0 and not cold):
            continue
        print(f"{r['slug']:<52}{r['used']:>6}{r['surfaced']:>10}{r['age']:>8}  {flag}")

    print("-" * 90)
    print(f"总 {len(rows)} 个 memory · {dead} 个 PRUNE 候选 (used==0 且 age>30d 且非 cold-storage) · {exempt} 个 cold-storage 豁免")
    print("\nKPI gate (mirror Hermes attach-rate):")
    print("  used==0 且 age>30d  → prune 候选, 人工复核后删 (复核: 是否 axiom 级该留)")
    print("  used==0 但 surfaced>0 → 改 description 让它更易被 recall, 或降级合并")
    print("  used>0              → 在工作, 留")
    print("\n注意: used 是 *引用* 信号不是 *recall* 信号。axiom 类(很少被显式引用但")
    print("      作为背景常驻有价值)需人工豁免 —— 别纯按数字删。")


if __name__ == "__main__":
    main()
