#!/usr/bin/env bash
# SessionStart hook: 把 backlog 里当前 project 的未完成任务注入开场 context
#
# 设计要点（2026-07-08 更新：lane key 与 persist 同步为 git repo root）:
#   - 从 stdin JSON 拿 cwd
#   - lane key = git repo root（非裸 cwd）→ 从子目录启动也能对上项目段；非 repo 归 misc
#   - 只注入当前 lane 段的 open 项 + 其他 lane 的 open 计数（一行摘要）
#   - stdout 会被 Claude Code 当 context 注入；无 open 项 → 静默
#
# 2026-07-08 方案 A（白名单分流 + 修 lane 分裂）:
#   - 两处都读并合并：聚合仓 ~/Desktop/colar-memory/BACKLOG.md
#     + 各机密 lane 项目内 <repo>/.claude/BACKLOG.local.md（不 push 的机密项）
#   - 当前 lane 归属改前缀匹配：cwd 以某 lane 路径为前缀即命中（修子目录/裸 home 分裂）
#
# 2026-07-10 衰减与折叠升级（修开场注入 70+ 条污染 context）:
#   - 解析 persist 落的 <!--t:YYYY-MM-DD--> last-touched 戳（显示时剥掉）
#   - >COLD_DAYS(14) 天未触碰 → 不逐条注入,折叠成一行计数
#   - 活跃项超 MAX_LIST(20) 条 → 只列前 20,余量折叠计数
#   - dedup 与 persist 同款归一化 key（全角→半角+去空白）,防标点变体重复注入
#   ⚠️ <!--t:--> 格式/_dedup_key 与 persist.sh 必须同步改
set +e
INPUT=$(head -c 65536)
export BACKLOG="$HOME/Desktop/colar-memory/BACKLOG.md"
export CONF_LANES="$HOME/.claude/backlog_confidential_lanes.txt"
export HOOK_INPUT="$INPUT"

# 聚合仓不存在也别急着退 —— 机密 lane 的 .local.md 可能仍有内容要注入

python3 -c '
import os, sys, json, signal, re, subprocess, datetime
signal.signal(signal.SIGALRM, lambda *a: sys.exit(0))
signal.alarm(6)

COLD_DAYS = 14   # 超过这个天数未触碰的项折叠成计数
MAX_LIST  = 20   # 活跃项最多逐条注入这么多,余量折叠

# 与 persist.sh 同款归一化（⚠️ 两处同步改;python 包在 bash 单引号里,禁用 ASCII 引号字符）
_FW = str.maketrans("（）：，、；！？【】－～", "():,,;!?[]-~")
def _dedup_key(s):
    # STEP2c(2026-07-17): 与 persist.sh 的 _dedup_key(_norm(...)) 逐字节等价(已实证全量 237 项 0 mismatch)。
    #   ⚠️ STEP3 provenance 要跨 recall/persist 比对同一 key,两侧归一化必须一致——改一侧必同步改另一侧。
    #   对齐点:剥行首 checkbox(persist 只对 content 建 key,不含 "- [ ]") + strip _(in progress)_ + 空白折叠。
    s = re.sub(r"<!--t:\d{4}-\d{2}-\d{2}-->", "", s or "")
    s = re.sub(r"^- \[[ xX]\]\s*", "", s.strip())        # 剥行首 checkbox
    s = re.sub(r"\s*_\(in progress\)_\s*$", "", s)        # 对齐 persist._norm 的 in-progress strip
    s = re.sub(r"\s+", " ", s).strip()                    # 对齐 persist._norm 的空白折叠
    s = s.translate(_FW)
    return re.sub(r"\s+", "", s).casefold()

try:
    d = json.loads(os.environ.get("HOOK_INPUT", "{}"))
except Exception:
    d = {}
cwd = (d.get("cwd", "") or os.getcwd()).rstrip("/")

def lane_key(path):
    try:
        r = subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"],
                           capture_output=True, text=True, timeout=2)
        root = (r.stdout or "").strip()
        # STEP2a(2026-07-17): git root 恰为 $HOME → 判 misc,不当 project lane。
        #   裸 home 不是项目;若 ~ 某天被 git init 或嵌进某 repo,别把整个 home 当一个 lane 吞掉子项目。
        #   ⚠️ 与 persist.sh:lane_key 同步改(两文件同一归属契约)。
        if r.returncode == 0 and root and root != os.path.expanduser("~"):
            return root, os.path.basename(root)
    except Exception:
        pass
    return "misc:" + path, "misc(" + (os.path.basename(path) or path) + ")"

cur_lane, cur_name = lane_key(cwd)

# --- 方案 A：机密 lane 白名单（前缀匹配），用于「两处都读」+ 前缀归属 ---
# ⚠️ 改此逻辑（_canon / _load_conf_lanes / _under_prefix / 前缀归属）必须
#    persist.sh 与 recall.sh 两处同步 —— persist 落 A、recall 找 B 就丢件。
def _canon(p):
    # 归一路径：realpath 解 symlink（macOS /tmp -> /private/tmp 之类）+ 去尾 /
    # 失败抛异常，交给调用方按 fail-closed 处理（不再吞成裸路径 fail-open）。
    return os.path.realpath(p).rstrip("/")

def _load_conf_lanes():
    # 三态返回（与 persist.sh 同步）：
    #   list（可为空 list）= 成功；None = 不可信来源
    # 不可信来源：CONF_LANES env 未设/空串 · 文件不存在 · 不可读 · 编码/解析/归一异常
    conf_path = os.environ.get("CONF_LANES", "") or ""
    if not conf_path.strip():
        return None
    try:
        with open(conf_path, encoding="utf-8") as fh:
            raw = fh.readlines()
    except FileNotFoundError:
        return None
    except Exception:
        return None
    prefixes = []
    try:
        for ln in raw:
            ln = ln.strip()
            if not ln or ln.startswith("#"):
                continue
            prefixes.append(_canon(ln))
    except Exception:
        return None
    return prefixes

def _under_prefix(path, prefix):
    return path == prefix or path.startswith(prefix + "/")

CONF_PREFIXES = _load_conf_lanes()  # None = 不可信白名单
# recall 侧：白名单不可信时，一律不读任何机密 lane 的 .local.md（宁可少注入，
# 不冒把机密段当聚合段处理的险）。用空 list 走后续逻辑即「无机密 lane 可读」。
CONF_SAFE = CONF_PREFIXES if CONF_PREFIXES is not None else []

# 先 pull colar-memory 再读，解 SessionStart 时序竞态。慢/离线/失败 → 读本地，不阻塞开场。
try:
    subprocess.run(["git", "-C", os.path.expanduser("~/Desktop/colar-memory"), "pull", "--quiet"],
                   timeout=3, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
except Exception:
    pass

def _read(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except Exception:
        return ""

# 两处都读，但保留 provenance：
#   聚合仓（非机密，会 push）→ 段标记 conf_source=None
#   每个机密 lane 的 .local.md → 段标记 conf_source=<该机密前缀>
# P0-2：非当前 session 命中的机密 lane 段，既不注入也不计数（连 basename 都不暴露）。
SEC_RE = r"<!-- project:(.*?) -->(.*?)<!-- /project -->"

# 每个元素：(lane_key, body, conf_source)  conf_source=None 表示来自聚合仓
tagged_secs = []

agg_text = _read(os.environ["BACKLOG"])
if agg_text:
    for key, body in re.findall(SEC_RE, agg_text, re.DOTALL):
        tagged_secs.append((key, body, None))

for pre in CONF_SAFE:
    local_text = _read(os.path.join(pre, ".claude", "BACKLOG.local.md"))
    if not local_text:
        continue
    for key, body in re.findall(SEC_RE, local_text, re.DOTALL):
        tagged_secs.append((key, body, pre))

if not tagged_secs:
    sys.exit(0)

def matches_current(key):
    # 归属判定（前缀匹配，修子目录分裂）：
    #   1) 精确等于当前 lane key（原行为）
    #   2) 当前 cwd 是该 lane 路径的子孙 —— 从项目子目录起 session 也认领父 lane 段
    # 只做「cwd 在 lane 之下」这一个方向；反向（lane 在 cwd 之下）会让裸 home 这种
    # 浅 cwd 吞掉所有子 lane，故不做。
    if key == cur_lane:
        return True
    lane_path = key[len("misc:"):] if key.startswith("misc:") else key
    if not lane_path.startswith("/"):
        return False
    return _under_prefix(_canon(cwd), _canon(lane_path))

cur_items = []
seen = set()
other = []
for path, body, conf_source in tagged_secs:
    items = [ln.strip() for ln in body.splitlines() if ln.strip().startswith("- [ ]")]
    if not items:
        continue
    key = path.strip().rstrip("/")
    is_current = matches_current(key)
    # P0-2：来自机密 lane 的段（conf_source 非 None）且非当前 session 命中 →
    #        直接 skip，既不进 cur_items 也不进 other（连 lane 名/计数都不暴露）。
    if conf_source is not None and not is_current:
        continue
    if is_current:
        for it in items:
            k = _dedup_key(it)
            if k in seen:
                continue
            seen.add(k)
            dm = re.search(r"<!--t:(\d{4}-\d{2}-\d{2})-->", it)
            display = re.sub(r"\s*<!--t:\d{4}-\d{2}-\d{2}-->", "", it).rstrip()
            cur_items.append((display, dm.group(1) if dm else None))
    else:
        # 只有非机密（聚合仓）段才进 other 计数，语义保持不变
        nm = os.path.basename(key) if not key.startswith("misc:") else key
        other.append((nm, len(items)))

if not cur_items and not other:
    sys.exit(0)

out = ["[backlog::hook-only] 跨 session 未完成任务(来自 BACKLOG.md,可能已过时,开工前快速核一眼):"]
# STEP2b(2026-07-17,nudge-only): 裸 home(cwd==$HOME 非项目 repo)→ 本 session todos 会落 misc 杂项磁铁
#   而非项目 lane。开场提示一句,在对的时机(开工前)nudge Colar cd 进项目。read-only,不动 persist 写路径。
if cwd == os.path.expanduser("~"):
    out.append("⚠️ 裸 home(非项目 repo):本 session 的 todos 会落 misc 杂项磁铁,不是项目 lane;如在做某项目请先 cd 进该 repo 再干活。")
if cur_items:
    # 冷/热分流:>COLD_DAYS 未触碰的折叠;活跃项超 MAX_LIST 也折叠
    # STEP1(2026-07-17): recency 排序(修 R9 最旧优先) + 分桶 round-robin(修 R3 单项目吃满槽) + 溢出写 sidecar(内容可恢复)
    _today = datetime.date.today()
    _MIN = datetime.date(1, 1, 1)  # 无戳项排序兜底(沉底,不占最新槽位)
    fresh, cold = [], []
    for it, dstr in cur_items:
        d = None
        age = None
        if dstr:
            try:
                d = datetime.date.fromisoformat(dstr)
                age = (_today - d).days
            except Exception:
                d = None
        (cold if (age is not None and age > COLD_DAYS) else fresh).append((it, d))

    # R9 修复:按 last-touched 递减(最新在前),让开场浮现"今天在干的活"而非文件顺序里最旧的 20 条
    fresh.sort(key=lambda x: x[1] or _MIN, reverse=True)

    # R3 修复:按开头 [标签]/首词分桶,round-robin 跨桶挑,防单一子项目吃满全部 MAX_LIST 槽位
    def _grp(text):
        # 先剥掉行首 "- [ ]" checkbox,否则 [标签]/首词 正则被它挡住 → 全落一个桶,分桶失效
        t = re.sub(r"^- \[[ xX]\]\s*", "", (text or "").strip())
        m = re.match(r"\[([^\]]{1,24})\]", t)
        if m:
            return "[" + m.group(1).strip() + "]"
        m2 = re.match(r"[\w./-]{2,20}", t)
        return m2.group(0) if m2 else "未分组"

    if len(fresh) <= MAX_LIST:
        shown = list(fresh)
    else:
        groups = {}  # 保持插入序(fresh 已 recency 降序 → 含最新项的桶靠前)
        for it, d in fresh:
            groups.setdefault(_grp(it), []).append((it, d))
        buckets = [list(v) for v in groups.values()]
        shown = []
        while len(shown) < MAX_LIST and any(buckets):
            for b in buckets:
                if b and len(shown) < MAX_LIST:
                    shown.append(b.pop(0))
            buckets = [b for b in buckets if b]
        shown.sort(key=lambda x: x[1] or _MIN, reverse=True)  # 展平后仍按 recency 显示

    overflow = len(fresh) - len(shown)
    out.append("■ 当前 project (" + cur_name + "):")
    out.extend("  " + it for it, _ in shown)

    folded = []
    if overflow > 0:
        folded.append(str(overflow) + " 条活跃项超出上限")
    if cold:
        folded.append(str(len(cold)) + " 条冷任务(>" + str(COLD_DAYS) + "天未触碰)")
    if folded:
        # 溢出/冷项全文写 sidecar:仅 ~/.claude 本地(不进 git,同 failclosed 兜底区),让被折叠内容可 Read 恢复而非只给计数
        hint = " → 全量见 BACKLOG.md 对应段;要捞哪条说一声"
        try:
            sidecar = os.path.expanduser("~/.claude/backlog_overflow.txt")
            slines = ["# backlog overflow — lane: " + cur_name + " — " + _today.isoformat(),
                      "# 每次 SessionStart 覆盖写,仅本地(~/.claude,不进 git)。开场只注入前 " + str(len(shown)) + " 条,以下为全量。", "",
                      "## 活跃(" + str(len(fresh)) + " 条,recency 降序):"]
            for it, d in fresh:
                slines.append(it + ("  <t:" + d.isoformat() + ">" if d else ""))  # it 已含行首 "- [ ]",不再加
            if cold:
                slines.append("")
                slines.append("## 冷(>" + str(COLD_DAYS) + "天未触碰," + str(len(cold)) + " 条):")
                for it, d in cold:
                    slines.append(it + ("  <t:" + d.isoformat() + ">" if d else ""))
            with open(sidecar, "w", encoding="utf-8") as sf:
                sf.write("\n".join(slines) + "\n")
            hint = " → 全量已写 " + sidecar + "(Read 它捞全部),或见 BACKLOG.md 对应段"
        except Exception:
            pass
        out.append("  … 已折叠: " + " + ".join(folded) + hint)
    if shown:
        out.append("  → 开工前把上面这些 rebuild 进 TodoWrite;union-merge 下未 rebuild 的项会保留,但只有本 session 显式 completed 才移除")
else:
    out.append("■ 当前 project (" + cur_name + "): 无 open 项")
if other:
    summary = " · ".join(n + ":" + str(c) for n, c in other)
    out.append("■ 其他 project open 计数: " + summary)
print("\n".join(out))
' 2>/dev/null
exit 0
