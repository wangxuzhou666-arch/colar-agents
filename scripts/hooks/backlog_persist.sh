#!/usr/bin/env bash
# Stop hook: session 结束时把 TodoWrite 里未完成的项落盘到 BACKLOG.md
#
# 设计要点:
#   - 从 stdin JSON 拿 transcript_path + cwd(和 recall_index.sh 同约定)
#   - 扫 transcript 里最后一次 TodoWrite 调用 → 取 status != completed 的项
#   - 按 cwd 分段 reconcile 进 BACKLOG.md(HTML comment anchor 定界,可重写)
#   - session 没用 TodoWrite → 不动 BACKLOG(避免快 session 误清空标准 backlog)
#   - open 项为 0 → 移除该 project 段(任务做完 = 自动清理)
#   - 写成功/失败都写 sidecar log(~/.claude/backlog_persist.log) + BACKLOG footer 状态戳,
#     不再让 os.replace 失败被 except+2>/dev/null 双吞成假成功;signal.alarm 兜底 timeout
set +e
INPUT=$(head -c 262144)
export BACKLOG="$HOME/Desktop/colar-memory/BACKLOG.md"
export PLOG="$HOME/.claude/backlog_persist.log"
export HOOK_INPUT="$INPUT"

python3 -c '
import os, sys, json, signal, re, datetime
signal.signal(signal.SIGALRM, lambda *a: sys.exit(0))
signal.alarm(8)

def _plog(status, detail):
    try:
        with open(os.environ.get("PLOG", os.path.expanduser("~/.claude/backlog_persist.log")), "a", encoding="utf-8") as lf:
            lf.write(datetime.datetime.now().isoformat(timespec="seconds") + " " + status + " " + detail + "\n")
    except Exception:
        pass

try:
    d = json.loads(os.environ.get("HOOK_INPUT", "{}"))
except Exception:
    sys.exit(0)

tp  = d.get("transcript_path", "")
cwd = (d.get("cwd", "") or os.getcwd()).rstrip("/")   # 归一化一次,anchor/name/regex 全用它,避免口径不一累积重复段
if not tp or not os.path.isfile(tp):
    sys.exit(0)

# --- 扫 transcript 最后一次 TodoWrite ---
last = None
sid  = os.path.basename(tp).removesuffix(".jsonl")
try:
    with open(tp, encoding="utf-8") as fh:
        for line in fh:
            try:
                obj = json.loads(line)
            except Exception:
                continue
            msg = obj.get("message", {})
            content = msg.get("content")
            if not isinstance(content, list):
                continue
            for b in content:
                if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "TodoWrite":
                    todos = (b.get("input") or {}).get("todos")
                    if isinstance(todos, list):
                        last = todos
except Exception:
    sys.exit(0)

# 本 session 没用 TodoWrite → 不碰 backlog
if last is None:
    sys.exit(0)

open_items = [t for t in last if isinstance(t, dict) and t.get("status") in ("pending", "in_progress")]

name  = os.path.basename(cwd) or cwd
today = datetime.date.today().isoformat()
sid8  = sid[:8]

def render_section():
    lines = [f"<!-- project:{cwd} -->",
             f"## {name}",
             f"`{cwd}`",
             f"_updated: {today} · session {sid8}_",
             ""]
    for t in open_items:
        c = (t.get("content") or "").strip().replace("\n", " ")
        suffix = " _(in progress)_" if t.get("status") == "in_progress" else ""
        lines.append(f"- [ ] {c}{suffix}")
    lines.append("<!-- /project -->")
    return "\n".join(lines)

HEADER = """# BACKLOG — 跨 session 持久任务队列

> 自动维护:Stop hook 落盘每 session 结束时 TodoWrite 里未完成(pending/in_progress)的项;
> SessionStart hook 注入当前 project 的 open 项。按 cwd 分段,可手动编辑。
> 完成的任务下次同 project session 结束时自动移除。这是 live tracker,不是 memory 文件。
"""

backlog = os.environ["BACKLOG"]
try:
    with open(backlog, encoding="utf-8") as fh:
        text = fh.read()
except FileNotFoundError:
    text = HEADER

if not text.strip().startswith("# BACKLOG"):
    text = HEADER + "\n" + text

# 删掉本 project 已有段(anchor 之间,含尾随空行)
pat = re.compile(r"\n*<!-- project:" + re.escape(cwd) + r" -->.*?<!-- /project -->\n*", re.DOTALL)
text = pat.sub("\n", text)

# 去掉旧 footer(避免每次累积)
text = re.sub(r"\n*<!-- last-persist:.*?-->\n*", "\n", text)

# 有 open 项才追加新段
if open_items:
    text = text.rstrip() + "\n\n" + render_section() + "\n"
else:
    text = text.rstrip() + "\n"

# footer 状态戳:证明 persist 真跑过 + 何时(配 sidecar log 让静默失败可见)
now = datetime.datetime.now().isoformat(timespec="seconds")
text = text.rstrip() + "\n\n<!-- last-persist: " + now + " -->\n"

tmp = backlog + ".tmp"
try:
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, backlog)
    _plog("OK", "cwd=" + cwd + " open=" + str(len(open_items)))
except Exception as e:
    _plog("FAIL", "cwd=" + cwd + " err=" + repr(e))
    sys.exit(0)
' 2>/dev/null
exit 0
