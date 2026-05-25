-- colar-agents session recall database
-- 一个 .db 文件存所有跨 session transcript，FTS5 全文检索
-- 灌入: scripts/recall/index.py
-- 查询: scripts/recall/recall.py

PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;

CREATE TABLE IF NOT EXISTS sessions (
    id            TEXT PRIMARY KEY,           -- jsonl 文件 stem (session uuid)
    workspace     TEXT NOT NULL,              -- ~/.claude/projects/<encoded-path>
    started_at    INTEGER NOT NULL,           -- unix ts (first message)
    last_at       INTEGER NOT NULL,           -- unix ts (last message)
    msg_count     INTEGER DEFAULT 0,
    file_path     TEXT NOT NULL,              -- 原 jsonl 绝对路径
    file_mtime    INTEGER NOT NULL,           -- 检测改动用
    indexed_at    INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sessions_last_at ON sessions(last_at);
CREATE INDEX IF NOT EXISTS idx_sessions_workspace ON sessions(workspace);

CREATE TABLE IF NOT EXISTS messages (
    rowid         INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid          TEXT,                       -- 消息 uuid (jsonl 里有,跨 session 可能重复因 compact/resume)
    session_id    TEXT NOT NULL,
    ts            INTEGER,                    -- 消息 ts
    role          TEXT,                       -- user / assistant / system / tool
    tool          TEXT,                       -- Bash / Read / Edit / ... (若是 tool use)
    content       TEXT,                       -- 浓缩后的可读内容 (截至 8KB/条)
    FOREIGN KEY (session_id) REFERENCES sessions(id)
);

CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id);
CREATE INDEX IF NOT EXISTS idx_messages_ts ON messages(ts);

-- FTS5 全文索引 (external content 模式，省一份存储)
CREATE VIRTUAL TABLE IF NOT EXISTS msg_fts USING fts5(
    content,
    tool,
    role,
    session_id UNINDEXED,
    content='messages',
    content_rowid='rowid',
    tokenize='unicode61 remove_diacritics 2'
);

CREATE TRIGGER IF NOT EXISTS msg_ai AFTER INSERT ON messages BEGIN
    INSERT INTO msg_fts(rowid, content, tool, role, session_id)
    VALUES (new.rowid, new.content, new.tool, new.role, new.session_id);
END;

CREATE TRIGGER IF NOT EXISTS msg_ad AFTER DELETE ON messages BEGIN
    INSERT INTO msg_fts(msg_fts, rowid, content, tool, role, session_id)
    VALUES ('delete', old.rowid, old.content, old.tool, old.role, old.session_id);
END;

-- schema 版本 (Architect 提到的 schema drift 防护)
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
INSERT OR REPLACE INTO meta VALUES ('schema_version', '1');
INSERT OR REPLACE INTO meta VALUES ('jsonl_schema_fields_expected', 'uuid,timestamp,message,type');
