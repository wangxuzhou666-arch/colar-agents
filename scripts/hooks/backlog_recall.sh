#!/usr/bin/env bash
# SessionStart hook: 把 BACKLOG.md 里当前 project 的未完成任务注入开场 context
#
# 设计要点:
#   - 从 stdin JSON 拿 cwd(SessionStart 也传 cwd)
#   - 只注入当前 project 段的 open 项 + 其他 project 的 open 计数(一行摘要)
#   - stdout 会被 Claude Code 当 context 注入
#   - 无 open 项 → 静默(不输出)
set +e
INPUT=$(head -c 65536)
export BACKLOG="$HOME/Desktop/colar-memory/BACKLOG.md"
export HOOK_INPUT="$INPUT"

[ -f "$BACKLOG" ] || exit 0

python3 -c '
import os, sys, json, signal, re, subprocess
signal.signal(signal.SIGALRM, lambda *a: sys.exit(0))
signal.alarm(6)

try:
    d = json.loads(os.environ.get("HOOK_INPUT", "{}"))
except Exception:
    d = {}
cwd = d.get("cwd", "") or os.getcwd()
cwd_norm = cwd.rstrip("/")
cwd_name = os.path.basename(cwd_norm) or cwd_norm

# 先 pull colar-memory 再读,解 SessionStart 时序竞态(git-pull hook 是 async,recall 不能读它 pull 前的旧 BACKLOG)。
# 慢/离线/失败 → 读本地,不阻塞开场。
try:
    subprocess.run(["git", "-C", os.path.expanduser("~/Desktop/colar-memory"), "pull", "--quiet"],
                   timeout=3, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
except Exception:
    pass

try:
    with open(os.environ["BACKLOG"], encoding="utf-8") as fh:
        text = fh.read()
except Exception:
    sys.exit(0)

# 解析所有 project 段
secs = re.findall(r"<!-- project:(.*?) -->(.*?)<!-- /project -->", text, re.DOTALL)
if not secs:
    sys.exit(0)

cur_items = []
other = []  # (name, count)
for path, body in secs:
    items = [ln.strip() for ln in body.splitlines() if ln.strip().startswith("- [ ]")]
    if not items:
        continue
    name = os.path.basename(path.rstrip("/")) or path
    if path.strip().rstrip("/") == cwd_norm:
        cur_items = items
    else:
        other.append((name, len(items)))

if not cur_items and not other:
    sys.exit(0)

out = ["[backlog::hook-only] 跨 session 未完成任务(来自 BACKLOG.md,可能已过时,开工前快速核一眼):"]
if cur_items:
    out.append("■ 当前 project (" + cwd_name + "):")
    out.extend("  " + it for it in cur_items)
    out.append("  → 开工前把上面这些 rebuild 进 TodoWrite;否则本 session 结束落盘以最后一次 TodoWrite 为准,会覆盖掉未 load 的项")
else:
    out.append("■ 当前 project (" + cwd_name + "): 无 open 项")
if other:
    summary = " · ".join(n + ":" + str(c) for n, c in other)
    out.append("■ 其他 project open 计数: " + summary)
print("\n".join(out))
' 2>/dev/null
exit 0
