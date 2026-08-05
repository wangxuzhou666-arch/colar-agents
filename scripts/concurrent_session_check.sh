#!/usr/bin/env bash
# 并发 claude session 检测 — 判断某个 repo 上「是否真有活跃的并发 claude session」，
# 并把「活跃 claude session」和「僵尸 dev server」区分开。
#
# 背景（为什么存在）：
#   实战中出现过「脏树雪球」——session 误判「以为有活跃并发 session
#   所以不敢 commit」，但实际那些 next/uvicorn 进程是挂了很多天的僵尸，根本没有活跃并发。
#   误判 → 无限 defer → 脏树累积。本脚本掐断这个放大器：用可信信号回答「现在到底有没有
#   别的 claude session 可能在这个 repo 上干活」，并诚实标注置信度（宁可报「疑似」也不误报
#   「确定无并发」）。
#
# 用法：
#   bash concurrent_session_check.sh [REPO_PATH]        # 人读报告（默认 REPO=当前 git 树）
#   bash concurrent_session_check.sh --brief [REPO]     # 只输出机器可解析的 VERDICT= 行（供 hook 消费）
#   REPO=<path> ACTIVE_WINDOW_MIN=20 ZOMBIE_HOURS=6 bash concurrent_session_check.sh
#
# 输出契约：
#   第一行永远是 `VERDICT=<CONCURRENT|AMBIGUOUS|NONE> conf=<high|low|none>`，供 B hook grep。
#   --brief 模式只打这一行。完整模式再打人读的 detail + dev server 诊断。
#   Exit：永远 0（advisory，绝不 block）。
#
# 检测原理（可信度来源）：
#   ~/.claude/sessions/<PID>.json 是每个「运行中 claude session」的注册表，含 pid / sessionId
#   / cwd / kind。PID 与 ps 里的真进程对应。判活用 kill -0 <pid>（注册文件可能残留=stale）。
#   自我排除用 $CLAUDE_CODE_SESSION_ID / $CLAUDE_PID（hook 继承本 session 的 env）。
#
#   置信度分层（诚实标注，不假装 100% 检测）：
#     CONCURRENT (high)  — 存在另一个活的 session，其 cwd 就在 repo 内（或有人工 override 标记）
#     AMBIGUOUS  (low)   — 存在另一个活的 session，cwd 是 repo 的祖先目录（如裸 home /Users/colar）
#                          → 它「可能」在用绝对路径改本 repo，无法排除，保守报「疑似并发」
#     NONE       (none)  — 除自己外没有活的 session，或其余活 session 都在明确无关的 repo cwd
#                          → 无并发证据（caveat：跨 repo 绝对路径操作理论上仍可能，先验极低）
#
# 局限：见文件尾 "LIMITATIONS"。平台：macOS（ps -o etime / BSD 语法）。

set -u

# 默认取当前 cwd 所在的 git 树根，不硬编码具体项目路径（本脚本对所有 repo 通用）
REPO_DEFAULT="$(git rev-parse --show-toplevel 2>/dev/null)"
BRIEF=0
ARG_REPO=""
for a in "$@"; do
  case "$a" in
    --brief) BRIEF=1 ;;
    *) ARG_REPO="$a" ;;
  esac
done

export REPO="${ARG_REPO:-${REPO:-$REPO_DEFAULT}}"
export BRIEF
export SELF_SID="${CLAUDE_CODE_SESSION_ID:-}"
export SELF_PID="${CLAUDE_PID:-}"
export ACTIVE_WINDOW_MIN="${ACTIVE_WINDOW_MIN:-20}"   # 注册文件 mtime 在此分钟内算「近期活跃」
export ZOMBIE_HOURS="${ZOMBIE_HOURS:-6}"              # dev server etime 超过此小时数 → 标僵尸候选
export SESSIONS_DIR="${SESSIONS_DIR:-$HOME/.claude/sessions}"

command -v python3 >/dev/null 2>&1 || { echo "VERDICT=NONE conf=none"; echo "(python3 不可用 — 检测跳过，fail-open)"; exit 0; }

# dev server 进程快照（cmdline 含 repo 路径 = 归属确定；uvicorn/next/vite 关键字 = 候选）
# 传给 python 做 etime 解析。ps 一次采集，避免多次 spawn。
PS_SNAPSHOT="$(ps -Ao pid=,etime=,command= 2>/dev/null | grep -iE 'next dev|next-server|uvicorn|vite|node .*\.bin/next' | grep -v grep || true)"
export PS_SNAPSHOT

python3 <<'PYEOF' || { echo "VERDICT=NONE conf=none"; echo "(检测内部异常 — fail-open)"; exit 0; }
import os, sys, json, glob, time, re

repo = os.path.realpath(os.environ["REPO"])
brief = os.environ.get("BRIEF", "0") == "1"
self_sid = os.environ.get("SELF_SID", "")
self_pid = os.environ.get("SELF_PID", "")
try:
    self_pid = int(self_pid) if self_pid else None
except ValueError:
    self_pid = None
window = int(os.environ.get("ACTIVE_WINDOW_MIN", "20")) * 60
zombie_h = float(os.environ.get("ZOMBIE_HOURS", "6"))
sessions_dir = os.environ["SESSIONS_DIR"]
now = time.time()

def alive(pid):
    """PID 是否为活进程。ProcessLookupError=死；PermissionError=活但非本人（仍算活）。"""
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except Exception:
        return False

def classify_cwd(cwd):
    if not cwd:
        return "UNRELATED"
    c = os.path.realpath(cwd)
    if c == repo or c.startswith(repo + os.sep):
        return "ON_REPO"          # session 就在 repo 内
    if repo.startswith(c + os.sep):
        return "ANCESTOR"         # cwd 是 repo 祖先（如裸 home）→ 可能用绝对路径够到 repo
    return "UNRELATED"            # 明确无关的 repo

# --- 枚举运行中 claude session 注册表 ---
on_repo, ancestor_recent, ancestor_idle, unrelated = [], [], [], []
for f in sorted(glob.glob(os.path.join(sessions_dir, "*.json"))):
    try:
        with open(f, encoding="utf-8") as fh:
            d = json.load(fh)
    except Exception:
        continue
    pid = d.get("pid")
    sid = d.get("sessionId", "")
    cwd = d.get("cwd", "")
    kind = d.get("kind", "?")
    name = d.get("name", "?")
    if not isinstance(pid, int):
        continue
    # 自我排除
    if (sid and sid == self_sid) or (self_pid and pid == self_pid):
        continue
    if not alive(pid):
        continue  # 注册文件残留但进程已死 → 跳过（stale）
    try:
        mtime = os.stat(f).st_mtime
    except OSError:
        mtime = 0
    recent = (now - mtime) <= window
    age_min = int((now - mtime) / 60)
    rec = {"pid": pid, "sid": sid[:8], "cwd": cwd, "kind": kind, "name": name,
           "recent": recent, "age_min": age_min}
    cls = classify_cwd(cwd)
    if cls == "ON_REPO":
        on_repo.append(rec)
    elif cls == "ANCESTOR":
        (ancestor_recent if recent else ancestor_idle).append(rec)
    else:
        unrelated.append(rec)

# --- 人工 override marker ---
override = os.path.join(repo, ".claude", "CONCURRENT_OVERRIDE")
has_override = os.path.isfile(override)

# --- 裁决 ---
if has_override:
    verdict, conf, reason = "CONCURRENT", "high", "人工 override marker 存在（.claude/CONCURRENT_OVERRIDE）"
elif on_repo:
    verdict, conf, reason = "CONCURRENT", "high", "另有活 session 的 cwd 就在 repo 内"
elif ancestor_recent:
    verdict, conf, reason = "AMBIGUOUS", "low", "另有活 session 在 repo 祖先目录（如裸 home）近期活跃，可能用绝对路径改本 repo，无法排除"
elif ancestor_idle:
    verdict, conf, reason = "AMBIGUOUS", "low", "另有活 session 在 repo 祖先目录但已空闲，仍可能恢复后改本 repo，保守不判 NONE"
else:
    verdict, conf, reason = "NONE", "none", "除自己外无活 session 在本 repo 或其祖先目录"

print("VERDICT=%s conf=%s" % (verdict, conf))
if brief:
    sys.exit(0)

# --- 完整人读报告 ---
print()
print("并发 session 检测 — repo: %s" % repo)
print("裁决: %s (置信度 %s)" % (verdict, conf))
print("依据: %s" % reason)
print()

def dump(title, rows):
    if not rows:
        return
    print(title)
    for r in rows:
        age = "刚活跃" if r["recent"] else ("%dmin 前" % r["age_min"])
        print("  pid=%-6s sid=%s kind=%-11s name=%-9s cwd=%s  [%s]"
              % (r["pid"], r["sid"], r["kind"], r["name"], r["cwd"], age))
    print()

dump("● ON_REPO（cwd 在 repo 内 — 强并发证据）:", on_repo)
dump("● ANCESTOR 近期活跃（cwd 是 repo 祖先，疑似并发）:", ancestor_recent)
dump("● ANCESTOR 空闲（cwd 是 repo 祖先，已空闲）:", ancestor_idle)
dump("○ UNRELATED（cwd 在无关 repo — 不计入本 repo，仅列出）:", unrelated)

if not (on_repo or ancestor_recent or ancestor_idle or unrelated):
    print("（除自己外没有其它活的 claude session）")
    print()

# --- dev server 僵尸诊断（关键：这些不是并发证据）---
def etime_to_hours(et):
    # 格式 [[dd-]hh:]mm:ss
    et = et.strip()
    days = 0
    if "-" in et:
        dpart, et = et.split("-", 1)
        days = int(dpart)
    parts = [int(x) for x in et.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0)
    h, m, s = parts[-3], parts[-2], parts[-1]
    return days * 24 + h + m / 60.0 + s / 3600.0

snap = os.environ.get("PS_SNAPSHOT", "")
servers = []
for line in snap.splitlines():
    line = line.strip()
    if not line:
        continue
    m = re.match(r"^(\d+)\s+(\S+)\s+(.*)$", line)
    if not m:
        continue
    pid, et, cmd = m.group(1), m.group(2), m.group(3)
    try:
        hours = etime_to_hours(et)
    except Exception:
        hours = 0.0
    on_this_repo = repo in cmd
    servers.append((int(pid), hours, et, on_this_repo, cmd))

if servers:
    print("dev server 诊断（提醒：dev server ≠ 活跃 claude session，别拿它当并发证据）:")
    for pid, hours, et, on_this_repo, cmd in sorted(servers, key=lambda x: -x[1]):
        tag = "本repo" if on_this_repo else "其它/未知cwd"
        zombie = " ⚠️僵尸候选(>%.0fh且无对应活跃并发)" % zombie_h if (hours >= zombie_h and verdict != "CONCURRENT") else ""
        short = cmd if len(cmd) <= 90 else cmd[:87] + "..."
        print("  pid=%-6s etime=%-11s [%s]%s" % (pid, et, tag, zombie))
        print("        %s" % short)
    print()
    print("  注: 僵尸候选 = 挂起时长 > %.0fh 且当前无「活跃并发 claude session」——" % zombie_h)
    print("      它只是没被回收的 dev server 进程，不构成「有人在并发改这个 repo」的理由。")

sys.exit(0)
PYEOF
exit 0
