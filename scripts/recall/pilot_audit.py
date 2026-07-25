#!/usr/bin/env python3
"""[DEPRECATED 2026-07-24] Pilot skill attach-rate audit (2 周观察期).

⚠️ pilot「2 周试用期」机制已退役——3 个 pilot 裁决完毕(emoji 43% / max-mode 57% 转正,
   nextjs-hmr 7% 优化 description 后转常规观察)。reflect Step 3 已改常规 attach 审计,
   不再调用本脚本。保留仅作历史参考。

每周手动跑: python3 pilot_audit.py
对比基线 (2026-05-24 0%) 看 attach 率是否上升。

3 个 pilot:
- nextjs-hmr-proactive-restart
- ui-design-emoji-discipline
- max-mode-protocol
"""
import argparse, sqlite3, time, pathlib

DB = pathlib.Path.home() / ".claude/recall.db"
NOW = int(time.time())

PILOT = [
    {
        "slug": "nextjs-hmr-proactive-restart",
        "trigger_kw": '"Next.js" OR "HMR" OR ".next" OR "middleware" OR "server component"',
        "attach_kw": '"nextjs-hmr-proactive-restart" OR "rm -rf .next" OR "pkill -f next dev"',
    },
    {
        "slug": "ui-design-emoji-discipline",
        "trigger_kw": '"emoji" OR "CTA" OR "close button" OR "状态指示" OR "按钮文案"',
        "attach_kw": '"ui-design-emoji-discipline" OR "self-grill" OR "pictographic"',
    },
    {
        "slug": "max-mode-protocol",
        "trigger_kw": '"max mode" OR "陪审团" OR "17 agent" OR "评估 idea"',
        "attach_kw": '"max-mode-protocol" OR "17-agent Full" OR "MVMM" OR "self-ritualization gate"',
    },
]


def count(conn, q, since):
    sql = "SELECT COUNT(DISTINCT m.session_id) FROM msg_fts JOIN messages m ON msg_fts.rowid=m.rowid WHERE msg_fts MATCH ? AND m.ts >= ?"
    try: return conn.execute(sql, (q, since)).fetchone()[0]
    except sqlite3.OperationalError as e: return f"ERR:{e}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--window", default="7d", help="时间窗 7d/14d/30d (default 7d)")
    args = ap.parse_args()

    n_days = int(args.window.rstrip("dhm"))
    unit = args.window[-1]
    secs = {"d": 86400, "h": 3600, "m": 60}[unit] * n_days
    since = NOW - secs

    conn = sqlite3.connect(DB)
    print(f"\n=== Pilot Skill Attach Audit (window={args.window}, since={time.strftime('%F', time.localtime(since))}) ===\n")
    print(f"{'pilot':<35} {'trigger':>8} {'attach':>8}  attach-rate")
    print("-" * 75)
    for p in PILOT:
        trig = count(conn, p["trigger_kw"], since)
        atch = count(conn, p["attach_kw"], since)
        if isinstance(trig, int) and isinstance(atch, int) and trig > 0:
            rate = f"{100*atch/trig:.0f}%"
        else:
            rate = "n/a"
        print(f"{p['slug']:<35} {trig:>8} {atch:>8}  {rate}")

    print("\n基线 (pilot 启动日 2026-05-24): attach=0 全部 (skill 刚创建)")
    print("目标 (2 周后 2026-06-07): trigger 高的至少有 1-3 个 attach 信号")
    print("KPI gate: attach-rate ≥30% → pilot 通过, 扩到 next batch")
    print("         attach-rate <30% → 检查 SKILL.md description 质量, 不达标硬 kill")


if __name__ == "__main__":
    main()
