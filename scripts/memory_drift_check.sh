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
#           现全部检查合并进单次 python3 内存扫描（第 12 项另起 3 个本地 git 子进程，无网络）。
#
# Errors:   每项检查各自 try 隔离。某项自身出错 → 打一个 "=== INTERNAL ERROR in <check> ===" 段到
#           **stdout**（Stop hook 把 stderr 丢进 /dev/null，打 stderr 等于一个 bug 让全部检查静默、
#           看起来像 clean），其余检查照常跑，exit 仍为 0。
#           测试用故障注入：DRIFT_CHECK_FAULT=<check 名> 让该项抛异常（见 scripts/hooks/tests/）。
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
#  10. Unresolved [[ ]] links (语料顶层 *.md 正文里的 [[name]] 对不上任何 name:/文件名 → 软提示,
#      因为 memory 约定允许指向待写的 memory; 已确认待写的进 allowlist 静默,只让新的冒头) +
#      allowlist 自身的陈旧条目（已能解析 / 已无引用 → 该删）
#  11. SOUL date-stamp creep (SOUL 含 YYYY-MM 的行数 > SOUL_DATE_LINES_MAX → SOUL 该放 axioms 不放事件)
#  12. Corpus backup drift (只读本地 git 状态,不 fetch: 3 天前的未跟踪文件 / 3 天前就有的未推送提交)

set -u

# 路径可用 env 覆盖（默认生产路径；覆盖仅供测试/沙箱）
export MEMORY_DIR="${MEMORY_DIR:-${HOME}/.claude/projects/-Users-colar-Desktop-colar-agents/memory}"
export SOUL_PATH="${SOUL_PATH:-${HOME}/.claude/CLAUDE.md}"
# 裸 home lane 的转发索引（含 "99 files" 式总数声明）
export LANE_INDEX="${LANE_INDEX:-${HOME}/.claude/projects/-Users-colar/memory/MEMORY.md}"
# MEMORY.md 行数 advisory 阈值（原 COUNTS 注释即 "200 truncate limit"）
export INDEX_MAXLINES="${INDEX_MAXLINES:-200}"
# 第 10 项的 [[ ]] allowlist（待写 memory 的链接）。住私有语料库：条目本身就是 memory 名。文件缺失 = 空 allowlist
export LINK_ALLOWLIST="${LINK_ALLOWLIST:-${MEMORY_DIR}/memory-link-allowlist.txt}"
# 第 9 项读的 hook 接线真相源；第 3b 项扫的 commands/CLAUDE.md 所在仓与 skills 目录
export SETTINGS_PATH="${SETTINGS_PATH:-${HOME}/.claude/settings.json}"
export AGENTS_DIR="${AGENTS_DIR:-${HOME}/Desktop/colar-agents}"
export SKILLS_DIR="${SKILLS_DIR:-${HOME}/.claude/skills}"

[ -d "$MEMORY_DIR" ] || { echo "memory dir not found: $MEMORY_DIR" >&2; exit 0; }
[ -f "$MEMORY_DIR/MEMORY.md" ] || { echo "MEMORY.md not found: $MEMORY_DIR/MEMORY.md" >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found — drift check skipped" >&2; exit 0; }

# fail-open：每项检查各自 try 住（错误打到 stdout），bash 层再兜一层 || true
python3 <<'PYEOF' || true
import glob, json, os, re, subprocess, sys, time

PREFIXES = ("feedback", "project", "user", "reference")


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


class Ctx:
    """所有检查共享的只读事实。构造失败 = setup 错误，由 run() 单独报。"""

    def __init__(self):
        self.mem_dir = os.environ["MEMORY_DIR"]
        os.chdir(self.mem_dir)
        self.now = time.time()
        self.by_prefix = {p: sorted(glob.glob(p + "_*.md")) for p in PREFIXES}
        self.actual = sorted(set(f for v in self.by_prefix.values() for f in v))
        # Tiered index: MEMORY.md 是热索引, 冷条目下沉到 *-index.md 子索引 + transcripts/INDEX.md
        self.index_files = ["MEMORY.md"] + sorted(glob.glob("*-index.md"))
        if os.path.isfile("transcripts/INDEX.md"):
            self.index_files.append("transcripts/INDEX.md")
        # 字符类必须含 "-"：SOUL 的时间锚点纪律要求 time-bound 文件带绝对日期
        # (project_<topic>_YYYY-MM-DD.md)，而没有 "-" 时正则会在第一个
        # 连字符处截断，于是「索引里明明有」被误报成 UNINDEXED。两个失效方向都坏：
        # 误报是噪音（会训练人忽略本检查），漏报则让指向带日期文件的死链永远查不出来。
        ref_pat = re.compile(r"(?:feedback|project|user|reference)_[a-z_0-9-]+\.md")
        self.indexed = set()
        for f in self.index_files:
            self.indexed.update(ref_pat.findall(read_text(f)))
        self.index_text = read_text("MEMORY.md")
        self.index_lines = self.index_text.count("\n")
        try:
            self.maxlines = int(os.environ.get("INDEX_MAXLINES", "200"))
        except ValueError:
            self.maxlines = 200
        self.soul_path = os.environ.get("SOUL_PATH", "")
        self.soul_text = read_text(self.soul_path) if self.soul_path and os.path.isfile(self.soul_path) else ""


# --- 1. Unindexed ---
def check_unindexed(c):
    unindexed = [f for f in c.actual if f not in c.indexed]
    if not unindexed:
        return []
    lines = ["=== UNINDEXED (dir 有 / MEMORY.md 没指) ==="]
    for f in unindexed:
        name, desc = frontmatter_name_desc(f)
        lines.append("  " + f)
        if name:
            lines.append("    name: " + name)
        if desc:
            lines.append("    desc: " + desc)
    return ["\n".join(lines)]


# --- 2. Dead links ---
def check_dead_links(c):
    dead = sorted(c.indexed - set(c.actual))
    if not dead:
        return []
    return ["=== DEAD LINKS (MEMORY.md 指了 / dir 没文件) ===\n" + "\n".join("  " + f for f in dead)]


def soul_phrases(c):
    # 提取 **X** bold 短语,长度 ≥ 4 char(过滤单字符 / 短虚词),与旧版口径一致
    return sorted(set(re.findall(r"\*\*([^*]{4,40})\*\*", c.soul_text)))


# --- 3. SOUL ↔ memory content overlap（单次内存扫描，无进程 spawn） ---
def check_soul_overlap(c):
    if not c.soul_text:
        return []
    phrases = soul_phrases(c)
    overlap = []
    for f in c.by_prefix["feedback"]:
        # SOUL 已经用文件名指过来的，关系是「细化」且动作已完成（4-class 表：写 + 加 pointer），
        # 不是候选重复 —— 而一个细化类 memory **本来就该**以它所细化的 SOUL axiom 命名，
        # 于是旧判据恰好在**正确状态**上永久报警。实例：SOUL 里某一条 axiom
        # 写着「详见 feedback_<topic>.md」，却被逐 session 报成候选重复。
        # 检查仍对「frontmatter 抄了 SOUL 短语、但 SOUL 没指回来」的真冗余生效。
        if f in c.soul_text:
            continue
        name, desc = frontmatter_name_desc(f)
        meta = (name + "\n" + desc).lower()
        if not meta.strip():
            continue
        for phrase in phrases:
            if phrase.lower() in meta:
                overlap.append("  %s  ←→ SOUL: '%s'" % (f, phrase))
    if not overlap:
        return []
    return ["=== SOUL ↔ MEMORY OVERLAP (memory frontmatter 含 SOUL bold axiom 短语) ===\n"
            + "\n".join(overlap) + "\n"
            + "  注: 候选重复。SOUL 已 cover 该 axiom,memory 可能多余。\n"
            + "  → 决策: 删 memory(SOUL 已写) / 升级 SOUL(memory 更细致) / 保留(细化案例,加 pointer)"]


# --- 3b(2026-08-05): SOUL 全文副本住在 commands/ 与 skills/ 的盲区 ---
#   2026-08-05 审计发现 4-class Impact Analysis 表同时存在于 SOUL、commands/save-memory.md
#   与 colar-agents/CLAUDE.md,三方各自声称权威(save-memory 甚至写明"别处出现全文副本即
#   drift,删副本")——上面的 3 只扫 memory frontmatter,对命令/skill 目录结构性失明,
#   所以这个活性冲突(照字面执行会去删 SOUL)长期没人发现。
#   判据: 单文件命中 >=3 个 SOUL bold 短语 = 疑似搬运了整段,不是偶然用词重合。
def check_soul_copies(c):
    if not c.soul_text:
        return []
    COPY_HITS_MIN = 3
    phrases = soul_phrases(c)
    agents_dir = os.environ.get("AGENTS_DIR", "")
    skills_dir = os.environ.get("SKILLS_DIR", "")
    copy_scan = sorted(glob.glob(os.path.join(agents_dir, "commands", "*.md"))) \
        + sorted(glob.glob(os.path.join(skills_dir, "*", "SKILL.md"))) \
        + sorted(glob.glob(os.path.join(agents_dir, "CLAUDE.md")))
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
    if not copies:
        return []
    return ["=== SOUL FULL-TEXT COPY (commands/ 或 skills/ 里疑似 SOUL 整段副本) ===\n"
            + "\n".join(copies) + "\n"
            + "  注: 多处持同一段全文 = 三方各自声称权威的温床,照字面执行会互删。\n"
            + "  → 决策: 选一处当权威留全文,其余改 pointer(SOUL 的定位是 axioms-only,通常权威不该在 SOUL)"]


# --- 4. Stale candidates (短 + 60d+ + 无视觉锚) ---
def check_stale(c):
    ANCHORS = ("🔴", "⚠️", "🆕", "🚨", "🔄")
    stale = []
    for f in c.by_prefix["feedback"]:
        try:
            st = os.stat(f)
        except OSError:
            continue
        if st.st_size >= 1500 or (c.now - st.st_mtime) <= 60 * 86400:
            continue
        text = read_text(f)
        nlines = text.count("\n")
        if nlines >= 25:
            continue
        if any(a in text for a in ANCHORS):
            continue
        mtime = time.strftime("%Y-%m-%d", time.localtime(st.st_mtime))
        stale.append("  %s  %dL  %s" % (mtime, nlines, f))
    if not stale:
        return []
    return ["=== STALE CANDIDATES (短文件 + 60d+ 未改 + 无视觉锚 → archive 候选) ===\n"
            + "\n".join(sorted(stale)) + "\n"
            + "  注: 这是 advisory,不删。先 grep 验证无 active 引用再决定。"]


# --- 5. Index bloat: MEMORY.md 行数超阈值 ---
def check_index_bloat(c):
    if c.index_lines <= c.maxlines:
        return []
    return ["=== INDEX BLOAT (MEMORY.md 超行数阈值) ===\n"
            + "  MEMORY.md: %d lines > %d 阈值\n" % (c.index_lines, c.maxlines)
            + "  注: 索引膨胀是内容腐烂同根因(SOUL Memory Discipline)。下沉冷条目到 *-index.md 子索引。"]


# --- 6. Hardcoded count drift ---
def check_counts(c):
    count_hits = []
    total_content = sum(len(v) for v in c.by_prefix.values())
    # 6a. 本索引 MEMORY.md 的 "## Class (N files)" 段头 vs 实际 prefix 计数
    for m in re.finditer(r"^(##+\s*(.{0,60}?)\((\d+)\s*files?\))", c.index_text, re.M | re.I):
        header, label, claimed = m.group(1), m.group(2).lower(), int(m.group(3))
        for p in PREFIXES:
            if p in label:
                real = len(c.by_prefix[p])
                if claimed != real:
                    count_hits.append("  MEMORY.md: '%s' 声明 %d ≠ 实际 %s_*.md %d 个"
                                      % (header.strip(), claimed, p, real))
                break
    # 6b. 裸 home lane 转发索引的总数声明（如 "99 files, 4-class"）vs 4 类实际总和
    lane = os.environ.get("LANE_INDEX", "")
    if lane and os.path.isfile(lane):
        for m in re.finditer(r"(\d+)\s*files", read_text(lane)):
            claimed = int(m.group(1))
            if claimed != total_content:
                count_hits.append("  %s: 声明 %d files ≠ 实际 4 类内容文件 %d 个"
                                  % (lane, claimed, total_content))
    if not count_hits:
        return []
    return ["=== HARDCODED COUNT DRIFT (索引写死的文件计数 ≠ 实际 ls 数) ===\n"
            + "\n".join(count_hits) + "\n"
            + "  注: 计数 drift 是索引腐烂早期信号。改成动态口径(ls | wc -l)或更新数字。"]


# --- 7. Unprefixed content files ---
def check_unprefixed(c):
    # BACKLOG.archive.md 与 BACKLOG.md 同族（前者是后者的归档），同属 infra 而非 memory 内容。
    KNOWN_INFRA = {"MEMORY.md", "ARCHIVE.md", "BACKLOG.md", "BACKLOG.archive.md", "README.md"}
    unprefixed = []
    for f in sorted(glob.glob("*.md")):
        if f in KNOWN_INFRA or f.endswith("-index.md"):
            continue
        if any(f.startswith(p + "_") for p in PREFIXES):
            continue
        unprefixed.append("  " + f)
    if not unprefixed:
        return []
    return ["=== UNPREFIXED CONTENT FILES (顶层无 user_/feedback_/project_/reference_ 前缀) ===\n"
            + "\n".join(unprefixed) + "\n"
            + "  注: 4-类前缀是索引/统计口径基础。改名归类,或确属 infra 则加进脚本 KNOWN_INFRA。"]


# --- 8. Expired next-actions in project_*.md ---
def check_next_actions(c):
    next_pat = re.compile(r"下次\s*session|next\s+session", re.I)
    expired = []
    for f in c.by_prefix["project"]:
        try:
            st = os.stat(f)
        except OSError:
            continue
        if (c.now - st.st_mtime) <= 30 * 86400:
            continue
        if next_pat.search(read_text(f)):
            mtime = time.strftime("%Y-%m-%d", time.localtime(st.st_mtime))
            expired.append("  %s  (mtime %s)  %s" % ("30d+", mtime, f))
    # 8b(2026-08-05): 索引文件自身也会挂 next-action,且比正文腐烂得更久——
    #   MEMORY.md:137 那条 workplay next-action 被正文作废后仍在索引里挂了 30 天,
    #   全靠人工发现。索引行不看 mtime(索引天天被改,mtime 永远新鲜),改为:
    #   索引里出现 next-action 字样即报,因为动态 next-action 本就该进 BACKLOG 不进索引。
    for idx in c.index_files:
        for i, ln in enumerate(read_text(idx).splitlines(), 1):
            if next_pat.search(ln):
                expired.append("  索引行    %s:%d  %s" % (idx, i, ln.strip()[:80]))
    if not expired:
        return []
    return ["=== EXPIRED NEXT-ACTIONS (project_*.md 含 '下次 session' 且 30d+ 未改 / 索引挂 next-action) ===\n"
            + "\n".join(sorted(expired)) + "\n"
            + "  注: next-action 已过保鲜期 — 要么已做完(清掉该行),要么项目停滞(归档)。\n"
            + "      索引层的 next-action 一律该清: 动态任务进 BACKLOG.md,索引只描述文件是什么。"]


# --- 9. Hook mechanism claims vs settings.json 实态 ---
# Why: 2026-08-05 审计发现 3 条腐烂全属此类且全部逃过既有 8 项检查——memory/SOUL 里
#      "X hook 自动跑 Y.sh" 的断言从未被任何东西校验过。文本说 UserPromptSubmit+--rebase、
#      实为 SessionStart+--ff-only；文本说 Stop hook 跑 drift-check.sh、实为 memory_drift_check.sh。
#      后果比文档瑕疵严重：AI 据此以为语料已同步，实际整个 session 基于陈旧内容判断。
def check_hook_claims(c):
    settings_path = os.environ.get("SETTINGS_PATH", "")
    if not settings_path or not os.path.isfile(settings_path):
        return []
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
    if c.soul_text:
        targets.append((c.soul_path, "SOUL"))
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
    if not claims:
        return []
    return ["=== HOOK CLAIM DRIFT (文本声称的 hook 接线 ≠ settings.json 实态) ===\n"
            + "\n".join(sorted(set(claims))) + "\n"
            + "  注: 机制断言腐烂比文档瑕疵严重 — AI 会据此以为某保障在跑而放弃自查。\n"
            + "      核对 settings.json 后改文本; 确属'记录它没接线'的否定句会被自动跳过。"]


# --- 10. 未解析 [[ ]] 链接（软检查，刻意不叫 "dead"）+ allowlist 陈旧条目 ---
# Why: Claude Code 的 memory 约定允许 [[name]] 指向尚未写的 memory，所以「未解析」≠ 错；
#      但改名 / 合并 / 删除后留下的悬空链接与之长得一模一样，机器分不开，只能列出来让人判。
#      已确认「待写」的进 LINK_ALLOWLIST 静默，于是冒头的基本只剩新出现的改名遗留。
# 解析口径（任一命中即算解析）：语料内任一 md 的 frontmatter name、文件名 stem、去掉 4 类前缀的 stem。
#      所以 [[foo]] 能解析到 project_foo.md；但链接侧**不剥前缀**——[[feedback-foo]] 解析不到
#      project_foo.md，那正是跨类改名的遗留，必须报出来。两侧都做 kebab/snake 归一（- 与空白 → _，小写，去 .md）。
#      allowlist 条目同样不剥前缀，按链接原样写。
UNRESOLVED_SHOW_MAX = 40


def norm_key(s):
    s = s.strip().strip("'\"").lower()
    if s.endswith(".md"):
        s = s[:-3]
    return re.sub(r"[\s\-]+", "_", s)


def strip_prefix(key):
    for p in PREFIXES:
        if key.startswith(p + "_"):
            return key[len(p) + 1:]
    return key


def check_links(c):
    resolvable = set()
    for path in glob.glob("**/*.md", recursive=True):
        stem_key = norm_key(os.path.basename(path))
        resolvable.add(stem_key)
        resolvable.add(strip_prefix(stem_key))
        name, _ = frontmatter_name_desc(path)
        if name:
            resolvable.add(norm_key(name))

    allow_path = os.environ.get("LINK_ALLOWLIST", "")
    allow = []  # [(原文, key)]
    for ln in read_text(allow_path).splitlines():
        ln = ln.strip()
        if ln and not ln.startswith("#"):
            allow.append((ln, norm_key(ln)))
    allow_keys = set(k for _, k in allow)

    link_pat = re.compile(r"\[\[([^\[\]\n]+?)\]\]")
    inline_code_pat = re.compile(r"`[^`\n]*`")
    referenced = set()
    unresolved = []
    for f in sorted(glob.glob("*.md")):
        text = read_text(f)
        if "[[" not in text:
            continue
        seen = set()
        in_fence = False
        for i, ln in enumerate(text.splitlines(), 1):
            if ln.lstrip().startswith("```"):
                in_fence = not in_fence
                continue
            if in_fence or "[[" not in ln:
                continue
            for raw in link_pat.findall(inline_code_pat.sub("", ln)):
                target = raw.split("|", 1)[0].split("#", 1)[0].strip()
                key = norm_key(target)
                if not key or key in seen:
                    continue
                seen.add(key)
                referenced.add(key)
                if key in resolvable or key in allow_keys:
                    continue
                unresolved.append("  %s:%d  [[%s]]" % (f, i, target))

    out = []
    if unresolved:
        shown = unresolved[:UNRESOLVED_SHOW_MAX]
        if len(unresolved) > UNRESOLVED_SHOW_MAX:
            shown.append("  … 另 %d 条未列出" % (len(unresolved) - UNRESOLVED_SHOW_MAX))
        out.append(
            "=== UNRESOLVED [[ ]] LINKS (%d 条) ===\n" % len(unresolved)
            + "  未解析 [[ ]]（可能是待写的 memory——约定允许——也可能是改名遗留）\n"
            + "\n".join(shown) + "\n"
            + "  注: 改名遗留 → 改成新名；确属待写 → 加进语料库 memory-link-allowlist.txt（写完后再删掉该行）。")

    stale_allow = []
    for raw, key in allow:
        if key in resolvable:
            stale_allow.append("  %s  — 已能解析（memory 已写）→ 删掉该行" % raw)
        elif key not in referenced:
            stale_allow.append("  %s  — 已无任何 [[ ]] 引用它 → 删掉该行" % raw)
    if stale_allow:
        out.append(
            "=== STALE ALLOWLIST ENTRIES (%s 里该删的行) ===\n" % os.path.basename(allow_path)
            + "\n".join(stale_allow) + "\n"
            + "  注: 陈旧条目会把将来同名的改名遗留一起静默掉，所以要删。")
    return out


# --- 11. SOUL 日期戳膨胀 ---
# Why: SOUL 契约是 axioms-only（"6 个月后会错的不进 SOUL"）。带日期的行几乎都是事件 / 审计读数 /
#      拍板记录，属于 memory 或 eval/BASELINE.md；日期行数上涨 = SOUL 在长回日志。
# 口径: 独立的 YYYY-MM（月份 01-12）。re.ASCII 让中文字符算非单词字符，"（2026-07审计" 这种紧贴中文
#      的也能命中；嵌在文件名里的（"_2026-08-10.md"，前面是 "_"）不算——那是指针不是日期戳。
SOUL_DATE_LINES_MAX = 5


def check_soul_dates(c):
    if not c.soul_text:
        return []
    date_pat = re.compile(r"\b20\d{2}-(0[1-9]|1[0-2])\b", re.ASCII)
    dated = [(i, ln.strip()) for i, ln in enumerate(c.soul_text.splitlines(), 1) if date_pat.search(ln)]
    if len(dated) <= SOUL_DATE_LINES_MAX:
        return []
    sample = "\n".join("    L%d  %s" % (i, ln[:70]) for i, ln in dated[:8])
    more = ("\n    … 另 %d 行" % (len(dated) - 8)) if len(dated) > 8 else ""
    return ["=== SOUL DATE-STAMP CREEP (SOUL 含日期的行 %d > 阈值 %d) ===\n" % (len(dated), SOUL_DATE_LINES_MAX)
            + sample + more + "\n"
            + "  注: SOUL 只放 axioms。日期属于事件 / 读数 / 拍板记录 → 迁去 memory 或 eval/BASELINE.md，SOUL 只留规则。"]


# --- 12. 语料备份漂移（只读本地 git 状态） ---
# Why: 语料的备份靠 git push。没进 git 的文件、没推上去的提交，在本机坏盘 / 误删时就是孤本——
#      而这类状态不会自己报错，只会静静地老化。只看本地状态：Stop hook 里不能联网（会卡、会慢），
#      所以 @{u} 用的是本地的 remote-tracking ref，不 fetch。没有 upstream / 不是 git 仓 → 静默跳过。
BACKUP_STALE_DAYS = 3
BACKUP_SHOW_MAX = 20


def git_out(args):
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0")
    r = subprocess.run(["git"] + args, capture_output=True, text=True, timeout=5, env=env)
    return r.returncode, r.stdout


def check_backup(c):
    rc, inside = git_out(["rev-parse", "--is-inside-work-tree"])
    if rc != 0 or inside.strip() != "true":
        return []
    cutoff = c.now - BACKUP_STALE_DAYS * 86400
    lines = []

    # (a) 未跟踪且 3 天前就在的文件（ignored 的不算）
    rc, out = git_out(["ls-files", "--others", "--exclude-standard", "-z"])
    old_untracked = []
    if rc == 0:
        for f in sorted(p for p in out.split("\0") if p):
            try:
                mt = os.stat(f).st_mtime
            except OSError:
                continue
            if mt < cutoff:
                old_untracked.append("    %s  %s" % (time.strftime("%Y-%m-%d", time.localtime(mt)), f))
    if old_untracked:
        lines.append("  未跟踪文件 %d 个（mtime 早于 %d 天前，从未进 git = 没有备份）:"
                     % (len(old_untracked), BACKUP_STALE_DAYS))
        lines += old_untracked[:BACKUP_SHOW_MAX]
        if len(old_untracked) > BACKUP_SHOW_MAX:
            lines.append("    … 另 %d 个" % (len(old_untracked) - BACKUP_SHOW_MAX))

    # (b) 不在 @{u} 上的本地提交，且最老的一个早于 3 天前
    rc, _ = git_out(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
    if rc == 0:
        rc, out = git_out(["log", "--format=%ct", "@{u}..HEAD"])
        stamps = [int(x) for x in out.split()] if rc == 0 else []
        if stamps and min(stamps) < cutoff:
            lines.append("  未推送提交 %d 个，最老的提交于 %s（超过 %d 天没推 = 远端备份落后）"
                         % (len(stamps), time.strftime("%Y-%m-%d", time.localtime(min(stamps))),
                            BACKUP_STALE_DAYS))
    if not lines:
        return []
    return ["=== CORPUS BACKUP DRIFT (本地 git 状态，未 fetch) ===\n" + "\n".join(lines) + "\n"
            + "  注: 该提交的提交、该推的推（push 由 Colar 显式确认）；确属不该进库的加 .gitignore。"]


CHECKS = [
    ("unindexed", check_unindexed),
    ("dead_links", check_dead_links),
    ("soul_overlap", check_soul_overlap),
    ("soul_copies", check_soul_copies),
    ("stale", check_stale),
    ("index_bloat", check_index_bloat),
    ("counts", check_counts),
    ("unprefixed", check_unprefixed),
    ("next_actions", check_next_actions),
    ("hook_claims", check_hook_claims),
    ("links", check_links),
    ("soul_dates", check_soul_dates),
    ("backup", check_backup),
]


def internal_error(label, e):
    return ("=== INTERNAL ERROR in %s ===\n  %s: %s\n"
            "  注: 本项检查自身出错已跳过（其余照跑）。这不是 clean —— 修脚本。" % (label, type(e).__name__, e))


def run():
    try:
        c = Ctx()
    except Exception as e:
        print(internal_error("setup", e))
        return
    fault = os.environ.get("DRIFT_CHECK_FAULT", "")
    sections = []
    for label, fn in CHECKS:
        try:
            if fault == label:
                raise RuntimeError("injected fault (DRIFT_CHECK_FAULT)")
            sections.extend(fn(c) or [])
        except Exception as e:
            sections.append(internal_error(label, e))

    # --- Counts + 输出契约 ---
    fb, pj, us, rf = (len(c.by_prefix[p]) for p in PREFIXES)
    tr = len(glob.glob("transcripts/*.md"))
    if not sections:
        print("✓ memory drift clean — feedback:%d / project:%d / user:%d / reference:%d / transcripts:%d · MEMORY.md:%dL"
              % (fb, pj, us, rf, tr, c.index_lines))
    else:
        print("\n\n".join(sections))
        print()
        print("=== COUNTS ===")
        print("  feedback:%d / project:%d / user:%d / reference:%d / transcripts:%d" % (fb, pj, us, rf, tr))
        print("  MEMORY.md: %d lines (%d advisory limit)" % (c.index_lines, c.maxlines))


try:
    run()
except Exception as e:
    # 兜底的兜底：错误打 stdout（stderr 会被 Stop hook 丢掉）
    print(internal_error("runner", e))
sys.exit(0)
PYEOF

exit 0
