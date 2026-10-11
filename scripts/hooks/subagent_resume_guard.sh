#!/usr/bin/env bash
# PreToolUse(SendMessage) 机械硬拦 —— 不许把上下文已过 400K 的 subagent 续派新活。
#
# 规则（Colar 2026-10-11 拍板）：subagent 上下文到 400K token 就交接给新的 subagent。
#   400K 是大模型 smart zone 的界限，过线推理质量下降 —— 首要理由是质量，成本次之
#   （续用的 agent 每轮都要全量复读自己的 transcript，近 O(N²)）。
#   全文：~/Desktop/colar-memory/feedback_subagent_resume_context_cap.md
#
# 为什么必须进机械层：这条 2026-09-28 就在 memory 里，2026-10-11 主 loop 仍用 SendMessage
#   把一个约 75 万 token 的 agent（a9b1cd20e7c9689ba，续派前最后一轮 748,593）续派去干整个
#   第 2 阶段，续派后涨到 94 万。「续派前看一眼 subagent_tokens」是零歧义的机械动作，
#   按 SOUL Tool-Call Discipline 的判据，这类坑文本杠杆实测无效，只能 hook 硬拦。
#
# 实测依据（Claude Code 2.1.294，2026-10-11）：
#   - stdin：{session_id, transcript_path, cwd, permission_mode, agent_id?, agent_type?,
#            hook_event_name, tool_name, tool_input, tool_use_id}。transcript_path 是【主会话】的
#            <项目目录>/<session_id>.jsonl —— subagent 里发起的调用也一样（agent_id 才是发起方）。
#   - tool_input：模型发出的是 {to, summary, message}；记进 transcript 时会补 type / recipient /
#            recipient_kind / content（content 只是截断 50 字的预览，不能当正文用）。
#   - subagent transcript：<项目目录>/<session_id>/subagents/agent-<agentId>.jsonl
#            （workflow 起的 agent 在 subagents/workflows/<wf_id>/ 下）。
#            /private/tmp/claude-501/.../tasks/<agentId>.output 只是指向它的 symlink，
#            且那个目录名是进程首个 session 的 id，不是当前 session —— 不能拿来推路径。
#   - agentId 形状：Claude Code 内部正则 ^a(?:[\w-]{1,63}-)?[0-9a-f]{16}$（比对前先 trim + 小写）。
#   - 上下文大小 = 最后一条非 synthetic 的 assistant 记录的
#            input_tokens + cache_read_input_tokens + cache_creation_input_tokens
#            （与 explore_read_nudge.sh 同一口径；同一轮多个 content block 会各写一条、usage 相同）。
#            实测 1911 份 subagent transcript：最后一条 usage 离文件尾 98% 在 64KB 内、最远 163KB；
#            17 份结尾是 <synthetic> 零 usage 记录，必须跳过往前找。
#
# 判定：
#   - 只认 to 能落到「本会话某个 subagent transcript」的调用；to 是 main / teammate 名 /
#     别的 session / 找不到文件 / stdin 或 transcript 解析失败 / message 是结构化对象（shutdown 等）/
#     纯 notify_when_idle 订阅 → 一律放行（fail-open），只往调试日志记一行。
#   - 上下文 ≥ 400,000 → exit 2，stderr 告诉模型约多少 K、该怎么换人。
#   - 放行口子：message 以 [resume-ok] 开头（允许前导空白）→ 放行，并往 resume-ok.jsonl 留痕。
#
# 日志：~/.claude/state/subagent-resume-guard/（同 explore_read_nudge 的落点惯例：不进 git、不放易失的 $TMPDIR）
#   - resume-ok.jsonl：每次走口子放行一行 {ts, session, caller, agent, ctx, msg_chars}，只追加不轮转
#   - debug.jsonl：每次判定一行（allow / block / resume-ok / skip+原因），超 512KB 轮转成 .1
#   SUBAGENT_RESUME_GUARD_STATE_DIR 可改落点（测试用）。阈值刻意不开环境变量。
#
# 性能：只读 transcript 尾部（256KB，找不到再放大到 4MB），目标 < 200ms。
# 自证测试：bash scripts/hooks/tests/test_subagent_resume_guard.sh —— 改判定先跑它。

# python 直接继承 hook 的 stdin（不经环境变量，message 再长也不撞 ARG_MAX）
python3 -c '
import glob, json, os, re, sys, unicodedata
from datetime import datetime, timezone

CAP = 400000  # 400K：大模型 smart zone 的界限（Colar 2026-10-11 定）
RESUME_OK_TAG = "[resume-ok]"
TAIL_WINDOWS = (256 * 1024, 4 * 1024 * 1024)  # 先读尾部 256KB，找不到 usage 再放大到 4MB
AGENT_ID_RE = re.compile(r"a(?:[A-Za-z0-9_-]{1,63}-)?[0-9a-f]{16}")
STATE_DIR = (os.environ.get("SUBAGENT_RESUME_GUARD_STATE_DIR")
             or os.path.expanduser("~/.claude/state/subagent-resume-guard"))
DEBUG_LOG_MAX = 512 * 1024


def append_log(name, entry):
    """追加一行 JSONL。写日志失败绝不影响判定，所以异常一律静默吞掉。"""
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        path = os.path.join(STATE_DIR, name)
        if name == "debug.jsonl" and os.path.exists(path) and os.path.getsize(path) > DEBUG_LOG_MAX:
            os.replace(path, path + ".1")
        entry = dict(ts=datetime.now(timezone.utc).isoformat(timespec="seconds"), **entry)
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception:
        pass


def find_agent_transcript(transcript_path, session_id, agent_id):
    """在本会话的 subagents 目录里找 agent-<id>.jsonl；找不到返回 None。"""
    bases = []
    if transcript_path.endswith(".jsonl"):
        bases.append(transcript_path[:-len(".jsonl")])
    if transcript_path and session_id:
        bases.append(os.path.join(os.path.dirname(transcript_path), session_id))
    name = "agent-%s.jsonl" % agent_id
    for base in bases:
        sub = os.path.join(base, "subagents")
        direct = os.path.join(sub, name)
        if os.path.isfile(direct):
            return direct
        # workflow 起的 agent 落在 subagents/workflows/<wf_id>/ 下
        for pattern in (os.path.join(sub, "*", name), os.path.join(sub, "*", "*", name)):
            hits = sorted(glob.glob(pattern))
            if hits:
                return hits[0]
    return None


def last_context_tokens(path):
    """最后一条真实 assistant 记录的上下文大小；找不到返回 None。"""
    size = os.path.getsize(path)
    for window in TAIL_WINDOWS:
        with open(path, "rb") as f:
            f.seek(max(0, size - window))
            data = f.read()
        lines = data.split(b"\n")
        if size > window:
            lines = lines[1:]  # 窗口的第一行多半被截断
        for raw in reversed(lines):
            if b"\"usage\"" not in raw:
                continue
            try:
                rec = json.loads(raw)
            except ValueError:
                continue
            msg = rec.get("message")
            if rec.get("type") != "assistant" or not isinstance(msg, dict):
                continue
            usage = msg.get("usage")
            # <synthetic> 是 API 出错 / 被打断时补的占位消息，usage 全 0，不代表真实上下文
            if not isinstance(usage, dict) or msg.get("model") == "<synthetic>":
                continue
            ctx = ((usage.get("input_tokens") or 0)
                   + (usage.get("cache_read_input_tokens") or 0)
                   + (usage.get("cache_creation_input_tokens") or 0))
            if ctx > 0:
                return ctx
        if size <= window:
            break
    return None


def agent_label(path):
    """读同目录的 agent-<id>.meta.json 拼一个「类型 · 描述」，读不到就空串。"""
    try:
        with open(path[:-len(".jsonl")] + ".meta.json", encoding="utf-8") as f:
            meta = json.load(f)
        parts = [p for p in (meta.get("agentType"), meta.get("description")) if isinstance(p, str) and p]
        return "（%s）" % " · ".join(parts) if parts else ""
    except Exception:
        return ""


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        append_log("debug.jsonl", {"decision": "skip", "reason": "bad-stdin"})
        return 0
    if not isinstance(data, dict) or data.get("tool_name") != "SendMessage":
        return 0

    tool_input = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
    session_id = data.get("session_id") if isinstance(data.get("session_id"), str) else ""
    caller = data.get("agent_id") or "main"
    to = tool_input.get("to")
    if not isinstance(to, str):
        to = tool_input.get("recipient")
    log = {"session": session_id, "caller": caller, "to": to if isinstance(to, str) else None}

    if not isinstance(to, str):
        append_log("debug.jsonl", dict(log, decision="skip", reason="no-to"))
        return 0
    agent_id = unicodedata.normalize("NFKC", to).strip().lower()
    if not AGENT_ID_RE.fullmatch(agent_id):
        # main / teammate 名 / 别的 session —— 都不是本会话 subagent，不归本 guard 管
        append_log("debug.jsonl", dict(log, decision="skip", reason="not-agent-id"))
        return 0

    message = tool_input.get("message")
    if not isinstance(message, str):
        # shutdown_request / plan_approval_response 这类结构化协议消息，不是续派新活
        append_log("debug.jsonl", dict(log, decision="skip", reason="structured-message"))
        return 0
    if not message.strip():
        # 纯 notify_when_idle 订阅，不给对方塞活
        append_log("debug.jsonl", dict(log, decision="skip", reason="empty-message"))
        return 0

    transcript_path = data.get("transcript_path") if isinstance(data.get("transcript_path"), str) else ""
    path = find_agent_transcript(transcript_path, session_id, agent_id)
    if path is None:
        append_log("debug.jsonl", dict(log, decision="skip", reason="no-transcript"))
        return 0
    ctx = last_context_tokens(path)
    if ctx is None:
        append_log("debug.jsonl", dict(log, decision="skip", reason="no-usage"))
        return 0
    log["ctx"] = ctx

    if ctx < CAP:
        append_log("debug.jsonl", dict(log, decision="allow"))
        return 0

    if message.lstrip().startswith(RESUME_OK_TAG):
        append_log("resume-ok.jsonl", {"session": session_id, "caller": caller, "agent": agent_id,
                                       "ctx": ctx, "msg_chars": len(message)})
        append_log("debug.jsonl", dict(log, decision="resume-ok"))
        return 0

    append_log("debug.jsonl", dict(log, decision="block"))
    k = round(ctx / 1000)
    err = sys.stderr
    print("subagent-resume-guard：本次 SendMessage 已拦截 —— 目标 agent %s%s 当前上下文约 %dK token，已过 400K。"
          % (agent_id, agent_label(path), k), file=err)
    print("400K 是大模型 smart zone 的界限：过线推理质量下降（首要理由）；续派还要每轮全量复读它的 transcript（成本次之）。", file=err)
    print("按 feedback_subagent_resume_context_cap 换人，不要续派：", file=err)
    print("  1. TaskStop 停掉它（task_id: %s；已经结束的可跳过）；" % agent_id, file=err)
    print("  2. git status 看工作树现状；", file=err)
    print("  3. 起一个新 agent，给自包含简报（背景与架构摘要、硬规则、完整条目清单），并写明「上一个 agent 停在 X，"
          "各条可能已做、做了一半或没做，先逐条核对，再补齐」。", file=err)
    print("一两句的小改确需续用（例如让它立刻收尾写交接）：消息开头写 [resume-ok] 再发，放行会留痕。", file=err)
    return 2


try:
    code = main()
except Exception:
    code = 0  # guard 自身出错一律放行，绝不因 hook bug 阻断工具
sys.exit(code)
'
rc=$?

# 只透传「确定命中」的 exit 2；python 崩溃等其他非零码一律 fail-open
[ "$rc" -eq 2 ] && exit 2
exit 0
