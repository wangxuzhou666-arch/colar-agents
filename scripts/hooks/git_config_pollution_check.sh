#!/usr/bin/env bash
# SessionStart + PostToolUse(Bash) advisory hook —— 检测仓库级 git config 被测试子进程写脏。
#
# 背景（2026-10-06 织锦两次实测）：在 linked worktree 里 commit 时，pre-commit 导出绝对路径的
#   GIT_DIR / GIT_INDEX_FILE；测试在 tmp_path 里起的 git 子进程继承了它们，`git config user.name Test`
#   之类的夹具操作就写进了真仓的 .git/config：user.name=Test、user.email=test@example.com、core.bare=true。
#   症状滞后且误导（提交署名变 Test、主工作树 git status 报 "must be run in a work tree"）。
#   源头修复只在新分支生效，约 30 棵旧 worktree 仍会复发 → 机械层兜底检测。
#
# 检测对象：
#   1. stdin JSON 的 cwd（缺省用进程 cwd）所在仓的 common dir —— 与 git rev-parse --git-common-dir
#      同一套发现规则（向上找 .git 目录 / .git 文件 → gitdir → commondir），由 python 自己走
#   2. 固定检查织锦主仓（下方 FABRIC_REPO；cwd 不在 git 仓库时只查它）
# 信号（只读 common dir 下的 config 文件）：
#   - user.name  == Test              （大小写不敏感、全等，不做子串匹配）
#   - user.email == test@example.com  （同上）
#   - core.bare 为真，但 common dir 就是 <仓根>/.git —— 有工作树的仓不该是 bare（真 bare 仓不报）
#
# 输出：命中 → JSON {systemMessage, hookSpecificOutput.additionalContext}（PostToolUse 的纯 stdout
#   不进模型上下文，只有 additionalContext 进）；无 hook 事件（手动跑）→ 纯文本。干净 → 零输出。
# 过滤：PostToolUse 只在命令含 git commit / git rebase / check_all / pytest 时检查；先在 bash 里
#   对原始 stdin 做超集预筛（不起 python），命中后再由 python 按 tool_input.command 精筛。
# 纪律：只读，绝不自动修；永远 exit 0。
# 耗时：全程不起 git 进程 —— /usr/bin/git 是 xcrun 垫片，机器繁忙时单次 13-38ms（2026-10-07 实测），
#   发现 + 两份 config 共三次调用就会破 100ms 目标；所以发现与解析都在一个 python 进程里做完。
#   代价是 config 用最小解析器读：只认无子节的 [user] / [core]，覆盖 `git config` 写出的规范格式
#   （污染正是它写的），手写的续行等冷门语法不认。
set +e

FABRIC_REPO="/Users/colar/Desktop/创业/fabric-agent-demo"

if [ -t 0 ]; then input=""; else input=$(cat 2>/dev/null); fi

EVENT_POST_RE='"hook_event_name"[[:space:]]*:[[:space:]]*"PostToolUse"'
KEYWORD_RAW_RE='git.*(commit|rebase)|check_all|pytest'
if [[ $input =~ $EVENT_POST_RE ]] && ! [[ $input =~ $KEYWORD_RAW_RE ]]; then
    exit 0
fi

printf '%s' "$input" | python3 -c '
import json, os, re, sys

FABRIC_REPO = sys.argv[1]
KEYWORD_RE = re.compile(r"git\s.*(commit|rebase)|check_all|pytest", re.S)
TRUTHY = {"true", "yes", "on", "1"}
WANTED_KEYS = {"user.name", "user.email", "core.bare"}

raw = sys.stdin.read()
try:
    payload = json.loads(raw) if raw.strip() else {}
except ValueError:
    # 坏 stdin 当手动调用：照常检查。bash 预筛已经按关键词挡过一轮，这里多查一次只费几十毫秒。
    payload = {}
if not isinstance(payload, dict):
    payload = {}

event = payload.get("hook_event_name") or ""
if event == "PostToolUse":
    command = (payload.get("tool_input") or {}).get("command") or ""
    if not isinstance(command, str) or not KEYWORD_RE.search(command):
        sys.exit(0)


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return None


def common_dir_of(start):
    d = os.path.abspath(start)
    while True:
        dotgit = os.path.join(d, ".git")
        if os.path.isdir(dotgit):
            return dotgit
        if os.path.isfile(dotgit):
            # linked worktree / submodule：.git 是文件，内容 "gitdir: <path>"；worktree 再经 commondir 指回主仓
            text = (read_text(dotgit) or "").strip()
            if not text.startswith("gitdir:"):
                return None
            gitdir = os.path.join(d, text[len("gitdir:"):].strip())
            commondir = (read_text(os.path.join(gitdir, "commondir")) or "").strip()
            return os.path.normpath(os.path.join(gitdir, commondir) if commondir else gitdir)
        if all((os.path.isfile(os.path.join(d, "HEAD")),
                os.path.isdir(os.path.join(d, "objects")),
                os.path.isdir(os.path.join(d, "refs")))):
            return d  # 身处 git dir 内部：真 bare 仓，或 cwd 就在某个 .git/ 里
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def config_value(text):
    # git 值语法：引号外的 # ; 起行内注释，引号本身不算值，反斜杠转义，两端空白不算值
    out, in_quote, i = [], False, 0
    while i < len(text):
        ch = text[i]
        if ch == "\\" and i + 1 < len(text):
            out.append({"n": "\n", "t": "\t", "b": "\b"}.get(text[i + 1], text[i + 1]))
            i += 2
            continue
        if ch == "\"":
            in_quote = not in_quote
        elif ch in "#;" and not in_quote:
            break
        else:
            out.append(ch)
        i += 1
    return "".join(out).strip()


def read_wanted_keys(config_file):
    text = read_text(config_file)
    if text is None:
        return {}
    values, section = {}, None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("["):
            end = line.find("]")
            header = line[1:end].strip() if end > 0 else ""
            # [branch "x"] / [a.b] 这类带子节的不是目标节
            section = header.lower() if re.fullmatch(r"[A-Za-z0-9-]+", header) else None
            line = line[end + 1:].strip() if end > 0 else ""  # git 允许 `[core] bare = true` 同一行
        if not line or line[0] in "#;" or section is None:
            continue
        key, sep, value = line.partition("=")
        key = re.split(r"[\s#;]", key.strip(), maxsplit=1)[0].lower()
        full_key = section + "." + key
        if full_key in WANTED_KEYS:
            # 无 "=" 的键（如裸写 `bare`）在 git 语义里就是 true，用 None 表示
            values.setdefault(full_key, []).append(config_value(value) if sep else None)
    return values


# common dir 列表（保持顺序、按 realpath 去重）
targets, seen = [], set()


def add_target(common_dir):
    if not common_dir or not os.path.isdir(common_dir):
        return
    real = os.path.realpath(common_dir)
    if real not in seen:
        seen.add(real)
        targets.append(common_dir.rstrip("/"))


cwd = payload.get("cwd") or os.getcwd()
if isinstance(cwd, str) and os.path.isdir(cwd):
    add_target(common_dir_of(cwd))
add_target(os.path.join(FABRIC_REPO, ".git"))  # 只认它自己的 .git，不向上找（找到的会是别的仓）

reports = []
for common_dir in targets:
    config_file = os.path.join(common_dir, "config")
    values = read_wanted_keys(config_file)
    has_worktree = os.path.basename(common_dir) == ".git"
    repo_root = os.path.dirname(common_dir) if has_worktree else common_dir
    hits = []
    for value in values.get("user.name", []):
        if value is not None and value.strip().lower() == "test":
            hits.append(("user.name=" + value, "config --local --unset user.name"))
            break
    for value in values.get("user.email", []):
        if value is not None and value.strip().lower() == "test@example.com":
            hits.append(("user.email=" + value, "config --local --unset user.email"))
            break
    bare_values = values.get("core.bare")
    if bare_values and has_worktree:
        last = bare_values[-1]  # git 取最后一次赋值
        if last is None or last.strip().lower() in TRUTHY:
            hits.append(("core.bare=" + (last or "true") + "（该仓有工作树，不该是 bare）",
                         "config --local core.bare false"))
    if hits:
        reports.append((repo_root, config_file, hits))

if not reports:
    sys.exit(0)

lines = ["[git-config-pollution::hook-only] !!! 仓库级 git config 被写脏（只读检测，未自动修复）"]
for repo_root, config_file, hits in reports:
    lines.append("仓库: {}   (config: {})".format(repo_root, config_file))
    for shown, fix in hits:
        lines.append("  - {}\n    恢复: git -C \"{}\" {}".format(shown, repo_root, fix))
lines.append(
    "先查是谁在 linked worktree 里 commit：已知根因是 pre-commit 导出绝对 GIT_DIR/GIT_INDEX_FILE，"
    "测试在 tmp 里起的 git 子进程继承后写进真仓（2026-10-06 织锦实测两次）。"
    "不先找到那棵没带修复的旧 worktree，恢复后还会再被写脏。"
)
full = "\n".join(lines)

if event in ("SessionStart", "PostToolUse"):
    short = "git config 被写脏：" + "；".join(
        "{} ({})".format(root, ", ".join(shown.split("（")[0] for shown, _ in hits))
        for root, _, hits in reports
    ) + " —— 恢复命令已注入上下文"
    print(json.dumps({
        "systemMessage": short,
        "hookSpecificOutput": {"hookEventName": event, "additionalContext": full},
    }, ensure_ascii=False))
else:
    print(full)
' "$FABRIC_REPO" 2>/dev/null
exit 0
