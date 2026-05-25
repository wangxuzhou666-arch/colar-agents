#!/usr/bin/env bash
# Stop hook: session 结束后增量索引到 ~/.claude/recall.db
#
# 设计要点:
#   - 只索引刚结束的 session (从 stdin JSON 拿 session_id 或 transcript_path)
#   - 失败静默 (不阻塞 Claude Code Stop)
#   - Python 内置 alarm 当 timeout 兜底 (macOS 无 timeout 命令)
#   - 单 Python invocation (省 ~50ms 启动)
#   - 通过环境变量传 SID/SCRIPT,避免 shell injection 进 Python literal

set +e
INPUT=$(head -c 65536)
export SCRIPT="$HOME/Desktop/agency-agents/scripts/recall/index.py"

[ -f "$SCRIPT" ] || exit 0

INPUT="$INPUT" python3 -c '
import os, sys, json, signal, subprocess
signal.signal(signal.SIGALRM, lambda *a: sys.exit(0))
signal.alarm(5)
try:
    d = json.loads(os.environ.get("INPUT", "{}"))
except Exception:
    sys.exit(0)
tp = d.get("transcript_path", "")
if not tp: sys.exit(0)
sid = os.path.basename(tp).removesuffix(".jsonl")
if not sid: sys.exit(0)
subprocess.run(["python3", os.environ["SCRIPT"], "--session", sid],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
' 2>/dev/null
exit 0
