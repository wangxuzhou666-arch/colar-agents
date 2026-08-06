#!/usr/bin/env bash
# Stop hook: session 结束时把 TodoWrite 里未完成的项 union-merge 进 backlog
#
# 设计要点（2026-07-08 重构，修 H1/H2/并发互抹）:
#   - 从 stdin JSON 拿 transcript_path + cwd
#   - 扫 transcript 里最后一次 TodoWrite → open(pending/in_progress) + done(completed)
#   - lane key = git repo root（非裸 cwd）→ 同项目子目录归并回一段，非 repo 归显式 misc lane
#   - union-merge：老段 open ∪ 本次 open − 本次显式 completed → 未 load 的项不再被静默抹除
#   - flock 串行化整个 read-modify-write → 并发 session 的 Stop 不再互相丢更新
#   - session 没用 TodoWrite → 不动 BACKLOG（避免快 session 误清）
#   - 写成功/失败都写 sidecar log(~/.claude/backlog_persist.log)；signal.alarm 兜底 timeout
#
# 2026-07-08 方案 A（白名单分流 + 修 lane 分裂）:
#   - 机密 lane 白名单 ~/.claude/backlog_confidential_lanes.txt（前缀匹配）
#   - lane 命中机密前缀 → 改道落项目内 <repo>/.claude/BACKLOG.local.md（不 push）
#     未命中 → 落聚合仓 ~/Desktop/colar-memory/BACKLOG.md
#     ⚠️ 2026-08-05 订正：该文件已 gitignore，**不再 push、不跨机同步**（原注释写"会 push"是错的）。
#     Why：本 hook 每 session 改写它却从不 commit → 树永远脏 → SessionStart 的 auto-pull
#     （守卫条件 dirty==0 && ahead==0）永远跳过，双机同步曾因此静默断裂 27 天。
#     BACKLOG 是 live tracker 不是 memory，本机自持即可；缺失时本 hook 会自动重建。
#   - lane 分裂修复：非 git 的 misc lane 也做前缀归并（git repo 早由 rev-parse 收敛到 root）
#
# 2026-07-10 衰减与去重升级（修 backlog 无限膨胀污染开场 context）:
#   - dedup key 归一化：全角→半角标点 + 去空白 + casefold —— 同任务的标点变体不再重复累积
#   - 每条尾部带 <!--t:YYYY-MM-DD--> last-touched 戳：本 session TodoWrite 出现过 → 刷成今天;
#     未触碰 → 保留旧戳; 无戳(旧格式迁移) → 补今天
#   - 冷任务折叠在 recall 侧做(>14 天未触碰 / 超量溢出),persist 只负责保真落盘
#   ⚠️ <!--t:--> 格式与 recall.sh 的解析必须同步改
set +e
INPUT=$(head -c 262144)
export BACKLOG="$HOME/Desktop/colar-memory/BACKLOG.md"
export CONF_LANES="$HOME/.claude/backlog_confidential_lanes.txt"
export PLOG="$HOME/.claude/backlog_persist.log"
export HOOK_INPUT="$INPUT"

python3 -c '
import os, sys, json, signal, re, datetime, subprocess, fcntl
signal.signal(signal.SIGALRM, lambda *a: sys.exit(0))
signal.alarm(8)

def _plog(status, detail):
    try:
        with open(os.environ.get("PLOG", os.path.expanduser("~/.claude/backlog_persist.log")), "a", encoding="utf-8") as lf:
            lf.write(datetime.datetime.now().isoformat(timespec="seconds") + " " + status + " " + detail + "\n")
    except Exception:
        pass

try:
    d = json.loads(os.environ.get("HOOK_INPUT", "{}"))
except Exception:
    sys.exit(0)

tp  = d.get("transcript_path", "")
cwd = (d.get("cwd", "") or os.getcwd()).rstrip("/")
if not tp or not os.path.isfile(tp):
    sys.exit(0)

def lane_key(path):
    try:
        r = subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"],
                           capture_output=True, text=True, timeout=2)
        root = (r.stdout or "").strip()
        # STEP2a(2026-07-17): git root 恰为 $HOME → 判 misc,不当 project lane。
        #   裸 home 不是项目;若 ~ 某天被 git init 或嵌进某 repo,别把整个 home 当一个 lane 吞掉子项目。
        #   ⚠️ 与 recall.sh:lane_key 同步改(两文件同一归属契约)。
        if r.returncode == 0 and root and root != os.path.expanduser("~"):
            return root, os.path.basename(root), root
    except Exception:
        pass
    return "misc:" + path, "misc(" + (os.path.basename(path) or path) + ")", path

lane, name, display_path = lane_key(cwd)

# --- 方案 A：机密 lane 白名单（前缀匹配）+ 落盘分流 ---
# ⚠️ 改此逻辑（_canon / _load_conf_lanes / _under_prefix / 前缀归属）必须
#    persist.sh 与 recall.sh 两处同步 —— persist 落 A、recall 找 B 就丢件。
def _canon(p):
    # 归一路径：realpath 解 symlink（macOS /tmp -> /private/tmp 之类）+ 去尾 /
    # 失败抛异常，交给调用方按 fail-closed 处理（不再吞成裸路径 fail-open）。
    return os.path.realpath(p).rstrip("/")

def _load_conf_lanes():
    # 三态返回（fail-closed 语义）：
    #   list（可为空 list）= 成功，且合法地「没有机密 lane」
    #   None               = 不可信来源，调用方必须 fail-closed
    # 不可信来源：CONF_LANES env 未设/空串 · 文件不存在（配了却缺，保守按不可信）
    #             · 不可读（权限/IO）· 编码异常 · 解析/归一异常
    conf_path = os.environ.get("CONF_LANES", "") or ""
    if not conf_path.strip():
        return None  # env 未设或空串 → 不可信
    try:
        with open(conf_path, encoding="utf-8") as fh:
            raw = fh.readlines()
    except FileNotFoundError:
        return None  # 路径已配但文件不存在 → 保守按不可信
    except Exception:
        return None  # 权限/IO/编码异常 → 不可信
    prefixes = []
    try:
        for ln in raw:
            ln = ln.strip()
            if not ln or ln.startswith("#"):
                continue
            prefixes.append(_canon(ln))  # 归一失败 → 抛异常 → 下方 except → None
    except Exception:
        return None  # 解析/归一异常 → 不可信
    return prefixes

def _under_prefix(path, prefix):
    # path 等于 prefix 本身，或以 <prefix>/ 开头 → 命中（防 /a/foobar 误命中 /a/foo）
    return path == prefix or path.startswith(prefix + "/")

CONF_PREFIXES = _load_conf_lanes()  # None = 不可信白名单

def confidential_repo_root(display_path, lane_path):
    # 用 lane 的真实路径（git root 或 misc 的裸 path）去比对机密前缀。
    # 两边都 realpath 归一，避免 symlink 导致的假不命中。
    # 返回三态：
    #   str  = 命中某机密前缀（<repo> repo root）→ 落项目内 .local.md
    #   None = 明确未命中任何机密前缀 → 落聚合仓（会 push）
    #   "__UNTRUSTED__" = 白名单不可信 或 probe 归一失败 → fail-closed 落本地兜底
    if CONF_PREFIXES is None:
        return "__UNTRUSTED__"  # P0-1：白名单不可信 → fail-closed
    try:
        probe = _canon(display_path or lane_path)  # P1-1：归一失败 → 抛异常
    except Exception:
        return "__UNTRUSTED__"  # probe 归一失败 → 不拿裸路径 fail-open，改 fail-closed
    for pre in CONF_PREFIXES:
        if _under_prefix(probe, pre):
            return pre
    return None

conf_root = confidential_repo_root(display_path, cwd)

last = None
sid  = os.path.basename(tp).removesuffix(".jsonl")
try:
    with open(tp, encoding="utf-8") as fh:
        for line in fh:
            try:
                obj = json.loads(line)
            except Exception:
                continue
            msg = obj.get("message", {})
            content = msg.get("content")
            if not isinstance(content, list):
                continue
            for b in content:
                if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "TodoWrite":
                    todos = (b.get("input") or {}).get("todos")
                    if isinstance(todos, list):
                        last = todos
except Exception:
    sys.exit(0)

if last is None:
    sys.exit(0)

def _norm(s):
    s = (s or "").strip().replace("\n", " ")
    s = re.sub(r"<!--t:\d{4}-\d{2}-\d{2}-->", "", s)
    s = re.sub(r"\s*_\(in progress\)_\s*$", "", s)
    s = re.sub(r"\s+", " ", s)
    return s.strip()

# dedup key 归一化：全角标点→半角 + 去全部空白 + casefold。
# 修「同一条任务因（）：vs ():、有无空格而 dedup 失败无限累积」。
# 注意:本段 python 包在 bash 单引号里,映射表禁用 ASCII 引号字符
_FW = str.maketrans("（）：，、；！？【】－～", "():,,;!?[]-~")
def _dedup_key(s):
    s = _norm(s).translate(_FW)
    return re.sub(r"\s+", "", s).casefold()

session_open = [_norm(t.get("content")) for t in last
                if isinstance(t, dict) and t.get("status") in ("pending", "in_progress")]
session_done = {_norm(t.get("content")) for t in last
                if isinstance(t, dict) and t.get("status") == "completed"}

today = datetime.date.today().isoformat()
sid8  = sid[:8]

HEADER = """# BACKLOG — 跨 session 持久任务队列

> 自动维护:Stop hook 落盘每 session 结束时 TodoWrite 里未完成(pending/in_progress)的项;
> SessionStart hook 注入当前 project 的 open 项。按 git repo root 分段(非 repo 归 misc),可手动编辑。
> union-merge:未在本 session TodoWrite 出现的项会被保留;仅本 session 显式 completed 的项才移除。
> flock 串行化:并发 session 的 Stop 不再互抹。这是 live tracker,不是 memory 文件。
"""

# 固定本地兜底：在 ~/.claude 下，确定不被任何 git push；不依赖 conf_root（那正是求不出的值）
FAILCLOSED = os.path.expanduser("~/.claude/BACKLOG.failclosed.local.md")

def _is_gitignored(repo, filepath):
    # P1-2：主动确认目标被 gitignore。别把「不 push」这个安全不变量外包给脚本无法验证的前置。
    # 返回 True 仅当 git check-ignore 明确判定被 ignore（returncode 0）。
    try:
        r = subprocess.run(["git", "-C", repo, "check-ignore", "-q", filepath],
                           capture_output=True, timeout=2)
        return r.returncode == 0
    except Exception:
        return False

# 落盘分流：
#   __UNTRUSTED__ → 固定本地兜底 ~/.claude/BACKLOG.failclosed.local.md（P0-1 fail-closed）
#   命中机密前缀   → 项目内 <repo>/.claude/BACKLOG.local.md（不 push）；先验它被 gitignore（P1-2）
#   未命中         → 聚合仓（会 push）
if conf_root == "__UNTRUSTED__":
    backlog = FAILCLOSED
    dest_tag = "LOCAL-FAILCLOSED"
    _plog("WARN", "conf-whitelist untrusted -> fail-closed to local")
    try:
        os.makedirs(os.path.dirname(backlog), exist_ok=True)
    except Exception:
        pass
elif conf_root:
    candidate = os.path.join(conf_root, ".claude", "BACKLOG.local.md")
    try:
        os.makedirs(os.path.dirname(candidate), exist_ok=True)
    except Exception:
        pass
    if _is_gitignored(conf_root, candidate):
        backlog = candidate
        dest_tag = "LOCAL"
    else:
        # P1-2：目标未被 gitignore → 不写该处（会 push = 泄漏），fail-closed 落兜底
        backlog = FAILCLOSED
        dest_tag = "LOCAL-FAILCLOSED"
        _plog("WARN", "target not gitignored -> fail-closed")
        try:
            os.makedirs(os.path.dirname(backlog), exist_ok=True)
        except Exception:
            pass
else:
    backlog = os.environ["BACKLOG"]
    dest_tag = "AGG"

lockf = None
try:
    lockf = open(backlog + ".lock", "w")
    fcntl.flock(lockf, fcntl.LOCK_EX)
except Exception:
    # P1-3：lock 打不开 → 降级为无锁写，但别静默，让降级可见
    lockf = None
    _plog("WARN", "no-lock, degraded")

try:
    try:
        with open(backlog, encoding="utf-8") as fh:
            text = fh.read()
    except FileNotFoundError:
        text = HEADER

    if not text.strip().startswith("# BACKLOG"):
        text = HEADER + "\n" + text

    existing_open = []  # [(content, last_touched | None)]
    m = re.search(r"<!-- project:" + re.escape(lane) + r" -->(.*?)<!-- /project -->", text, re.DOTALL)
    if m:
        for ln in m.group(1).splitlines():
            ln = ln.strip()
            if ln.startswith("- [ ]"):
                raw = ln[len("- [ ]"):]
                dm = re.search(r"<!--t:(\d{4}-\d{2}-\d{2})-->", raw)
                existing_open.append((_norm(raw), dm.group(1) if dm else None))

    session_open_keys = {_dedup_key(c) for c in session_open}
    session_done_keys = {_dedup_key(c) for c in session_done}

    # STEP3a(2026-07-17): age-TTL 归档下架。超 ARCHIVE_TTL_DAYS 天未在任何 session TodoWrite 出现的项
    #   → 从活跃段下架,写 BACKLOG.archive.md 墓碑(可 grep 可回滚),不静默删。本 session 触碰过的项永不归档。
    #   归档按 <!--t:--> last-touched 日期为键(非 dedup_key)。当前存量全 <14 天,部署即时不下架任何项(纯未来 GC)。
    ARCHIVE_TTL_DAYS = 45
    today_d = datetime.date.fromisoformat(today)
    def _age_days(dstr):
        try:
            return (today_d - datetime.date.fromisoformat(dstr)).days
        except Exception:
            return None  # 日期不可解析 → 保守当 fresh,不归档

    merged, seen, archived = [], set(), []  # merged/archived: [(content, last_touched)]
    for item, item_date in existing_open + [(c, None) for c in session_open]:
        if not item:
            continue
        k = _dedup_key(item)
        if k in session_done_keys or k in seen:
            continue
        seen.add(k)
        # 本 session 触碰过 → 刷成今天; 未触碰保留旧戳; 无戳(旧格式)补今天当首见
        touched = today if (k in session_open_keys or item_date is None) else item_date
        # age-TTL:仅「本 session 未触碰」且「有戳且超 TTL」的项下架归档,其余照留
        if k not in session_open_keys and item_date is not None:
            age = _age_days(item_date)
            if age is not None and age > ARCHIVE_TTL_DAYS:
                archived.append((item, item_date))
                continue
        merged.append((item, touched))

    if archived:
        archive_path = os.path.join(os.path.dirname(backlog), "BACKLOG.archive.md")
        try:
            new_file = not os.path.exists(archive_path)
            with open(archive_path, "a", encoding="utf-8") as af:
                if new_file:
                    af.write("# BACKLOG.archive — age-TTL 下架墓碑(可回滚:把行复制回 BACKLOG.md 对应段)\n\n")
                for c, dd in archived:
                    af.write("- [ ] " + c + " <!--t:" + dd + "--> <!--archived:" + today + " lane:" + lane + "-->\n")
        except Exception as e:
            _plog("WARN", "archive write failed -> keep items: " + repr(e))
            # 归档写失败 → 绝不丢数据:放回 merged 下次再试(no-silent-erasure)
            for c, dd in archived:
                merged.append((c, dd))
            archived = []

    text = re.sub(r"\n*<!-- project:" + re.escape(lane) + r" -->.*?<!-- /project -->\n*", "\n", text, flags=re.DOTALL)
    text = re.sub(r"\n*<!-- last-persist:.*?-->\n*", "\n", text)

    if merged:
        lines = [f"<!-- project:{lane} -->", f"## {name}", f"`{display_path}`",
                 f"_updated: {today} · session {sid8}_", ""]
        lines += [f"- [ ] {c} <!--t:{d}-->" for c, d in merged]
        lines.append("<!-- /project -->")
        text = text.rstrip() + "\n\n" + "\n".join(lines) + "\n"
    else:
        text = text.rstrip() + "\n"

    now = datetime.datetime.now().isoformat(timespec="seconds")
    text = text.rstrip() + "\n\n<!-- last-persist: " + now + " -->\n"

    tmp = backlog + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, backlog)
    _plog("OK", "dest=" + dest_tag + " lane=" + lane + " merged=" + str(len(merged)) + " arch=" + str(len(archived)) + " (open=" + str(len(session_open)) + " done=" + str(len(session_done)) + " prev=" + str(len(existing_open)) + ")")
except Exception as e:
    _plog("FAIL", "dest=" + dest_tag + " lane=" + lane + " err=" + repr(e))
finally:
    if lockf is not None:
        try:
            fcntl.flock(lockf, fcntl.LOCK_UN)
            lockf.close()
        except Exception:
            pass
sys.exit(0)
' 2>/dev/null
exit 0
