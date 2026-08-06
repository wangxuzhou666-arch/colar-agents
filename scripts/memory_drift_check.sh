#!/usr/bin/env bash
# Memory drift detection — scans memory/ vs MEMORY.md for index mismatch + stale candidates.
#
# Usage:    bash scripts/memory_drift_check.sh
# Exit:     always 0 (advisory, never blocks). Clean 时输出以 "✓ memory drift clean" 开头的
#           单行（Stop hook 用 grep -v 静默它）；异常时输出 advisory sections。
# Why:      MEMORY.md is human-curated index for groupings/visual anchors. This script
#           detects drift but does NOT auto-modify (preserves curation). Output is paste-ready
#           — copy frontmatter snippets into MEMORY.md sections by hand.
#
# Perf:     2026-07-06 重写 — 原版 SOUL overlap 段做 ~64 短语 × ~54 文件 ≈ 3500 次
#           `echo | grep` 进程 spawn，实测 46s > Stop hook timeout 15s，每次被 kill 从未跑完。
#           现全部检查合并进单次 python3 内存扫描，实测 <0.2s。
#
# Output sections:
#   1. Unindexed files (dir 有 / MEMORY.md 没指 → 写入纪律失效信号)
#   2. Dead links (MEMORY.md 指了 / dir 没文件 → 删除后忘清理 index)
#   3. SOUL ↔ memory overlap (memory frontmatter 含 SOUL **bold** axiom 短语 → 候选重复)
#   4. Stale candidates (短 + 60d+ + 无视觉锚 → archive 候选,不强制删)
#   5. Index bloat (MEMORY.md 行数超阈值 → 索引折叠/腐烂早期信号)
#   6. Hardcoded count drift (索引里写死的 "N files" ≠ 实际 ls 数)
#   7. Unprefixed content files (顶层非 user_/feedback_/project_/reference_ 前缀的内容 md)
#   8. Expired next-actions (project_*.md 含 "下次 session/next session" 且 30d+ 未改)
#   9. Hook claim drift (文本声称 "X hook 跑 Y.sh" ≠ settings.json 实态 → 2026-08-05 新增,
#      补的是审计发现的唯一机制缺口: 3 条机制断言腐烂全部逃过前 8 项检查。否定句自动跳过)

set -u

# 路径可用 env 覆盖（默认生产路径；覆盖仅供测试/沙箱）
export MEMORY_DIR="${MEMORY_DIR:-${HOME}/.claude/projects/-Users-colar-Desktop-colar-agents/memory}"
export SOUL_PATH="${SOUL_PATH:-${HOME}/.claude/CLAUDE.md}"
# 裸 home lane 的转发索引（含 "99 files" 式总数声明）
export LANE_INDEX="${LANE_INDEX:-${HOME}/.claude/projects/-Users-colar/memory/MEMORY.md}"
# MEMORY.md 行数 advisory 阈值（原 COUNTS 注释即 "200 truncate limit"）
export INDEX_MAXLINES="${INDEX_MAXLINES:-200}"

[ -d "$MEMORY_DIR" ] || { echo "memory dir not found: $MEMORY_DIR" >&2; exit 0; }
[ -f "$MEMORY_DIR/MEMORY.md" ] || { echo "MEMORY.md not found: $MEMORY_DIR/MEMORY.md" >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found — drift check skipped" >&2; exit 0; }

# fail-open：python 内部任何异常都在 except 里吞掉后 exit 0，bash 层再兜一层 || true
python3 <<'PYEOF' || true
import glob, os, re, sys, time

def read_text(path, limit=None):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read(limit) if limit else fh.read()
    except Exception:
        return ""

def frontmatter_name_desc(path):
    """取 frontmatter 里的 name/description（对齐旧版 awk 逻辑：--- 之间的前两个命中）"""
    name = desc = ""
    fence = 0
    for ln in read_text(path, 8192).splitlines():
        if ln.strip() == "---":
            fence += 1
            if fence == 2:
                break
            continue
        if fence == 1:
            if ln.startswith("name:") and not name:
                name = ln[len("name:"):].strip()
            elif ln.startswith("description:") and not desc:
                desc = ln[len("description:"):].strip()
    return name, desc

def main():
    mem_dir = os.environ["MEMORY_DIR"]
    os.chdir(mem_dir)
    now = time.time()
    sections = []  # 每个元素是一段完整 advisory 文本

    PREFIXES = ("feedback", "project", "user", "reference")
    actual = sorted(set(
        f for p in PREFIXES for f in glob.glob(p + "_*.md")
    ))
    actual_set = set(actual)
    by_prefix = {p: sorted(glob.glob(p + "_*.md")) for p in PREFIXES}

    # Tiered index: MEMORY.md 是热索引, 冷条目下沉到 *-index.md 子索引 + transcripts/INDEX.md
    index_files = ["MEMORY.md"] + sorted(glob.glob("*-index.md"))
    if os.path.isfile("transcripts/INDEX.md"):
        index_files.append("transcripts/INDEX.md")
    ref_pat = re.compile(r"(?:feedback|project|user|reference)_[a-z_0-9]+\.md")
    indexed = set()
    for f in index_files:
        indexed.update(ref_pat.findall(read_text(f)))

    # --- 1. Unindexed ---
    unindexed = [f for f in actual if f not in indexed]
    if unindexed:
        lines = ["=== UNINDEXED (dir 有 / MEMORY.md 没指) ==="]
        for f in unindexed:
            name, desc = frontmatter_name_desc(f)
            lines.append("  " + f)
            if name:
                lines.append("    name: " + name)
            if desc:
                lines.append("    desc: " + desc)
        sections.append("\n".join(lines))

    # --- 2. Dead links ---
    dead = sorted(indexed - actual_set)
    if dead:
        sections.append("=== DEAD LINKS (MEMORY.md 指了 / dir 没文件) ===\n"
                        + "\n".join("  " + f for f in dead))

    # --- 3. SOUL ↔ memory content overlap（单次内存扫描，无进程 spawn） ---
    soul_path = os.environ.get("SOUL_PATH", "")
    if soul_path and os.path.isfile(soul_path):
        soul_text = read_text(soul_path)
        # 提取 **X** bold 短语,长度 ≥ 4 char(过滤单字符 / 短虚词),与旧版口径一致
        phrases = sorted(set(m for m in re.findall(r"\*\*([^*]{4,40})\*\*", soul_text)))
        overlap = []
        for f in by_prefix["feedback"]:
            name, desc = frontmatter_name_desc(f)
            meta = (name + "\n" + desc).lower()
            if not meta.strip():
                continue
            for phrase in phrases:
                if phrase.lower() in meta:
                    overlap.append("  %s  ←→ SOUL: '%s'" % (f, phrase))
        if overlap:
            sections.append(
                "=== SOUL ↔ MEMORY OVERLAP (memory frontmatter 含 SOUL bold axiom 短语) ===\n"
                + "\n".join(overlap) + "\n"
                + "  注: 候选重复。SOUL 已 cover 该 axiom,memory 可能多余。\n"
                + "  → 决策: 删 memory(SOUL 已写) / 升级 SOUL(memory 更细致) / 保留(细化案例,加 pointer)")

        # 3b(2026-08-05): SOUL 全文副本住在 commands/ 与 skills/ 的盲区。
        #   2026-08-05 审计发现 4-class Impact Analysis 表同时存在于 SOUL、commands/save-memory.md
        #   与 colar-agents/CLAUDE.md,三方各自声称权威(save-memory 甚至写明"别处出现全文副本即
        #   drift,删副本")——上面的 3 只扫 memory frontmatter,对命令/skill 目录结构性失明,
        #   所以这个活性冲突(照字面执行会去删 SOUL)长期没人发现。
        #   判据: 单文件命中 >=3 个 SOUL bold 短语 = 疑似搬运了整段,不是偶然用词重合。
        COPY_HITS_MIN = 3
        copy_scan = sorted(glob.glob(os.path.expanduser("~/Desktop/colar-agents/commands/*.md"))) \
                  + sorted(glob.glob(os.path.expanduser("~/.claude/skills/*/SKILL.md"))) \
                  + sorted(glob.glob(os.path.expanduser("~/Desktop/colar-agents/CLAUDE.md")))
        copies = []
        for f in copy_scan:
            body = read_text(f)
            if not body:
                continue
            # 只算"非引用式"命中：短语所在行若点名了 SOUL,那是 pointer 不是副本。
            # (2026-08-05 首跑即验: compile-doc.md 三处命中全带 "SOUL 铁律/SOUL 规则" 字样,
            #  属正确引用。不加这层过滤,检查一上线就是噪音,会被当红点通胀无视。)
            hit = []
            for p in phrases:
                for ln in body.splitlines():
                    if p.lower() in ln.lower() and "soul" not in ln.lower():
                        hit.append(p)
                        break
            if len(hit) >= COPY_HITS_MIN:
                shown = ", ".join("'%s'" % p for p in hit[:3])
                more = ("  等 %d 个" % len(hit)) if len(hit) > 3 else ""
                copies.append("  %s  命中 %d 个 SOUL 短语: %s%s"
                              % (f.replace(os.path.expanduser("~"), "~"), len(hit), shown, more))
        if copies:
            sections.append(
                "=== SOUL FULL-TEXT COPY (commands/ 或 skills/ 里疑似 SOUL 整段副本) ===\n"
                + "\n".join(copies) + "\n"
                + "  注: 多处持同一段全文 = 三方各自声称权威的温床,照字面执行会互删。\n"
                + "  → 决策: 选一处当权威留全文,其余改 pointer(SOUL 的定位是 axioms-only,通常权威不该在 SOUL)")

    # --- 4. Stale candidates (短 + 60d+ + 无视觉锚) ---
    ANCHORS = ("🔴", "⚠️", "🆕", "🚨", "🔄")
    stale = []
    for f in by_prefix["feedback"]:
        try:
            st = os.stat(f)
        except OSError:
            continue
        if st.st_size >= 1500 or (now - st.st_mtime) <= 60 * 86400:
            continue
        text = read_text(f)
        nlines = text.count("\n")
        if nlines >= 25:
            continue
        if any(a in text for a in ANCHORS):
            continue
        mtime = time.strftime("%Y-%m-%d", time.localtime(st.st_mtime))
        stale.append("  %s  %dL  %s" % (mtime, nlines, f))
    if stale:
        sections.append(
            "=== STALE CANDIDATES (短文件 + 60d+ 未改 + 无视觉锚 → archive 候选) ===\n"
            + "\n".join(sorted(stale)) + "\n"
            + "  注: 这是 advisory,不删。先 grep 验证无 active 引用再决定。")

    # --- 5. Index bloat: MEMORY.md 行数超阈值 ---
    index_text = read_text("MEMORY.md")
    index_lines = index_text.count("\n")
    try:
        maxlines = int(os.environ.get("INDEX_MAXLINES", "200"))
    except ValueError:
        maxlines = 200
    if index_lines > maxlines:
        sections.append(
            "=== INDEX BLOAT (MEMORY.md 超行数阈值) ===\n"
            + "  MEMORY.md: %d lines > %d 阈值\n" % (index_lines, maxlines)
            + "  注: 索引膨胀是内容腐烂同根因(SOUL Memory Discipline)。下沉冷条目到 *-index.md 子索引。")

    # --- 6. Hardcoded count drift ---
    count_hits = []
    total_content = sum(len(v) for v in by_prefix.values())
    # 6a. 本索引 MEMORY.md 的 "## Class (N files)" 段头 vs 实际 prefix 计数
    for m in re.finditer(r"^(##+\s*(.{0,60}?)\((\d+)\s*files?\))", index_text, re.M | re.I):
        header, label, claimed = m.group(1), m.group(2).lower(), int(m.group(3))
        for p in PREFIXES:
            if p in label:
                real = len(by_prefix[p])
                if claimed != real:
                    count_hits.append("  MEMORY.md: '%s' 声明 %d ≠ 实际 %s_*.md %d 个"
                                      % (header.strip(), claimed, p, real))
                break
    # 6b. 裸 home lane 转发索引的总数声明（如 "99 files, 4-class"）vs 4 类实际总和
    lane = os.environ.get("LANE_INDEX", "")
    if lane and os.path.isfile(lane):
        lane_text = read_text(lane)
        for m in re.finditer(r"(\d+)\s*files", lane_text):
            claimed = int(m.group(1))
            if claimed != total_content:
                count_hits.append("  %s: 声明 %d files ≠ 实际 4 类内容文件 %d 个"
                                  % (lane, claimed, total_content))
    if count_hits:
        sections.append(
            "=== HARDCODED COUNT DRIFT (索引写死的文件计数 ≠ 实际 ls 数) ===\n"
            + "\n".join(count_hits) + "\n"
            + "  注: 计数 drift 是索引腐烂早期信号。改成动态口径(ls | wc -l)或更新数字。")

    # --- 7. Unprefixed content files ---
    KNOWN_INFRA = {"MEMORY.md", "ARCHIVE.md", "BACKLOG.md", "README.md"}
    unprefixed = []
    for f in sorted(glob.glob("*.md")):
        if f in KNOWN_INFRA or f.endswith("-index.md"):
            continue
        if any(f.startswith(p + "_") for p in PREFIXES):
            continue
        unprefixed.append("  " + f)
    if unprefixed:
        sections.append(
            "=== UNPREFIXED CONTENT FILES (顶层无 user_/feedback_/project_/reference_ 前缀) ===\n"
            + "\n".join(unprefixed) + "\n"
            + "  注: 4-类前缀是索引/统计口径基础。改名归类,或确属 infra 则加进脚本 KNOWN_INFRA。")

    # --- 8. Expired next-actions in project_*.md ---
    next_pat = re.compile(r"下次\s*session|next\s+session", re.I)
    expired = []
    for f in by_prefix["project"]:
        try:
            st = os.stat(f)
        except OSError:
            continue
        if (now - st.st_mtime) <= 30 * 86400:
            continue
        if next_pat.search(read_text(f)):
            mtime = time.strftime("%Y-%m-%d", time.localtime(st.st_mtime))
            expired.append("  %s  (mtime %s)  %s" % ("30d+", mtime, f))
    # 8b(2026-08-05): 索引文件自身也会挂 next-action,且比正文腐烂得更久——
    #   MEMORY.md:137 那条 workplay next-action 被正文作废后仍在索引里挂了 30 天,
    #   全靠人工发现。索引行不看 mtime(索引天天被改,mtime 永远新鲜),改为:
    #   索引里出现 next-action 字样即报,因为动态 next-action 本就该进 BACKLOG 不进索引。
    for idx in index_files:
        for i, ln in enumerate(read_text(idx).splitlines(), 1):
            if next_pat.search(ln):
                expired.append("  索引行    %s:%d  %s" % (idx, i, ln.strip()[:80]))
    if expired:
        sections.append(
            "=== EXPIRED NEXT-ACTIONS (project_*.md 含 '下次 session' 且 30d+ 未改 / 索引挂 next-action) ===\n"
            + "\n".join(sorted(expired)) + "\n"
            + "  注: next-action 已过保鲜期 — 要么已做完(清掉该行),要么项目停滞(归档)。\n"
            + "      索引层的 next-action 一律该清: 动态任务进 BACKLOG.md,索引只描述文件是什么。")

    # --- 9. Hook mechanism claims vs settings.json 实态 ---
    # Why: 2026-08-05 审计发现 3 条腐烂全属此类且全部逃过既有 8 项检查——memory/SOUL 里
    #      "X hook 自动跑 Y.sh" 的断言从未被任何东西校验过。文本说 UserPromptSubmit+--rebase、
    #      实为 SessionStart+--ff-only；文本说 Stop hook 跑 drift-check.sh、实为 memory_drift_check.sh。
    #      后果比文档瑕疵严重：AI 据此以为语料已同步，实际整个 session 基于陈旧内容判断。
    settings_path = os.path.expanduser("~/.claude/settings.json")
    if os.path.isfile(settings_path):
        try:
            import json
            sdata = json.loads(read_text(settings_path))
            real_hooks = {}
            for ev, items in (sdata.get("hooks") or {}).items():
                found = set()
                for it in items:
                    for h in it.get("hooks", []):
                        found.update(re.findall(r"([a-z_0-9]+\.sh)", h.get("command", "")))
                real_hooks[ev] = found
            every_hooked = set()
            for v in real_hooks.values():
                every_hooked |= v

            EVENTS = ("UserPromptSubmit", "SessionStart", "SubagentStop", "PreToolUse",
                      "PostToolUse", "PreCompact", "Notification", "Stop")
            # 否定/存疑语气的行是"正确记录了它没接线",不该报
            NEG = ("不在", "未接", "手动", "NOT IMPLEMENTED", "从未", "没有", "无 hook",
                   "别当", "勿", "已放弃", "不是", "≠", "曾经")
            claims = []
            targets = [(f, f) for f in sorted(glob.glob("*.md"))]
            if soul_path and os.path.isfile(soul_path):
                targets.append((soul_path, "SOUL"))
            for path, label in targets:
                for i, ln in enumerate(read_text(path).splitlines(), 1):
                    if "hook" not in ln.lower():
                        continue
                    if any(n in ln for n in NEG):
                        continue
                    evs = [e for e in EVENTS if e in ln]
                    if not evs:
                        continue
                    for sh in sorted(set(re.findall(r"([a-z_0-9]+\.sh)", ln))):
                        for ev in evs:
                            if sh in real_hooks.get(ev, set()):
                                continue
                            why = ("该事件下没有它(它注册在 %s)" % ", ".join(
                                sorted(e for e in real_hooks if sh in real_hooks[e]))
                                if sh in every_hooked else "settings.json 里任何 hook 都没有它")
                            claims.append("  %s:%d  声称 %s 跑 %s — %s" % (label, i, ev, sh, why))
            if claims:
                sections.append(
                    "=== HOOK CLAIM DRIFT (文本声称的 hook 接线 ≠ settings.json 实态) ===\n"
                    + "\n".join(sorted(set(claims))) + "\n"
                    + "  注: 机制断言腐烂比文档瑕疵严重 — AI 会据此以为某保障在跑而放弃自查。\n"
                    + "      核对 settings.json 后改文本; 确属'记录它没接线'的否定句会被自动跳过。")
        except Exception:
            pass

    # --- Counts + 输出契约 ---
    fb, pj, us, rf = (len(by_prefix[p]) for p in ("feedback", "project", "user", "reference"))
    tr = len(glob.glob("transcripts/*.md"))

    if not sections:
        print("✓ memory drift clean — feedback:%d / project:%d / user:%d / reference:%d / transcripts:%d · MEMORY.md:%dL"
              % (fb, pj, us, rf, tr, index_lines))
    else:
        print("\n\n".join(sections))
        print()
        print("=== COUNTS ===")
        print("  feedback:%d / project:%d / user:%d / reference:%d / transcripts:%d" % (fb, pj, us, rf, tr))
        print("  MEMORY.md: %d lines (%d advisory limit)" % (index_lines, maxlines))

try:
    main()
except Exception as e:
    # fail-open：自检脚本自身出错绝不阻断 Stop hook
    print("memory_drift_check internal error (fail-open): %r" % (e,), file=sys.stderr)
sys.exit(0)
PYEOF

exit 0
