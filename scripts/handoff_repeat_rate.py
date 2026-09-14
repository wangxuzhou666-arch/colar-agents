#!/usr/bin/env python3
"""handoff 重踩率 —— RL 回路的 reward signal。

原理：handoff 的目的是让下个 session 不重踩已知的坑。
      所以 t 时刻写下的坑若在 t' > t 又出现，就是一次交接失效。
      重踩率 = handoff 体系的失效率，完全自动可算，不需要人工打分、不需要 transcript。

用法：
  python3 handoff_repeat_rate.py                        # 当前 repo
  python3 handoff_repeat_rate.py /path/to/repo
  python3 handoff_repeat_rate.py --json                 # 机读输出，供趋势追踪

同时读 .claude/handoffs/ 的现存文件与 .claude/handoffs-archive/*.tar.gz 的归档，
所以 prune_handoffs.sh 清理过也不丢历史基线 —— 这是这个指标能长期比较的前提。

policy（2026-09-13 拍板）：重踩率降不下去 = 上一轮「该升级成 hook 的坑」选错了对象。
  机械坑（每 session 都成立、与任务无关）→ 升级到 scripts/hooks/bash_pitfall_guard.sh
  判断坑 → 留在 skill 文本里
"""
import os, re, sys, json, glob, tarfile, subprocess, datetime
from collections import Counter, defaultdict

THRESH = 0.45          # Jaccard 相似度阈值：两条坑是否算同一种
MIN_TOKENS = 4         # 指纹 token 数下限，太短不可靠


def repo_root(argv):
    for a in argv[1:]:
        if not a.startswith("-"):
            return a
    try:
        return subprocess.check_output(["git", "rev-parse", "--show-toplevel"],
                                       text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return None


def iter_handoffs(root):
    """产出 (date, name, text)，现存文件 + 归档 tar 一起。"""
    hd = os.path.join(root, ".claude", "handoffs")
    for p in sorted(glob.glob(os.path.join(hd, "*.md"))):
        name = os.path.basename(p)
        txt = open(p, encoding="utf-8", errors="replace").read()
        yield name, txt
    ad = os.path.join(root, ".claude", "handoffs-archive")
    for tp in sorted(glob.glob(os.path.join(ad, "*.tar.gz"))):
        try:
            with tarfile.open(tp, "r:gz") as tf:
                for m in tf.getmembers():
                    if not m.name.endswith(".md"):
                        continue
                    f = tf.extractfile(m)
                    if f:
                        yield os.path.basename(m.name), f.read().decode("utf-8", "replace")
        except Exception as e:
            print(f"  ⚠️ 归档 {os.path.basename(tp)} 读取失败: {e}", file=sys.stderr)


def grab_pitfalls(txt):
    m = re.search(r"踩过的坑[^\n]*[：:]\s*", txt)
    if not m:
        return []
    rest = txt[m.end():]
    stops = ["下次入口", "本次已完成", "关键决策", "⚠️", "先验收", "DEFAULT_ACTION", "\n```"]
    ends = [rest.find(s) for s in stops]
    ends = [e for e in ends if e > 0]
    block = rest[:min(ends)] if ends else rest[:1200]
    items = re.split(r"\n\s*[-·•]\s*|\s+·\s+", block)
    return [re.sub(r"\s+", " ", i).strip(" -·•\n") for i in items if len(i.strip()) > 12]


def fingerprint(t):
    t = re.sub(r"\[[a-z\-]+\]", "", t)            # 去证据标签
    t = re.sub(r"\b[0-9a-f]{7,40}\b", "", t)      # 去 sha
    t = re.sub(r"\d+", "", t)
    t = re.sub(r"[^\w一-鿿]+", " ", t)
    bag = set()
    for w in t.split():
        if len(w) < 2:
            continue
        if re.match(r"^[一-鿿]+$", w):
            bag |= {w[i:i + 2] for i in range(len(w) - 1)}
        else:
            bag.add(w.lower())
    return bag


def jaccard(a, b):
    return len(a & b) / len(a | b) if a and b else 0.0


def isoweek(d):
    y, m, dd = map(int, d.split("-"))
    iso = datetime.date(y, m, dd).isocalendar()
    return f"{iso[0]}-W{iso[1]:02d}"


def main():
    root = repo_root(sys.argv)
    if not root:
        print("不在 git repo 里且未传 repo 路径", file=sys.stderr)
        return 1
    as_json = "--json" in sys.argv

    pits = []
    n_files = 0
    for name, txt in iter_handoffs(root):
        mo = re.match(r"^(\d{4}-\d{2}-\d{2})T", name)
        if not mo:
            continue
        n_files += 1
        for it in grab_pitfalls(txt):
            pits.append((mo.group(1), name, it))
    pits.sort(key=lambda x: (x[0], x[1]))

    if not pits:
        print("没提取到坑条目（handoffs 目录为空？）", file=sys.stderr)
        return 1

    fps = [(d, f, t, fingerprint(t)) for d, f, t in pits]
    fps = [x for x in fps if len(x[3]) >= MIN_TOKENS]

    seen = []
    byweek_new, byweek_rep = Counter(), Counter()
    repeats = defaultdict(list)
    for d, f, t, fp in fps:
        w = isoweek(d)
        hit = None
        for i, s in enumerate(seen):
            if jaccard(s[0], fp) >= THRESH:
                hit = i
                break
        if hit is not None:
            byweek_rep[w] += 1
            seen[hit][0].update(fp)
            repeats[seen[hit][1]].append((d, t))
        else:
            byweek_new[w] += 1
            seen.append([set(fp), len(seen), t])

    weeks = sorted(set(byweek_new) | set(byweek_rep))
    rows = []
    for w in weeks:
        n, r = byweek_new[w], byweek_rep[w]
        rows.append({"week": w, "new": n, "repeat": r, "rate": r / (n + r) if n + r else 0.0})

    tot_new = sum(byweek_new.values())
    tot_rep = sum(byweek_rep.values())
    overall = tot_rep / (tot_new + tot_rep) if (tot_new + tot_rep) else 0.0

    worst = sorted(repeats.items(), key=lambda kv: -len(set(d for d, _ in kv[1])))[:8]
    worst_out = [{"days": len(set(d for d, _ in v)), "hits": len(v),
                  "sample": seen[k][2][:140]} for k, v in worst if len(set(d for d, _ in v)) >= 2]

    if as_json:
        print(json.dumps({"repo": root, "files": n_files, "items": len(fps),
                          "overall_repeat_rate": round(overall, 4),
                          "weekly": rows, "worst": worst_out}, ensure_ascii=False, indent=1))
        return 0

    print(f"# handoff 重踩率  repo={root}")
    print(f"  样本 {n_files} 份 handoff / {len(fps)} 条坑（含归档 tar）")
    print(f"  总体重踩率 {overall:.1%}  （新坑 {tot_new} · 重踩 {tot_rep}）\n")
    print("  周        新坑  重踩   重踩率")
    for r in rows:
        bar = "#" * int(r["rate"] * 30)
        print(f"  {r['week']}  {r['new']:4d}  {r['repeat']:4d}   {r['rate']:6.1%}  {bar}")

    if worst_out:
        print("\n## 重踩最狠的坑种（升级成 hook 的首选候选）")
        for w in worst_out:
            print(f"  ● 跨 {w['days']} 天 / {w['hits']} 次 — {w['sample']}")
    print("\n  policy: 机械坑 → scripts/hooks/bash_pitfall_guard.sh 加规则；判断坑 → 留 skill 文本。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
