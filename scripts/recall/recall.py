#!/usr/bin/env python3
"""colar-agents recall CLI -- 跨 session 全文检索.

用法:
    recall "nextjs HMR chunks 404"           # 基础检索
    recall "schema drift" --since 60d         # 时间窗
    recall "GEPA" --tool WebSearch            # 限定 tool
    recall "kitchen" --workspace kitchen      # 限定 workspace 子串
    recall "memory" --limit 20 --snippet 300  # 调展示
    recall --session abc12345                 # 看单 session 全文

设计哲学:
    - 默认输出可读 (Colar 在 terminal 看), 不做 prompt-friendly format
    - --json 模式给 LLM 消费 (后续 /recall slash 用)
    - 不自动 LLM summarize (那是下个迭代的事, 先看 FTS5 召回质量)
"""
import argparse, json, pathlib, re, sqlite3, sys, time
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from redact import redact_full

DB_PATH = pathlib.Path.home() / ".claude/recall.db"
DEFAULT_LIMIT = 10
DEFAULT_SNIPPET = 200


def parse_since(s: str) -> int:
    """'7d' / '24h' / '30m' -> unix ts cutoff."""
    if not s: return 0
    m = re.match(r"(\d+)([dhm])", s)
    if not m: return 0
    n, unit = int(m.group(1)), m.group(2)
    return int(time.time()) - n * {"d": 86400, "h": 3600, "m": 60}[unit]


def fmt_age(ts: int) -> str:
    if not ts: return "?"
    age = int(time.time()) - ts
    if age < 3600: return f"{age//60}m"
    if age < 86400: return f"{age//3600}h"
    return f"{age//86400}d"


def _escape_fts5_query(q: str) -> str:
    """FTS5 query 语法保护:
    - `-` / `*` / `:` / `"` 在 FTS5 是操作符,plain text query 必须 quote
    - 简单策略: 若 query 含特殊字符且无 FTS5 operator 意图,整体 phrase quote
    - 若 query 已有引号 (用户主动 phrase / boolean),原样传
    """
    if '"' in q or any(op in q for op in (" AND ", " OR ", " NOT ")):
        return q  # 用户自己写了 FTS5 expression
    if any(c in q for c in "-*:^"):
        # 转义内嵌双引号,然后整体 phrase
        return '"' + q.replace('"', '""') + '"'
    return q


def search(conn, query, limit, since, tool, workspace, snippet_len):
    fts_q = _escape_fts5_query(query)
    where, params = ["msg_fts MATCH ?"], [fts_q]
    if since:
        where.append("m.ts >= ?"); params.append(since)
    if tool:
        where.append("m.tool = ?"); params.append(tool)
    if workspace:
        where.append("s.workspace LIKE ?"); params.append(f"%{workspace}%")

    sql = f"""
    SELECT
        m.session_id, m.ts, m.role, m.tool, m.content,
        s.workspace, s.file_path,
        snippet(msg_fts, 0, '⟦', '⟧', '…', {snippet_len // 8}) AS snip,
        bm25(msg_fts) AS score
    FROM msg_fts
    JOIN messages m ON msg_fts.rowid = m.rowid
    JOIN sessions s ON m.session_id = s.id
    WHERE {' AND '.join(where)}
    ORDER BY score
    LIMIT ?
    """
    params.append(limit)
    return conn.execute(sql, params).fetchall()


def view_session(conn, sid, redact=True):
    rows = conn.execute(
        "SELECT ts, role, tool, content FROM messages WHERE session_id LIKE ? ORDER BY ts",
        (f"{sid}%",)
    ).fetchall()
    if not rows:
        print(f"session {sid} not found", file=sys.stderr); sys.exit(1)
    for ts, role, tool, content in rows:
        tag = f"[{tool}]" if tool else f"[{role}]"
        print(f"\n{tag} {time.strftime('%F %T', time.localtime(ts)) if ts else '?'}")
        body = content[:1500]
        if redact: body = redact_full(body, include_pii=True)
        print(body)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("query", nargs="?", help="FTS5 query")
    ap.add_argument("--since", help="Time window, e.g. 7d / 24h / 30m")
    ap.add_argument("--tool", help="Filter by tool name (Bash/Read/Edit/...)")
    ap.add_argument("--workspace", help="Substring match on workspace path")
    ap.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
    ap.add_argument("--snippet", type=int, default=DEFAULT_SNIPPET)
    ap.add_argument("--session", help="View full single session by id prefix")
    ap.add_argument("--json", action="store_true", help="JSON output for LLM consumption")
    ap.add_argument("--unsafe", action="store_true",
                    help="Disable PII/secret redaction (default: redact). Use only when alone at desk, not on Zoom/screen-share.")
    args = ap.parse_args()

    if not DB_PATH.exists():
        print(f"DB not found at {DB_PATH}. Run: python index.py", file=sys.stderr); sys.exit(2)

    conn = sqlite3.connect(DB_PATH)

    if args.session:
        view_session(conn, args.session, redact=not args.unsafe); return

    if not args.query:
        ap.print_help(); sys.exit(1)

    since = parse_since(args.since) if args.since else 0
    rows = search(conn, args.query, args.limit, since, args.tool, args.workspace, args.snippet)

    redact_output = not args.unsafe

    if args.json:
        out = [{
            "session_id": r[0], "ts": r[1], "role": r[2], "tool": r[3],
            "workspace": r[5],
            "snippet": redact_full(r[7], include_pii=True) if redact_output else r[7],
            "score": r[8], "file": r[6],
        } for r in rows]
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return

    if not rows:
        print("(no hits)"); return

    print(f"\n=== {len(rows)} hits for: {args.query!r}  (redact={'on' if redact_output else 'OFF — unsafe'}) ===\n")
    for sid, ts, role, tool, content, ws, fp, snip, score in rows:
        ws_short = ws.replace("-Users-colar-Desktop-", "").replace("-Users-colar-", "")[:30]
        tag = f"[{tool}]" if tool else f"[{role}]"
        snip_out = redact_full(snip, include_pii=True) if redact_output else snip
        print(f"  {fmt_age(ts):>4} ago  {tag:<14} {ws_short:<32}  sid={sid[:8]}  score={score:.1f}")
        print(f"    {snip_out[:args.snippet]}")
        print()


if __name__ == "__main__":
    main()
