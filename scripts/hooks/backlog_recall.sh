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
set +e
INPUT=$(head -c 65536)
export BACKLOG="$HOME/Desktop/colar-memory/BACKLOG.md"
export CONF_LANES="$HOME/.claude/backlog_confidential_lanes.txt"
export HOOK_INPUT="$INPUT"

# 聚合仓不存在也别急着退 —— 机密 lane 的 .local.md 可能仍有内容要注入

python3 -c '
import os, sys, json, signal, re, subprocess
signal.signal(signal.SIGALRM, lambda *a: sys.exit(0))
signal.alarm(6)

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
        if r.returncode == 0 and root:
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
            if it not in seen:
                seen.add(it)
                cur_items.append(it)
    else:
        # 只有非机密（聚合仓）段才进 other 计数，语义保持不变
        nm = os.path.basename(key) if not key.startswith("misc:") else key
        other.append((nm, len(items)))

if not cur_items and not other:
    sys.exit(0)

out = ["[backlog::hook-only] 跨 session 未完成任务(来自 BACKLOG.md,可能已过时,开工前快速核一眼):"]
if cur_items:
    out.append("■ 当前 project (" + cur_name + "):")
    out.extend("  " + it for it in cur_items)
    out.append("  → 开工前把上面这些 rebuild 进 TodoWrite;union-merge 下未 rebuild 的项会保留,但只有本 session 显式 completed 才移除")
else:
    out.append("■ 当前 project (" + cur_name + "): 无 open 项")
if other:
    summary = " · ".join(n + ":" + str(c) for n, c in other)
    out.append("■ 其他 project open 计数: " + summary)
print("\n".join(out))
' 2>/dev/null
exit 0
