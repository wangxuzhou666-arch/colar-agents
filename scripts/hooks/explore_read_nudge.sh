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
# 2026-09-18 实测基线（0.26% 派发率 / 93.9% >300K 成本占比）已作废——
# orchestration_audit.py 口径修过一版（2026-09-19，见 eval/BASELINE.md），旧数字不可比。
#
# 25.7 小时观测下来这个 hook 零新增触发。埋点（本文件 2026-09-19 加）是为了区分两种
# 解释：①上游 SOUL 规则真让主 loop 一开局就 fan-out，根本没机会连读到阈值（这是好事）
# ②阈值定高了，主 loop 反复逼近却总差一点（这是该调参）。纯靠"触没触发"分不清这两种。
set +e

THRESHOLD=${EXPLORE_READ_THRESHOLD:-6}
# 硬上限 500K（2026-09-18 Colar 定）：低阈值（200K）会在任务早期误报——起手基线就 55-70K，
# 调研读三个大文件即 190K，那时催 handoff 是纯亏。500K 不存在「才做了一点点」的情况，是真失控。
# 这是兜底，不是主手段：派发率上去了根本涨不到这里。实测最贵 session 峰值 718K。
CEILING=${CONTEXT_CEILING:-500000}
TAIL_BYTES=2000000   # 只读 transcript 尾部：整份可能几十 MB，hook 必须跑得完
LOG_ENABLED=${EXPLORE_NUDGE_LOG:-1}   # 静默埋点开关，默认开；设 0 关闭（不影响 nudge/ceiling 主逻辑）

INPUT=$(head -c 65536)
export HOOK_INPUT="$INPUT" HOOK_THRESHOLD="$THRESHOLD" HOOK_TAIL="$TAIL_BYTES" \
       HOOK_CEILING="$CEILING" HOOK_LOG_ENABLED="$LOG_ENABLED"

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
reads, paths, ctx, agent_dispatches = 0, [], 0, 0
counting = True   # 撞到写操作后停止数 reads，但还要继续往前找 context 水位

for line in reversed(lines):
    if "tool_use" not in line and "usage" not in line:
        continue
    try:
        rec = json.loads(line)
    except json.JSONDecodeError:
        continue          # 尾部第一行常被截断，跳过
    if rec.get("isSidechain"):
        # 排除 subagent 内部消息——和 orchestration_audit.py 同一个口径：
        # 派发计数只认主 loop 自己发起的 Agent/Task，不认 subagent 嵌套再派发
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

    for blk in reversed(msg.get("content") or []):
        if not isinstance(blk, dict) or blk.get("type") != "tool_use":
            continue
        name = blk.get("name")
        # Agent/Task 派发计数与 reads 计数解耦：即便 reads 已被更晚的 Edit 打断
        # （counting=False），派发次数仍按"本次扫到的 tail 窗口"继续累计——这是
        # 埋点要的"本 session 迄今派发次数"字段，复用同一次扫描，不加第二次文件遍历。
        # 代价：一旦 tail 里已经出现过 Edit，下面的 `ctx and not counting: break`
        # 会让扫描提前收尾，此时更早的派发次数不会被数到——是有偏的下界，不是全量。
        if name in ("Agent", "Task"):
            agent_dispatches += 1
            continue
        if not counting:
            continue
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
ceiling_hit = ctx >= ceiling
if ceiling_hit:
    print(f"[context-ceiling::hook-only] 当前 context {ctx/1000:.0f}K，已过硬上限 {ceiling//1000}K。"
          f"主 loop context 每轮全量重发，到这个水位每次工具调用都在重付 {ctx/1000:.0f}K —— "
          f"任务一到断点就 /handoff 换 session（或 /compact 就地压缩）。"
          f"这不是早期误报区间：起手基线才 55-70K。")

# 去重：同一段连读会跨多轮 prompt 存在（没新 Read 也没 Edit 时计数不变），
# 不去重就每轮重复喊同一句 —— 噪音会让人开始无视所有 hook 提示，比没有 hook 更糟。
# 只在 reads 比上次提示时增加了才再喊；被 Edit 打断（reads 掉回阈值下）就清状态重新开始。
state = os.path.join(os.environ.get("TMPDIR", "/tmp"),
                     "claude-explore-nudge-" + os.path.basename(tp).replace(".jsonl", ""))
last = 0
if os.path.exists(state):
    try:
        last = int(open(state).read().strip())
    except (ValueError, OSError):
        last = 0

nudge_shown = False
if reads < threshold:
    if os.path.exists(state):
        os.remove(state)
elif reads > last:
    with open(state, "w") as f:
        f.write(str(reads))
    sample = ", ".join(paths[:4])
    print(f"[explore-nudge::hook-only] 主 loop 已连读 {reads} 个文件未改任何东西（{sample}…）—— "
          f"这是探索性工作，内容会永久留在主 loop context 并在之后每一轮重付。"
          f"考虑把剩下的摸底派给 Explore/subagent，只要结论回来。"
          f"（判据见 feedback_fable_thin_orchestrator_model_routing：主 loop 不读大文件）")
    nudge_shown = True

# --- 静默埋点（2026-09-19）---------------------------------------------
# 目的：现在只看得到"hook 触没触发"，看不到"主 loop 到底有没有接近过阈值"。
# 每次 hook 运行都落一行 JSONL，不管有没有真的喊话——否则永远分不清
# "从未接近阈值"和"反复接近但差一点"这两种解释（见文件头注释）。
#
# 三条硬约束，任何一条违反都是 bug：
#   1. 绝对静默——这段代码本身不能 print 任何东西到 stdout（UserPromptSubmit
#      hook 的 stdout 会被当作注入内容塞进每个 prompt 的 context）。
#   2. 绝对 fail-open——写日志的任何异常（目录不存在/磁盘满/权限/编码失败）
#      都不改变退出码、不产生 stderr 噪音、不影响上面已经跑完的 nudge 主逻辑。
#      这是这段 try/except Exception 大网捕获的唯一理由：写日志这个动作本身
#      对主流程而言必须"要么成功要么无声无息地失败"，具体是哪种 OSError 不重要。
#   3. 不重新扫描 transcript——下面用的 reads/ctx/agent_dispatches/paths 全部
#      复用上面同一次尾部扫描的结果，没有第二次文件遍历。
if os.environ.get("HOOK_LOG_ENABLED", "1") == "1":
    try:
        from datetime import datetime, timezone

        # 落点选 ~/.claude/state/，不选仓库目录（不进 git，不需要碰 .gitignore）、
        # 也不选 $TMPDIR（那是易失目录，reboot/重登会被系统清掉，埋点要跨天累积
        # 证据，选它会白白丢数据）。按天分文件 + 只保留最近 30 天，两条一起做到
        # "不会无限增长"：单日 UserPromptSubmit 次数是有限的（实测 251 条/天量级，
        # 一行 JSON 撑死几百字节，单日文件几十到一百多 KB），30 天滚动窗口封顶总量。
        log_dir = os.path.expanduser("~/.claude/state/explore-nudge")
        os.makedirs(log_dir, exist_ok=True)

        now = datetime.now(timezone.utc)
        session = os.path.basename(tp).replace(".jsonl", "")
        entry = {
            "ts": now.isoformat(timespec="seconds"),
            "session": session,
            "reads": reads,
            "ctx": ctx,
            "agent_dispatches": agent_dispatches,
            "emitted": bool(ceiling_hit or nudge_shown),
        }
        log_file = os.path.join(log_dir, now.strftime("%Y-%m-%d") + ".jsonl")
        with open(log_file, "a") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")

        # 保留最近 30 天，跑在每次成功写入之后——目录里文件数本就是"天数"量级，
        # 一次 listdir + 逐个 mtime 判断开销可忽略，不必再加定时任务之类的机制。
        cutoff_day = now.timestamp() - 30 * 86400
        for fn in os.listdir(log_dir):
            fp2 = os.path.join(log_dir, fn)
            if fn.endswith(".jsonl") and os.path.getmtime(fp2) < cutoff_day:
                os.remove(fp2)
    except Exception:
        # fail-open：埋点失败绝不能拖累 hook 本体（见上方约束 #2）。
        # 不 print、不 raise——静默吞掉，外层 2>/dev/null + exit 0 兜底。
        pass
' 2>/dev/null
exit 0
