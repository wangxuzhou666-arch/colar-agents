#!/usr/bin/env python3
"""wf_progress.py — Workflow / subagent 编排进度快照。

VSCode 扩展里 /workflows 那个实时 TUI 画不出来,本脚本从落盘的
journal.jsonl + agent-*.jsonl 里重建一个能看懂的进度面板。

用法:
  python3 wf_progress.py            # 自动挑「最新活动」的那个 workflow
  python3 wf_progress.py <wf-id>    # 按 wf id 子串定位(如 wf_bc4eaadf 或 bc4eaadf)
  python3 wf_progress.py <目录绝对路径>
  python3 wf_progress.py --list     # 列出所有 workflow,按活跃度排序
"""
import sys, os, glob, json, re, time

HOME = os.path.expanduser("~")
BASE = os.path.join(HOME, ".claude", "projects")
# 所有 workflow 目录的 glob 模式:<project>/<session>/subagents/workflows/wf_*/
WF_GLOB = os.path.join(BASE, "*", "*", "subagents", "workflows", "wf_*")


def age(ts):
    """把「距今秒数」转成人话。"""
    d = time.time() - ts
    if d < 90:      return f"{int(d)}s 前"
    if d < 5400:    return f"{int(d/60)}m 前"
    return f"{int(d/3600)}h 前"


def newest_mtime(wf_dir):
    """整个 workflow 目录里最新一次文件写入时间 —— 用来判活跃度。"""
    files = glob.glob(os.path.join(wf_dir, "*.jsonl"))
    return max((os.path.getmtime(f) for f in files), default=os.path.getmtime(wf_dir))


def find_wf(arg):
    """定位目标 workflow 目录。arg 可为 None / wf-id 子串 / 绝对路径。"""
    if arg:
        if os.path.isdir(arg):
            return arg
        cands = [d for d in glob.glob(WF_GLOB) if os.path.isdir(d) and arg in os.path.basename(d)]
        if not cands:
            return None
        return max(cands, key=newest_mtime)
    # 无参 → 挑最新活动的那个
    cands = [d for d in glob.glob(WF_GLOB) if os.path.isdir(d)]
    if not cands:
        return None
    return max(cands, key=newest_mtime)


def list_all():
    cands = [d for d in glob.glob(WF_GLOB) if os.path.isdir(d)]
    cands.sort(key=newest_mtime, reverse=True)
    if not cands:
        print("没找到任何 workflow 运行记录。")
        return
    print(f"共 {len(cands)} 个 workflow(按最近活动排序):\n")
    for d in cands[:20]:
        s, done, inflight = quick_counts(d)
        print(f"  {os.path.basename(d):<20} 起{s:>3} 完成{done:>3} 飞{inflight:>2}  末次活动 {age(newest_mtime(d))}")


def quick_counts(wf_dir):
    started, done = set(), set()
    jp = os.path.join(wf_dir, "journal.jsonl")
    if os.path.exists(jp):
        with open(jp) as f:
            for l in f:
                l = l.strip()
                if not l:
                    continue
                try:
                    e = json.loads(l)
                except Exception:
                    continue
                aid = e.get("agentId")
                if e.get("type") == "started":
                    started.add(aid)
                elif e.get("type") == "result":
                    done.add(aid)
    return len(started), len(done), len(started - done)


def classify(prompt):
    """从 agent 的首个 user prompt 里提取一个短角色标签。"""
    if not prompt:
        return "?"
    p = prompt.strip()
    m = re.match(r"你是\s*([^。\n,，]+)", p)
    if m:
        return m.group(1).strip()
    if "对抗验证" in p[:24]:
        lm = re.search(r"lens\s*切入[:：]\s*([^\n]+)", p)
        lens = lm.group(1).strip()[:10] if lm else ""
        cm = re.search(r"Claim[:：]\s*([^\n]+)", p)
        claim = cm.group(1).strip()[:34] if cm else ""
        return f"对抗验证({lens}) {claim}"
    if "合成" in p[:40]:
        return "合成决策视图"
    return p[:20]


def agent_detail(wf_dir, aid):
    """读单个 agent jsonl:返回 (role, current_action, nlines, mtime)。"""
    matches = glob.glob(os.path.join(wf_dir, f"agent-{aid}*.jsonl")) or \
              glob.glob(os.path.join(wf_dir, f"agent-*{aid}*.jsonl"))
    if not matches:
        return None, None, 0, 0
    fp = matches[0]
    prompt, last_action, nlines = None, None, 0
    with open(fp) as f:
        for l in f:
            nlines += 1
            try:
                e = json.loads(l)
            except Exception:
                continue
            msg = e.get("message", {}) or {}
            # 抓首个 user prompt
            if prompt is None and msg.get("role") == "user":
                c = msg.get("content")
                if isinstance(c, str):
                    prompt = c
                elif isinstance(c, list):
                    for b in c:
                        if isinstance(b, dict) and b.get("type") == "text":
                            prompt = b.get("text")
                            break
            # 抓最后一个 tool_use 当「当前动作」
            c = msg.get("content")
            if isinstance(c, list):
                for b in c:
                    if isinstance(b, dict) and b.get("type") == "tool_use":
                        inp = b.get("input", {}) or {}
                        hint = (inp.get("description") or inp.get("command")
                                or inp.get("file_path") or inp.get("pattern") or "")
                        last_action = f"{b.get('name')}: {str(hint)[:56]}"
    return classify(prompt), last_action, nlines, os.path.getmtime(fp)


def render(wf_dir):
    rows = []
    with open(os.path.join(wf_dir, "journal.jsonl")) as f:
        for l in f:
            l = l.strip()
            if l:
                try:
                    rows.append(json.loads(l))
                except Exception:
                    pass
    started, done = {}, set()
    for r in rows:
        aid = r.get("agentId")
        if r.get("type") == "started":
            started[aid] = r.get("key")
        elif r.get("type") == "result":
            done.add(aid)
    inflight = [aid for aid in started if aid not in done]

    fresh = newest_mtime(wf_dir)
    live = "🟢 活跃" if (time.time() - fresh) < 90 else \
           ("🟡 静默" if (time.time() - fresh) < 600 else "⚪️ 已停/结束")

    print("=" * 64)
    print(f"{os.path.basename(wf_dir)}   {live}(末次写入 {age(fresh)})")
    print(f"{len(started)} 起 · {len(done)} 完成 · {len(inflight)} 在飞"
          f" · 完成度 {int(100*len(done)/max(len(started),1))}%")
    print("=" * 64)

    if not inflight:
        print("\n✅ 所有 agent 已完成 —— 编排结束,等主流程取回合成结果。")
        return

    # 在飞的按最近活动排序,活的排前面
    detailed = []
    for aid in inflight:
        role, act, nl, mt = agent_detail(wf_dir, aid)
        detailed.append((mt, aid, role, act, nl))
    detailed.sort(reverse=True)

    print(f"\n⏳ {len(inflight)} 个在飞 agent(按最近活动排序):\n")
    for mt, aid, role, act, nl in detailed:
        flag = "🟢" if mt and (time.time() - mt) < 90 else "🟡"
        print(f"{flag} {role or '(未知)'}")
        print(f"     现在: {act or '(无 tool_use,思考中/首轮)'}   ·  {nl} 行 · {age(mt) if mt else '?'}")
    print()


def main():
    arg = sys.argv[1].strip() if len(sys.argv) > 1 and sys.argv[1].strip() else None
    if arg in ("--list", "-l", "list"):
        list_all()
        return
    wf = find_wf(arg)
    if not wf:
        print(f"没找到匹配的 workflow{' (arg='+arg+')' if arg else ''}。")
        print("试试 `--list` 看有哪些,或确认确实起过 Workflow 工具编排。")
        return
    render(wf)


if __name__ == "__main__":
    main()
