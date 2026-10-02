#!/usr/bin/env bash
# SessionStart hook: 提示织锦（fabric-agent-demo）docs 清理的待确认清单 / LaunchAgent 是否还在跑
#
# 设计要点:
#   - 从 stdin JSON 拿 cwd;只有 cwd 命中 fabric-agent-demo 主仓或 /.wt/fabric- 工作树才可能输出，
#     其余 lane 一律静默(同 backlog_recall.sh 的 lane 归属判法,但这里只需要字符串命中,不需要
#     git repo root 那套——pending.json/log.jsonl 固定长在主仓,worktree 不会有自己的一份)
#   - 两条检查互相独立,都读不到就都静默:
#       pending.json 非空 → 提示待确认件数 + 清单路径
#       log.jsonl 最后一行的 ts 距今超过 10 天 → 另提示一行"可能没在跑"
#   - 永远 exit 0,不联网,不做任何写入;stdout 会被当 context 注入,不命中 → 零输出
set +e
INPUT=$(head -c 65536)
export HOOK_INPUT="$INPUT"

python3 -c '
import datetime, json, os, sys

try:
    d = json.loads(os.environ.get("HOOK_INPUT", "{}"))
except Exception:
    # stdin 按契约应该是 JSON,但解析失败时宁可静默退出,也不让这条提示挡住会话启动。
    sys.exit(0)

cwd = d.get("cwd", "") or ""
if "fabric-agent-demo" not in cwd and "/.wt/fabric-" not in cwd:
    sys.exit(0)

REPO = "/Users/colar/Desktop/创业/fabric-agent-demo"
ARCHIVE = REPO + "/.claude/docs-archive"
lines = []

try:
    with open(ARCHIVE + "/pending.json", encoding="utf-8") as f:
        items = json.load(f).get("items", [])
    if items:
        lines.append(
            "[docs-cleanup::hook-only] docs 清理待确认：{} 个候选在 {}/pending.json，"
            "确认后用单独提交删除，不要混进其他提交".format(len(items), ARCHIVE)
        )
except Exception:
    # 清单缺失 / 从没跑过 / JSON 格式异常,都当"当前无待确认项"处理,静默过去。
    pass

try:
    last_line = None
    with open(ARCHIVE + "/log.jsonl", encoding="utf-8") as f:
        for raw in f:
            raw = raw.strip()
            if raw:
                last_line = raw
    if last_line:
        ts = datetime.datetime.fromisoformat(json.loads(last_line)["ts"])
        now = datetime.datetime.now(ts.tzinfo) if ts.tzinfo else datetime.datetime.now()
        age_days = (now - ts).days
        if age_days > 10:
            lines.append(
                "[docs-cleanup::hook-only] docs 清理 LaunchAgent 已 {} 天未运行，"
                "定期清理可能没在跑，确认：launchctl print gui/$(id -u)/com.colar.fabric-docs-cleanup"
                .format(age_days)
            )
except Exception:
    # log 缺失 / 空 / 某行格式异常,当作"拿不到运行记录",不因此阻断或误报。
    pass

if lines:
    print("\n".join(lines))
' 2>/dev/null
exit 0
