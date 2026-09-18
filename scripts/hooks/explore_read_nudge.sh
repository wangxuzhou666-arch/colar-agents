#!/usr/bin/env bash
# UserPromptSubmit hook: 主 loop 连读一串文件却一个都没改 → 提示把这段探索派出去。
#
# 盯的是「context 为什么会膨胀」的因，不是「context 已经多大」的果。
# 纯 context 阈值会误报：session 起手基线就 55-70K，调研读三个大文件就 190K，
# 这时催 handoff 是纯亏——任务才刚开始，还没到可交接的状态。(2026-09-18 Colar 指出)
#
# 判据自带防误报：改文件必须先 Read（edit_read_guard 强制的），所以批量改文件是
# Read→Edit 反复配对，每次 Edit 重置计数，永不触发。只有「读了一堆一个没改」才累计。
#
# 2026-09-18 实测基线：主 loop 7 天 Read 2129 次，Agent 派发率 0.26%，
# >300K 的 session 吃掉 93.9% 成本。
set +e

THRESHOLD=${EXPLORE_READ_THRESHOLD:-6}
# 硬上限 500K（2026-09-18 Colar 定）：低阈值（200K）会在任务早期误报——起手基线就 55-70K，
# 调研读三个大文件即 190K，那时催 handoff 是纯亏。500K 不存在「才做了一点点」的情况，是真失控。
# 这是兜底，不是主手段：派发率上去了根本涨不到这里。实测最贵 session 峰值 718K。
CEILING=${CONTEXT_CEILING:-500000}
TAIL_BYTES=2000000   # 只读 transcript 尾部：整份可能几十 MB，hook 必须跑得完

INPUT=$(head -c 65536)
export HOOK_INPUT="$INPUT" HOOK_THRESHOLD="$THRESHOLD" HOOK_TAIL="$TAIL_BYTES" HOOK_CEILING="$CEILING"

python3 -c '
import os, sys, json

try:
    d = json.loads(os.environ.get("HOOK_INPUT", "{}"))
except json.JSONDecodeError:
    sys.exit(0)

# subagent 的 hook 收到的是父 session 的 transcript_path（edit_read_guard 2026-07-10 实证），
# 且 subagent 本来就该自己读文件——它读的内容用完即弃，不进主 loop context。
if d.get("agent_id"):
    sys.exit(0)

tp = d.get("transcript_path", "")
if not tp or not os.path.isfile(tp):
    sys.exit(0)

threshold = int(os.environ["HOOK_THRESHOLD"])
tail_bytes = int(os.environ["HOOK_TAIL"])

with open(tp, "rb") as f:
    f.seek(0, os.SEEK_END)
    f.seek(max(0, f.tell() - tail_bytes))
    tail = f.read().decode("utf-8", "replace")

lines = tail.split("\n")
reads, paths, ctx = 0, [], 0
counting = True   # 撞到写操作后停止数 reads，但还要继续往前找 context 水位

for line in reversed(lines):
    if "tool_use" not in line and "usage" not in line:
        continue
    try:
        rec = json.loads(line)
    except json.JSONDecodeError:
        continue          # 尾部第一行常被截断，跳过
    if rec.get("isSidechain"):
        continue
    msg = rec.get("message")
    if not isinstance(msg, dict):
        continue

    # 最近一条主 loop 消息的 usage 就是当前 context 水位
    if not ctx:
        u = msg.get("usage")
        if isinstance(u, dict):
            ctx = (u.get("cache_read_input_tokens", 0)
                   + u.get("cache_creation_input_tokens", 0)
                   + u.get("input_tokens", 0))

    if counting:
        for blk in reversed(msg.get("content") or []):
            if not isinstance(blk, dict) or blk.get("type") != "tool_use":
                continue
            name = blk.get("name")
            if name in ("Edit", "Write", "NotebookEdit"):
                counting = False
                break
            if name == "Read":
                reads += 1
                fp = (blk.get("input") or {}).get("file_path", "")
                if fp:
                    paths.append(os.path.basename(fp))

    if ctx and not counting:
        break

ceiling = int(os.environ["HOOK_CEILING"])
if ctx >= ceiling:
    print(f"[context-ceiling::hook-only] 当前 context {ctx/1000:.0f}K，已过硬上限 {ceiling//1000}K。"
          f"主 loop context 每轮全量重发，到这个水位每次工具调用都在重付 {ctx/1000:.0f}K —— "
          f"任务一到断点就 /handoff 换 session（或 /compact 就地压缩）。"
          f"这不是早期误报区间：起手基线才 55-70K。")

if reads >= threshold:
    sample = ", ".join(paths[:4])
    print(f"[explore-nudge::hook-only] 主 loop 已连读 {reads} 个文件未改任何东西（{sample}…）—— "
          f"这是探索性工作，内容会永久留在主 loop context 并在之后每一轮重付。"
          f"考虑把剩下的摸底派给 Explore/subagent，只要结论回来。"
          f"（判据见 feedback_fable_thin_orchestrator_model_routing：主 loop 不读大文件）")
' 2>/dev/null
exit 0
