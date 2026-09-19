#!/usr/bin/env python3
"""编排行为度量 — 回答「主 loop 到底有没有把活派出去」。

cc-usage-bar 按 model 分组算钱，但看不见两个决定成本的维度：
活是主 loop 自己干的还是派给 subagent 的，以及单个 session 的 context 涨到了多少。

2026-09-19 修过一版口径（per-record timestamp 窗口过滤 + 派发率分子分母同限主 loop
+ 补齐 Task 别名）——历史读数与本版不可直接比较，新旧对照见 eval/BASELINE.md。

用法: python3 scripts/orchestration_audit.py [天数]
"""
import json, os, sys, glob
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone

PRICING_FILE = os.path.expanduser("~/Desktop/cc-usage-bar/config.json")
# clear + resume 要重付 session 基线(~60K) 加 handoff 正文(~20K)。
# context 超过这个数，继续拖着的每轮开销就压过了重开一轮的成本。
CTX_WARN, CTX_CRIT = 200_000, 300_000


def load_pricing():
    """复用 cc-usage-bar 的价目表，避免两处数字各说各话。"""
    with open(PRICING_FILE) as f:
        return json.load(f)["pricing"]


def price_of(pricing, model):
    m = (model or "").lower()
    for key, val in pricing.items():
        if key != "default" and key in m:
            return val
    return pricing["default"]


def cost_usd(pricing, model, u):
    p = price_of(pricing, model)
    return (u.get("input_tokens", 0) * p["input"]
            + u.get("output_tokens", 0) * p["output"]
            + u.get("cache_creation_input_tokens", 0) * p["cacheWrite"]
            + u.get("cache_read_input_tokens", 0) * p["cacheRead"]) / 1_000_000


def scan(days):
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    pricing = load_pricing()
    cost = defaultdict(float)          # (model, 层) -> USD
    tools, agents = Counter(), Counter()             # 全层计数（含 subagent 内部嵌套），仅供参考展示
    main_tools, main_agents = Counter(), Counter()   # 派发率分子分母 —— 必须同层，否则比值失真
    main_edits = 0                     # 主 loop 亲自改文件的次数
    sessions = defaultdict(lambda: {"peak": 0, "calls": 0, "cost": 0.0})
    skipped_no_ts = 0                  # timestamp 缺失/畸形被跳过的记录数，供人工核查口径

    for fp in glob.glob(os.path.expanduser("~/.claude/projects/**/*.jsonl"), recursive=True):
        # 文件级预过滤：mtime 是"最后一次写入"，早于 cutoff 就不可能含窗口内记录，
        # 跳过整份文件是安全的性能优化 —— 不是本次要修的口径 bug，保留。
        if datetime.fromtimestamp(os.path.getmtime(fp), timezone.utc) < cutoff:
            continue
        with open(fp, errors="replace") as fh:
            for line in fh:
                if '"message"' not in line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue          # 写到一半的尾行，跳过即可

                # 口径修复（2026-09-19）：上面的 mtime 只过滤到"文件级"——一个长寿 session
                # 文件今天被碰过一次，里面混着 09-12 起的历史记录，此前会被整份计入"最近 N 天"
                # （实测：总成本 +10%，466 条超窗记录被误计入）。这里按每条记录自己的
                # timestamp 二次过滤，是这次要修的核心。
                ts_raw = rec.get("timestamp")
                if not ts_raw:
                    skipped_no_ts += 1
                    continue
                try:
                    ts = datetime.fromisoformat(ts_raw.replace("Z", "+00:00"))
                except (ValueError, AttributeError):
                    skipped_no_ts += 1
                    continue
                if ts < cutoff:
                    continue
                # 选择：timestamp 缺失/畸形一律跳过（不计入任何窗口），不是"缺失就当在窗口内"。
                # 理由：这是"最近 N 天"报告，缺时间戳 = 无法证明它在窗口内，算进去就是重犯
                # 本次要修的同一类错误（拿不确定的东西冒充确定）。代价是可能轻微低估，
                # 但"看不清就不算"比"看不清就算进去"更适合一份审计脚本。

                msg = rec.get("message")
                if not isinstance(msg, dict):
                    continue
                model = msg.get("model") or ""
                if model == "<synthetic>":
                    continue
                side = "subagent" if rec.get("isSidechain") else "main"

                u = msg.get("usage")
                if isinstance(u, dict):
                    c = cost_usd(pricing, model, u)
                    cost[(model, side)] += c
                    ctx = (u.get("cache_read_input_tokens", 0)
                           + u.get("cache_creation_input_tokens", 0)
                           + u.get("input_tokens", 0))
                    s = sessions[rec.get("sessionId") or fp]
                    s["peak"] = max(s["peak"], ctx)
                    s["calls"] += 1
                    s["cost"] += c

                for blk in (msg.get("content") or []):
                    if not isinstance(blk, dict) or blk.get("type") != "tool_use":
                        continue
                    name = blk.get("name", "?")
                    tools[name] += 1
                    if side == "main":
                        main_tools[name] += 1
                    if name in ("Agent", "Task"):
                        who = (blk.get("input") or {}).get("subagent_type") or "(default)"
                        agents[who] += 1
                        if side == "main":
                            main_agents[who] += 1
                    elif side == "main" and name in ("Edit", "Write", "NotebookEdit"):
                        main_edits += 1
    return cost, tools, agents, main_edits, sessions, main_tools, main_agents, skipped_no_ts


def main():
    days = int(sys.argv[1]) if len(sys.argv) > 1 else 7
    cost, tools, agents, main_edits, sessions, main_tools, main_agents, skipped = scan(days)
    total = sum(cost.values()) or 1e-9
    n_tools_main = sum(main_tools.values()) or 1
    n_agent_main = sum(main_agents.values())
    n_agent_all = sum(agents.values())
    n_nested = n_agent_all - n_agent_main   # subagent 内部自己再派发，不是主 loop 的派发行为

    print(f"\n=== 编排行为度量 · 最近 {days} 天 ===\n")
    print(f"{'模型':<22}{'层':<11}{'成本 USD':>12}{'占比':>8}")
    print("-" * 53)
    for (model, side), c in sorted(cost.items(), key=lambda x: -x[1]):
        print(f"{model.replace('claude-','')[:20]:<22}{side:<11}{c:>12.2f}{c/total*100:>7.1f}%")

    main_cost = sum(c for (_, s), c in cost.items() if s == "main")
    print(f"\n主 loop 成本占比        {main_cost/total*100:.1f}%   (越低说明活派得越出去)")
    # 分子分母同限主 loop：这个比率量的是"主 loop 有没有把活派出去"，混入 subagent
    # 内部自己的嵌套派发会把分子分母都搞混层，比值失去意义。
    print(f"Agent 派发率（主 loop） {n_agent_main/n_tools_main*100:.2f}%   "
          f"({n_agent_main} 次派发 / {n_tools_main} 次主 loop 工具调用)")
    if n_nested:
        print(f"  另有 {n_nested} 次是 subagent 内部自己再派发的嵌套调用 —— "
              f"不计入上面的比率（那是子任务自己的编排，不是主 loop 决定要不要派活）")
    print(f"主 loop 亲自改文件      {main_edits} 次   (执行层承接后这个数该降)")
    if skipped:
        print(f"（{skipped} 条记录因 timestamp 缺失/畸形被跳过，未计入本次窗口统计）")

    if main_agents:
        print("\n--- 主 loop 派给了谁 ---")
        for who, n in main_agents.most_common(8):
            print(f"  {who[:40]:<42}{n:>5}")

    print("\n--- session context 峰值分布 ---")
    buckets = [(0, CTX_WARN, "健康"), (CTX_WARN, CTX_CRIT, f"偏长 >{CTX_WARN//1000}K"),
               (CTX_CRIT, 10**12, f"该切 >{CTX_CRIT//1000}K")]
    for lo, hi, label in buckets:
        grp = [s for s in sessions.values() if lo <= s["peak"] < hi]
        if grp:
            share = sum(s["cost"] for s in grp) / total * 100
            print(f"  {label:<16}{len(grp):>4} 个 session   吃掉 {share:>5.1f}% 成本")

    worst = sorted(sessions.values(), key=lambda s: -s["cost"])[:5]
    print(f"\n--- 最贵的 5 个 session ---")
    for s in worst:
        flag = " ← 超阈值" if s["peak"] >= CTX_CRIT else ""
        print(f"  峰值 {s['peak']/1000:>6.0f}K   {s['calls']:>5} 次调用   ${s['cost']:>7.2f}{flag}")


if __name__ == "__main__":
    main()
