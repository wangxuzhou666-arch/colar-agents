#!/usr/bin/env python3
"""编排行为度量 — 回答「主 loop 到底有没有把活派出去」以及这些活到底烧了多少钱。

cc-usage-bar 按 model 分组算钱，但看不见两个决定成本的维度：
活是主 loop 自己干的还是派给 subagent 的，以及单个 session 的 context 涨到了多少。

2026-09-19 修过一版口径（per-record timestamp 窗口过滤 + 派发率分子分母同限主 loop
+ 补齐 Task 别名）——历史读数与本版不可直接比较，新旧对照见 eval/BASELINE.md。

2026-10-01 再修一版口径：按模型版本定价（最长子串匹配）+ cache 写按 5m/1h TTL
拆分 + 按 message.id 去重（同一条回复流式落盘成多条记录：usage 取最新那条，tool_use 取整组并集）
+ session 峰值只看主 loop（subagent 与父 session 共用 sessionId）。
新旧对照与各因素贡献见 eval/BASELINE.md。

用法: python3 scripts/orchestration_audit.py [天数]
"""
import json, os, sys, glob
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone

PRICING_FILE = os.path.expanduser("~/Desktop/cc-usage-bar/config.json")
# clear + resume 要重付 session 基线(~60K) 加 handoff 正文(~20K)。
# context 超过这个数，继续拖着的每轮开销就压过了重开一轮的成本。
CTX_WARN, CTX_CRIT = 200_000, 300_000

# 主 loop cache-break 判据：非首次调用 且 本次 cache_creation ≥ max(下限, 半数 prompt)。
BREAK_FLOOR_TOKENS = 20_000
BREAK_PROMPT_FRACTION = 0.5
# 距上一次主 loop 调用的间隔分档（秒），用于定冷缓存守卫阈值。
GAP_BUCKETS = [(0, 300, "<5分钟"), (300, 3600, "5-60分钟"), (3600, 10**12, ">60分钟")]


def load_pricing():
    """复用 cc-usage-bar 的价目表，避免两处数字各说各话。"""
    with open(PRICING_FILE) as f:
        return json.load(f)["pricing"]


def match_price(pricing, model):
    """最长子串匹配版本键（如 'opus-5-5' 优先于 'opus-5' 优先于 'opus'），
    'default' 不参与匹配、只做兜底。返回 (命中的键, 价格 dict)。"""
    m = (model or "").lower()
    best_key, best_len = None, -1
    for key in pricing:
        if key == "default":
            continue
        if key in m and len(key) > best_len:
            best_key, best_len = key, len(key)
    if best_key is None:
        return "default", pricing["default"]
    return best_key, pricing[best_key]


def record_cost(pricing, model, u, diag):
    """单条（已去重的最终快照）记录的美元成本。

    返回 (总成本, cache 写入部分的成本, 按类目拆的 {类目: (token数, USD)} 明细)。
    diag 是调用方传入的诊断计数器 dict，记录落到 default 的 model、fast 条数、
    cache 细分缺失/不全的条数——这些都要在报告里如实打印，不能悄悄吞掉。
    """
    key, p = match_price(pricing, model)
    if key == "default":
        diag["default_models"][model] += 1
    if "cacheWrite1h" not in p:
        # 选择：缺字段直接报错，不用 cacheWrite×1.6 猜。config.json 里本该每条
        # 都写了 cacheWrite1h，缺了大概率是配置出错，不是该兜底蒙混的场景。
        raise ValueError(f"价目表条目 '{key}' 缺 cacheWrite1h 字段，拒绝用倍率猜测顶替")

    uncached_input = u.get("input_tokens", 0)
    output = u.get("output_tokens", 0)
    cache_read = u.get("cache_read_input_tokens", 0)
    cache_total = u.get("cache_creation_input_tokens", 0)

    detail = u.get("cache_creation")
    if isinstance(detail, dict):
        five_m = detail.get("ephemeral_5m_input_tokens", 0)
        one_h = detail.get("ephemeral_1h_input_tokens", 0)
        covered = five_m + one_h
        if covered < cache_total:
            five_m += cache_total - covered   # 细分之和不够，差额按便宜的 5m 价顶上
            diag["cache_breakdown_short"] += 1
    else:
        five_m, one_h = cache_total, 0
        if cache_total:
            diag["cache_breakdown_missing"] += 1

    def usd(tokens, rate):
        return tokens * rate / 1_000_000

    parts = {
        "uncached_input": (uncached_input, usd(uncached_input, p["input"])),
        "output":         (output,         usd(output,         p["output"])),
        "cache_read":     (cache_read,     usd(cache_read,     p["cacheRead"])),
        "cache_write_5m": (five_m,         usd(five_m,         p["cacheWrite"])),
        "cache_write_1h": (one_h,          usd(one_h,          p["cacheWrite1h"])),
    }
    cost = sum(c for _, c in parts.values())
    cache_write_cost = parts["cache_write_5m"][1] + parts["cache_write_1h"][1]

    if u.get("speed") == "fast":
        # fast mode 整条记录按标准价的 2 倍算 —— 分类明细也同步翻倍，
        # 否则按类目加总会对不上总成本。
        cost *= 2
        cache_write_cost *= 2
        parts = {k: (tok, c * 2) for k, (tok, c) in parts.items()}
        diag["fast_mode_records"] += 1

    return cost, cache_write_cost, parts


def _collect(days):
    """第一遍扫描：读所有窗口内的 jsonl 记录，按 message.id 去重（usage 取 timestamp
    最新的一条，content block 取整组并集），没有 id 的记录不参与去重、原样留着。返回去重后要
    参与聚合的记录列表，以及去重过程本身的计数（供人工核查口径用）。"""
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    by_msg_id = {}         # message.id -> 目前保留的最新快照
    blocks_by_mid = {}     # message.id -> 整组快照的 content block 并集（按 block id 去重）
    noid_records = []      # 没有 message.id 的记录，不去重，直接收集
    skipped_no_ts = 0
    n_raw_with_id = 0      # 带 id 的原始行数（含重复），用于算丢弃了多少条

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
                # 文件今天被碰过一次，里面混着历史记录，此前会被整份计入"最近 N 天"。
                # 这里按每条记录自己的 timestamp 二次过滤。
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
                # 这是"最近 N 天"报告，缺时间戳 = 无法证明它在窗口内，"看不清就不算"
                # 比"看不清就算进去"更适合一份审计脚本。

                msg = rec.get("message")
                if not isinstance(msg, dict):
                    continue
                model = msg.get("model") or ""
                if model == "<synthetic>":
                    continue
                side = "subagent" if rec.get("isSidechain") else "main"
                mid = msg.get("id")
                entry = {
                    "ts_raw": ts_raw, "ts": ts, "model": model, "side": side,
                    "sessionId": rec.get("sessionId") or fp,
                    "usage": msg.get("usage"),
                    "content": msg.get("content") or [],
                }

                if not mid:
                    noid_records.append(entry)   # 没有 id，不去重，原样计入
                    continue
                n_raw_with_id += 1
                # 每条快照只带一个 content block（thinking / text / 某一个 tool_use），
                # 并行工具调用分散在同组不同快照里 —— usage 取最新那条，block 要整组拼起来，
                # 否则只留最后一条会漏掉前面的 tool_use（2026-10-01 实测 7 天漏 5863 个）。
                blocks = blocks_by_mid.setdefault(mid, {})
                for i, blk in enumerate(entry["content"]):
                    key = blk.get("id") if isinstance(blk, dict) and blk.get("id") else (ts_raw, i)
                    blocks.setdefault(key, blk)
                prev = by_msg_id.get(mid)
                if prev is None or ts_raw > prev["ts_raw"]:
                    by_msg_id[mid] = entry

    for mid, entry in by_msg_id.items():
        entry["content"] = list(blocks_by_mid[mid].values())
    return by_msg_id, noid_records, n_raw_with_id, skipped_no_ts


def scan(days):
    pricing = load_pricing()
    by_msg_id, noid_records, n_raw_with_id, skipped_no_ts = _collect(days)
    n_dedup_ids = len(by_msg_id)
    n_discarded_dup = n_raw_with_id - n_dedup_ids

    diag = {
        "default_models": Counter(),
        "cache_breakdown_missing": 0,
        "cache_breakdown_short": 0,
        "fast_mode_records": 0,
    }
    cost = defaultdict(float)                              # (model, 层) -> USD
    tools, agents = Counter(), Counter()                   # 全层计数（含 subagent 内部嵌套），仅供参考展示
    main_tools, main_agents = Counter(), Counter()         # 派发率分子分母 —— 必须同层，否则比值失真
    main_edits = 0                                          # 主 loop 亲自改文件的次数
    sessions = defaultdict(lambda: {"peak": 0, "calls": 0, "cost": 0.0, "main_cost": 0.0})
    tok_tokens = defaultdict(lambda: defaultdict(int))     # tok_tokens[层][类目] = token 数
    tok_cost = defaultdict(lambda: defaultdict(float))     # tok_cost[层][类目] = USD
    session_main_calls = defaultdict(list)                 # sid -> [(ts, usage, cache写成本), ...]

    # 第二遍：对去重后的记录（真正保留下来的那条 + 不参与去重的记录）统一聚合。
    for rec in list(by_msg_id.values()) + noid_records:
        model, side, sid, content = rec["model"], rec["side"], rec["sessionId"], rec["content"]
        u = rec["usage"]

        if isinstance(u, dict):
            c, cache_write_cost, parts = record_cost(pricing, model, u, diag)
            cost[(model, side)] += c
            for cat, (tok, usd) in parts.items():
                tok_tokens[side][cat] += tok
                tok_cost[side][cat] += usd

            ctx = (u.get("cache_read_input_tokens", 0)
                   + u.get("cache_creation_input_tokens", 0)
                   + u.get("input_tokens", 0))
            s = sessions[sid]
            s["cost"] += c                     # 整 session 花费（含 subagent），供「最贵 session」排序
            if side == "main":
                # 峰值 / 调用数只看主 loop：subagent 记录和父 session 共用 sessionId
                # （2026-10-01 实测 55/55），混进来会把 subagent 自己的长 context 算成"主 loop 该切了"。
                s["peak"] = max(s["peak"], ctx)
                s["calls"] += 1
                s["main_cost"] += c
                session_main_calls[sid].append((rec["ts"], u, cache_write_cost))

        # tool_use 计数与 usage 是否存在无关（原版行为）：一条记录没有 usage 不代表
        # 它没有 content —— 这里只是实测中这支目前只会被不带 usage 的用户消息命中。
        for blk in content:
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

    break_stats = _cache_break_analysis(session_main_calls)

    return {
        "cost": cost, "tools": tools, "agents": agents, "main_edits": main_edits,
        "sessions": sessions, "main_tools": main_tools, "main_agents": main_agents,
        "skipped_no_ts": skipped_no_ts, "tok_tokens": tok_tokens, "tok_cost": tok_cost,
        "diag": diag, "n_raw_with_id": n_raw_with_id, "n_dedup_ids": n_dedup_ids,
        "n_discarded_dup": n_discarded_dup, "n_noid": len(noid_records),
        "break_stats": break_stats,
    }


def _cache_break_analysis(session_main_calls):
    """主 loop cache-break 计数（只看主 loop、按 session 去重排序后的调用序列）。

    每个 session 第一次调用算「冷启动」，不算 break。非首次调用里，
    cache_creation ≥ max(20_000, 0.5 × prompt总量) 才算一次 break
    （prompt总量 = input + cache_read + cache_creation）。

    冷启动的"距上一次活动"口径取了简化版：只给总次数/总美元，不按间隔分档——
    按 session 自身上一次活动（而非上一次主 loop 调用）分档需要把用户消息/工具
    结果也纳入时间线，复杂度和这项诊断的边际价值不成比例，任务说明里允许这个
    降级路径，故只给总量。
    """
    break_count = 0
    break_token_total = 0
    break_cost_total = 0.0
    break_buckets = {label: [0, 0.0] for _, _, label in GAP_BUCKETS}
    cold_start_count = 0
    cold_start_cost_total = 0.0

    for calls in session_main_calls.values():
        calls.sort(key=lambda c: c[0])
        prev_ts = None
        for i, (ts, u, cache_write_cost) in enumerate(calls):
            if i == 0:
                cold_start_count += 1
                cold_start_cost_total += cache_write_cost
                prev_ts = ts
                continue
            prompt_total = (u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0)
                            + u.get("cache_creation_input_tokens", 0))
            cache_creation = u.get("cache_creation_input_tokens", 0)
            is_break = cache_creation >= max(BREAK_FLOOR_TOKENS, BREAK_PROMPT_FRACTION * prompt_total)
            if is_break:
                break_count += 1
                break_token_total += cache_creation
                break_cost_total += cache_write_cost
                gap_s = (ts - prev_ts).total_seconds()
                for lo, hi, label in GAP_BUCKETS:
                    if lo <= gap_s < hi:
                        break_buckets[label][0] += 1
                        break_buckets[label][1] += cache_write_cost
                        break
            prev_ts = ts

    return {
        "break_count": break_count, "break_token_total": break_token_total,
        "break_cost_total": break_cost_total, "break_buckets": break_buckets,
        "cold_start_count": cold_start_count, "cold_start_cost_total": cold_start_cost_total,
    }


def main():
    days = int(sys.argv[1]) if len(sys.argv) > 1 else 7
    r = scan(days)
    cost, tools, agents = r["cost"], r["tools"], r["agents"]
    main_edits, sessions = r["main_edits"], r["sessions"]
    main_tools, main_agents, skipped = r["main_tools"], r["main_agents"], r["skipped_no_ts"]

    total = sum(cost.values()) or 1e-9
    n_tools_main = sum(main_tools.values()) or 1
    n_agent_main = sum(main_agents.values())
    n_agent_all = sum(agents.values())
    n_nested = n_agent_all - n_agent_main   # subagent 内部自己再派发，不是主 loop 的派发行为

    print(f"\n=== 编排行为度量 · 最近 {days} 天 ===\n")
    print(f"去重：{r['n_raw_with_id']} 条带 message.id 的原始记录 → "
          f"{r['n_dedup_ids']} 条去重后（丢弃 {r['n_discarded_dup']} 条流式重复快照，"
          f"另有 {r['n_noid']} 条无 message.id、不参与去重）")

    print(f"\n{'模型':<22}{'层':<11}{'成本 USD':>12}{'占比':>8}")
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

    # 分母也只取主 loop 成本：阈值回答的是"主 loop context 拖长了该不该切"，
    # subagent 的花费不随主 loop context 长度变化，算进来会稀释或放大这个比例。
    print("\n--- 主 loop context 峰值分布 ---")
    main_sessions = [s for s in sessions.values() if s["calls"]]
    buckets = [(0, CTX_WARN, "健康"), (CTX_WARN, CTX_CRIT, f"偏长 >{CTX_WARN//1000}K"),
               (CTX_CRIT, 10**12, f"该切 >{CTX_CRIT//1000}K")]
    for lo, hi, label in buckets:
        grp = [s for s in main_sessions if lo <= s["peak"] < hi]
        if grp:
            share = sum(s["main_cost"] for s in grp) / (main_cost or 1e-9) * 100
            print(f"  {label:<16}{len(grp):>4} 个 session   吃掉 {share:>5.1f}% 主 loop 成本")

    worst = sorted(sessions.values(), key=lambda s: -s["cost"])[:5]
    print(f"\n--- 最贵的 5 个 session（含 subagent）---")
    for s in worst:
        flag = " ← 超阈值" if s["peak"] >= CTX_CRIT else ""
        print(f"  主 loop 峰值 {s['peak']/1000:>6.0f}K   {s['calls']:>5} 次主 loop 调用   "
              f"${s['cost']:>7.2f}（主 loop ${s['main_cost']:.2f}）{flag}")

    print("\n--- token 分类（主 / subagent / 合计） ---")
    cats = ["uncached_input", "cache_read", "cache_write_5m", "cache_write_1h", "output"]
    cat_labels = {"uncached_input": "未缓存input", "cache_read": "cache读",
                  "cache_write_5m": "cache写5m", "cache_write_1h": "cache写1h", "output": "output"}
    tok_tokens, tok_cost = r["tok_tokens"], r["tok_cost"]
    for side in ("main", "subagent", "合计"):
        print(f"\n  [{side}]")
        for cat in cats:
            if side == "合计":
                mtok = (tok_tokens["main"][cat] + tok_tokens["subagent"][cat]) / 1_000_000
                usd = tok_cost["main"][cat] + tok_cost["subagent"][cat]
            else:
                mtok = tok_tokens[side][cat] / 1_000_000
                usd = tok_cost[side][cat]
            print(f"    {cat_labels[cat]:<10}{mtok:>10.2f}M   ${usd:>10.2f}   {usd/total*100:>6.1f}%")

    bs = r["break_stats"]
    print("\n--- 主 loop cache-break 计数 ---")
    print(f"  冷启动（session 第一次主 loop 调用）: {bs['cold_start_count']} 次   "
          f"写入成本 ${bs['cold_start_cost_total']:.2f}")
    print(f"  break 次数                          : {bs['break_count']} 次")
    print(f"  break 重写 token 总量                : {bs['break_token_total']/1_000_000:.2f}M")
    print(f"  break 写入成本（仅 cache 写部分）     : ${bs['break_cost_total']:.2f}")
    print("  按距上一次主 loop 调用的间隔分档：")
    for _, _, label in GAP_BUCKETS:
        n, usd = bs["break_buckets"][label]
        print(f"    {label:<10}{n:>5} 次   ${usd:>8.2f}")

    diag = r["diag"]
    print("\n--- 定价诊断 ---")
    if diag["default_models"]:
        print(f"  落到 default 价的 model（未命中任何版本/家族键）:")
        for m, n in diag["default_models"].most_common():
            print(f"    {m:<40}{n:>6} 条")
    else:
        print("  没有记录落到 default 价 —— 价目表覆盖了本窗口全部 model")
    print(f"  fast mode（speed==fast）记录数      : {diag['fast_mode_records']}")
    print(f"  缺 cache_creation 细分字段的记录数   : {diag['cache_breakdown_missing']}")
    print(f"  细分字段之和小于总数的记录数         : {diag['cache_breakdown_short']}")


if __name__ == "__main__":
    main()
