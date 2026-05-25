#!/usr/bin/env python3
"""colar-agents recall indexer.

灌入 ~/.claude/projects/**/*.jsonl 到 ~/.claude/recall.db
- 增量: 只读 mtime 比 sessions.file_mtime 新的 jsonl
- 单 session 强一致: 先 DELETE session 旧记录,再批量 INSERT
- 提取策略: text/tool_use/tool_result 浓缩为可读 content, thinking 跳过

用法:
    python index.py                 # 全量增量
    python index.py --session ID    # 单 session (Stop hook 用)
    python index.py --rebuild       # 删 DB 重建
    python index.py --stats         # 看现状
"""
import argparse, json, pathlib, sqlite3, sys, time
from datetime import datetime
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from redact import redact_secrets, is_dangerous_bash

DB_PATH = pathlib.Path.home() / ".claude/recall.db"
PROJECTS_ROOT = pathlib.Path.home() / ".claude/projects"
SCHEMA_PATH = pathlib.Path(__file__).parent / "schema.sql"
CONTENT_MAX = 8000  # 单条消息 content 上限 (FTS5 性能 + 防 OOM)


def parse_ts(s: str) -> int:
    if not s: return 0
    try: return int(datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp())
    except: return 0


def render_content(content) -> tuple[str, str]:
    """从 message.content (str | list) 提取 (rendered_text, primary_tool).

    入库前 redaction: secret pattern 全文替换 + 危险 Bash command 的 tool_result 整条 skip.
    """
    if isinstance(content, str):
        return redact_secrets(content)[:CONTENT_MAX], ""
    if not isinstance(content, list):
        return "", ""
    parts, tool, danger_cmd = [], "", False
    for item in content:
        if not isinstance(item, dict): continue
        t = item.get("type")
        if t == "text":
            parts.append(item.get("text", ""))
        elif t == "tool_use":
            name = item.get("name", "")
            tool = tool or name
            inp = item.get("input", {})
            # 把 tool input 关键字段拍平 (command / file_path / pattern 等)
            key_summary = " ".join(
                f"{k}={str(v)[:200]}" for k, v in inp.items()
                if k in ("command", "file_path", "pattern", "url", "query", "description", "old_string", "new_string")
            )
            parts.append(f"[tool:{name}] {key_summary}")
            # 标记: 这个 tool_use 的 command 是危险的 (下一条 tool_result 整条 skip)
            if name == "Bash" and is_dangerous_bash(inp.get("command", "")):
                danger_cmd = True
        elif t == "tool_result":
            if danger_cmd:
                parts.append("[SKIPPED_DANGEROUS_TOOL_RESULT]")
                danger_cmd = False
                continue
            c = item.get("content", "")
            if isinstance(c, list):
                c = " ".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
            elif isinstance(c, dict):
                c = json.dumps(c, ensure_ascii=False)[:1500]
            err = " [ERROR]" if item.get("is_error") else ""
            parts.append(f"[result{err}] {str(c)[:1500]}")
        # thinking 不入索引 (Colar 内部推理,不该被检索)
    rendered = "\n".join(p for p in parts if p)
    # 兜底: 即使 tool 路径没标 danger,通用 secret pattern 再过一遍
    rendered = redact_secrets(rendered)
    return rendered[:CONTENT_MAX], tool


def index_jsonl(conn, jl_path: pathlib.Path, force: bool = False) -> tuple[int, bool]:
    """返回 (新增消息数, 是否处理)。"""
    sid = jl_path.stem
    mtime = int(jl_path.stat().st_mtime)
    # workspace = 第一层 project 目录 (扁平化 subagents 子目录到主 project)
    try:
        rel = jl_path.relative_to(PROJECTS_ROOT)
        workspace = rel.parts[0]
    except ValueError:
        workspace = jl_path.parent.name

    cur = conn.cursor()
    row = cur.execute("SELECT file_mtime FROM sessions WHERE id=?", (sid,)).fetchone()
    if row and not force and row[0] >= mtime:
        return 0, False  # 没改动,跳过

    # 单 session 重建: 串行化 (防并发 Stop hook race condition)
    # Python sqlite3 默认 isolation_level='' 自动开 DEFERRED tx; commit 后手动 BEGIN IMMEDIATE 升锁
    conn.commit()
    cur.execute("BEGIN IMMEDIATE")
    cur.execute("DELETE FROM messages WHERE session_id=?", (sid,))
    cur.execute("DELETE FROM sessions WHERE id=?", (sid,))

    msgs = []
    first_ts, last_ts = 0, 0
    try:
        for line in jl_path.read_text(errors="ignore").splitlines():
            try: m = json.loads(line)
            except: continue
            t = m.get("type")
            if t not in ("user", "assistant"): continue
            msg = m.get("message", {})
            if not isinstance(msg, dict): continue
            content, tool = render_content(msg.get("content", ""))
            if not content: continue
            ts = parse_ts(m.get("timestamp", ""))
            uuid = m.get("uuid") or f"{sid}:{ts}:{len(msgs)}"
            msgs.append((uuid, sid, ts, msg.get("role", t), tool, content))
            if first_ts == 0 or (ts and ts < first_ts): first_ts = ts
            if ts > last_ts: last_ts = ts
    except Exception as e:
        print(f"  ! parse error {jl_path.name}: {e}", file=sys.stderr)
        return 0, False

    if not msgs: return 0, False
    cur.execute(
        "INSERT INTO sessions VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (sid, workspace, first_ts or mtime, last_ts or mtime, len(msgs),
         str(jl_path), mtime, int(time.time()))
    )
    cur.executemany(
        "INSERT INTO messages (uuid, session_id, ts, role, tool, content) VALUES (?,?,?,?,?,?)",
        msgs
    )
    return len(msgs), True


def cmd_full(conn, rebuild=False):
    if rebuild:
        # 直接物理删 db 是最干净的 — FTS5 有 5 个 shadow table (msg_fts / _data / _idx / _docsize / _config)
        # 单 DROP 不会清,残留会让重建 schema 冲突。
        conn.close()
        DB_PATH.unlink(missing_ok=True)
        for ext in ("-wal", "-shm"):
            (DB_PATH.parent / (DB_PATH.name + ext)).unlink(missing_ok=True)
        conn = sqlite3.connect(DB_PATH)
        conn.executescript(SCHEMA_PATH.read_text())
        # 重建后立刻 chmod 600 (新文件 mode 受 umask 影响)
        DB_PATH.chmod(0o600)
    start = time.time()
    total_msgs, processed = 0, 0
    files = list(PROJECTS_ROOT.glob("**/*.jsonl"))
    for i, jl in enumerate(files):
        if i % 50 == 0:
            print(f"  [{i}/{len(files)}] {processed} sessions, {total_msgs} msgs, {time.time()-start:.1f}s")
        n, did = index_jsonl(conn, jl, force=rebuild)
        total_msgs += n
        if did: processed += 1
    conn.commit()
    print(f"\nIndexed {processed} new/changed sessions, {total_msgs} messages, {time.time()-start:.1f}s")


def cmd_session(conn, sid):
    matches = list(PROJECTS_ROOT.glob(f"*/{sid}.jsonl"))
    if not matches:
        print(f"session {sid} not found", file=sys.stderr); sys.exit(1)
    n, _ = index_jsonl(conn, matches[0], force=True)
    conn.commit()
    print(f"Indexed session {sid}: {n} messages")


def cmd_stats(conn):
    s = conn.execute("SELECT COUNT(*), SUM(msg_count) FROM sessions").fetchone()
    m = conn.execute("SELECT COUNT(*) FROM messages").fetchone()
    db_size = DB_PATH.stat().st_size if DB_PATH.exists() else 0
    print(f"Sessions: {s[0]}  Messages (per sessions): {s[1]}  (per messages table): {m[0]}")
    print(f"DB size: {db_size/1024/1024:.1f} MB")
    top_tools = conn.execute("SELECT tool, COUNT(*) FROM messages WHERE tool!='' GROUP BY tool ORDER BY 2 DESC LIMIT 5").fetchall()
    print(f"Top tools: {top_tools}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--session", help="Index single session by id")
    ap.add_argument("--rebuild", action="store_true", help="Drop and rebuild")
    ap.add_argument("--stats", action="store_true")
    args = ap.parse_args()

    if not DB_PATH.exists():
        print(f"DB not found, creating from schema at {DB_PATH}")
        DB_PATH.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(DB_PATH)
        conn.executescript(SCHEMA_PATH.read_text())
    else:
        conn = sqlite3.connect(DB_PATH)

    if args.stats: cmd_stats(conn)
    elif args.session: cmd_session(conn, args.session)
    else: cmd_full(conn, rebuild=args.rebuild)


if __name__ == "__main__":
    main()
