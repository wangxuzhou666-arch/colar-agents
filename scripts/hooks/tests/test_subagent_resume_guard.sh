#!/usr/bin/env bash
# subagent_resume_guard.sh 的判别力自证：
#   B 组（必须拦，exit 2 且 stderr 钉到具体读数与换人步骤）：恰好 400,000 · 2026-10-11 实测形状（748,593）·
#         尾部是 <synthetic> 零 usage · 最后一条 usage 被 300KB 的 tool_result 挡在 256KB 窗口外 ·
#         workflow 子目录里的 agent · to 大写 · 在 subagent 里发起 · [resume-ok] 不在开头
#   A 组（必须放行，exit 0 且零输出）：399,999 · compact 后回落（只认最后一条）· [resume-ok] 开头（含前导空白）·
#         非 subagent 目标（main / teammate 名 / 带 [ref] 的 session 名，且盘上故意放了同名超线文件）·
#         文件不存在 · stdin JSON 损坏 / 为空 · transcript 全是坏行 · 结构化消息 · 纯订阅 · 非 SendMessage
#   L 组：[resume-ok] 放行必须往 resume-ok.jsonl 追加恰好一行（agent + ctx 对得上）；拦截不许写它
#   T 组：耗时（宽松兜底 1000ms；目标 < 200ms，见输出里的实测值）
#
# 跑法：bash scripts/hooks/tests/test_subagent_resume_guard.sh
# 变异验证：GUARD=<改坏一条判定的副本> bash 本脚本 → 对应用例必须转红，否则该用例没有判别力。
#   2026-10-11 已验 13 个变异全部被杀：阈值改 500000 · >= 改 > · 删掉 [resume-ok] 分支 · 口子放行但不留痕 ·
#   startswith 改成 in · 漏加 cache_creation_input_tokens · 漏加 input_tokens · cache_read 读成 output_tokens ·
#   取第一条 usage · 不跳过 synthetic/零 usage · 只读一个 64KB 窗口 · 删掉 agentId 形状检查 · 不进 workflow 子目录。
#   注意 synthetic 有两道防线（model 名 + 零 usage），只删其中一道是等价变异，杀不死属正常。
#
# 隔离：fixture 全在 mktemp 目录；日志经 SUBAGENT_RESUME_GUARD_STATE_DIR 指进临时目录，不碰 ~/.claude/state。
# 写法上的注意：判断退出码一律不走管道（管道后取 $? 既脆也会被 bash_pitfall_guard 拦）。
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GUARD=${GUARD:-$HERE/../subagent_resume_guard.sh}
pass=0
fail=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"
export SUBAGENT_RESUME_GUARD_STATE_DIR="$STATE"

SID=11111111-2222-4333-8444-555555555555
PROJ="$TMP/projects/-Users-test"
SUB="$PROJ/$SID/subagents"
TP="$PROJ/$SID.jsonl"
mkdir -p "$SUB/workflows/wf_0000aaaa-bbb"
: > "$TP"

# ---- fixture：一份 subagent transcript，参数逐条描述记录 ----
#   u:输入:缓存读:缓存写  → 一条带 usage 的 assistant 记录
#   syn                   → <synthetic> 零 usage 记录（API 出错 / 被打断时的占位）
#   big:字节数            → 一条超大 tool_result（user 记录，不含 usage）
#   junk                  → 一行截断的坏 JSON
mk() { # $1 文件路径 · 其余参数同上
  python3 -I - "$@" <<'PY'
import json, sys
path, specs = sys.argv[1], sys.argv[2:]
out = []
for spec in specs:
    kind, _, rest = spec.partition(":")
    if kind == "u":
        i, cr, cc = (int(x) for x in rest.split(":"))
        out.append(json.dumps({"type": "assistant", "isSidechain": True, "message": {
            "model": "claude-sonnet-5-5", "role": "assistant",
            "content": [{"type": "text", "text": "ok"}],
            "usage": {"input_tokens": i, "cache_read_input_tokens": cr,
                      "cache_creation_input_tokens": cc, "output_tokens": 7}}}))
    elif kind == "syn":
        out.append(json.dumps({"type": "assistant", "isSidechain": True, "message": {
            "model": "<synthetic>", "role": "assistant",
            "content": [{"type": "text", "text": "API Error"}],
            "usage": {"input_tokens": 0, "cache_read_input_tokens": 0,
                      "cache_creation_input_tokens": 0, "output_tokens": 0}}}))
    elif kind == "big":
        out.append(json.dumps({"type": "user", "isSidechain": True, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "toolu_x", "content": "x" * int(rest)}]}}))
    elif kind == "junk":
        out.append("{\"type\": \"assistant\", \"message\": {\"usage\": {\"input_tok")
with open(path, "w") as f:
    f.write("\n".join(out) + "\n")
PY
}

# ---- payload：模型实际发出的 SendMessage 形状（to / summary / message）----
payload() { # $1 to · $2 message · [$3 发起方 agent_id，空=主 loop]
  TO="$1" MSG="$2" CALLER="${3-}" TPATH="$TP" SESSION="$SID" python3 -c 'import json,os,sys
d = {"session_id": os.environ["SESSION"], "transcript_path": os.environ["TPATH"], "cwd": "/Users/colar",
     "permission_mode": "default", "hook_event_name": "PreToolUse", "tool_name": "SendMessage",
     "tool_input": {"to": os.environ["TO"], "summary": "test", "message": os.environ["MSG"]},
     "tool_use_id": "toolu_test"}
if os.environ["CALLER"]:
    d["agent_id"] = os.environ["CALLER"]
    d["agent_type"] = "Senior Developer"
sys.stdout.write(json.dumps(d))' > "$TMP/p.json"
}

raw_payload() { printf '%s' "$1" > "$TMP/p.json"; }

# ---- 断言（guard 读文件而非管道，$? 直取 guard 自己的退出码）----
assert_block() { # $1 标签 · 其余参数：stderr 必含片段（钉到读数与换人步骤，防"被别的判定顺手拦下"冒充通过）
  local label=$1 out rc ok=1 frag
  shift
  out=$(bash "$GUARD" < "$TMP/p.json" 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || ok=0
  for frag in "$@"; do
    case "$out" in *"$frag"*) : ;; *) ok=0 ;; esac
  done
  if [ "$ok" -eq 1 ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL[block] $label"
    echo "   exit: $rc (want 2) / 期待片段: $*"
    echo "   got: ${out:-<空输出=放行>}"
  fi
}

assert_allow() { # $1 标签
  local out rc
  out=$(bash "$GUARD" < "$TMP/p.json" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL[allow] $1"
    echo "   exit: $rc (want 0)"
    echo "   got: ${out:-<空>}"
  fi
}

ok_lines() { # resume-ok.jsonl 当前行数
  if [ -f "$STATE/resume-ok.jsonl" ]; then wc -l < "$STATE/resume-ok.jsonl" | tr -d ' '; else echo 0; fi
}

assert_ok_logged() { # $1 标签 · $2 之前的行数 · $3 agent · $4 ctx —— 恰好新增一行且字段对得上
  local now
  now=$(ok_lines)
  if [ "$now" -eq $(($2 + 1)) ] && AGENT="$3" CTX="$4" LOG="$STATE/resume-ok.jsonl" python3 -c 'import json,os,sys
last = json.loads(open(os.environ["LOG"]).read().splitlines()[-1])
sys.exit(0 if last.get("agent") == os.environ["AGENT"] and last.get("ctx") == int(os.environ["CTX"])
         and last.get("ts") and last.get("session") else 1)'; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL[log] $1：resume-ok.jsonl 行数 $2 → ${now}（want +1）或字段对不上"
    [ -f "$STATE/resume-ok.jsonl" ] && tail -n 1 "$STATE/resume-ok.jsonl"
  fi
}

assert_ok_not_logged() { # $1 标签 · $2 之前的行数
  if [ "$(ok_lines)" -eq "$2" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL[log] $1：不该往 resume-ok.jsonl 写，却写了"
  fi
}

# ---- fixtures（agentId 形状同 Claude Code：a + 16 位 hex，可带「标签-」前缀）----
A_AT=a0000000000000001    # 恰好 400,000：5 + 389,995 + 10,000 —— 三个字段少加任何一个都会掉到线下
A_REAL=a0000000000000002  # 2026-10-11 实测：a9b1cd20e7c9689ba 续派前最后一轮 748,593
A_SYN=a0000000000000003   # 450K 之后跟一条 <synthetic> 零 usage
A_BIG=a0000000000000004   # 450K 之后跟一条 300KB tool_result（落在 256KB 首读窗口之外）
A_WF=aworker-00000000000000a5  # workflow 子目录 + 带标签前缀的 id
A_LOW=a0000000000000006   # 399,999
A_COMPACT=a0000000000000007  # 先 600K、compact 后回落到 120K
A_OK=a0000000000000008    # 450K，用来走 [resume-ok]
A_JUNK=a0000000000000009  # 全是坏行
A_NOFILE=a00000000000000ff

mk "$SUB/agent-$A_AT.jsonl"     u:3:150000:2000 u:5:389995:10000
mk "$SUB/agent-$A_REAL.jsonl"   u:2:600000:3000 u:2:744781:3810
mk "$SUB/agent-$A_SYN.jsonl"    u:2:440000:10000 syn
mk "$SUB/agent-$A_BIG.jsonl"    u:2:440000:10000 big:307200
mk "$SUB/workflows/wf_0000aaaa-bbb/agent-$A_WF.jsonl" u:2:450000:0
mk "$SUB/agent-$A_LOW.jsonl"    u:2:399000:997
mk "$SUB/agent-$A_COMPACT.jsonl" u:2:590000:10000 u:2:110000:10000
mk "$SUB/agent-$A_OK.jsonl"     u:2:440000:10000
mk "$SUB/agent-$A_JUNK.jsonl"   junk junk junk
# 判别力陷阱：给 main / teammate 名也放一份超线 transcript —— 若有人删了 agentId 形状检查，A 组会转红
mk "$SUB/agent-main.jsonl"       u:2:800000:0
mk "$SUB/agent-researcher.jsonl" u:2:800000:0
printf '%s' '{"agentType":"Senior Developer","description":"Preview phase 1: drift check, docs, plan"}' \
  > "$SUB/agent-$A_REAL.meta.json"

# ============ B 组：必须拦 ============

payload "$A_AT" "第 2 阶段开工：把下面 10 条全做完"
assert_block "B1 恰好 400,000 到线即拦" "400K" "约 400K" "TaskStop" "[resume-ok]" "$A_AT"

payload "$A_REAL" "第 2 阶段开工：Colar 已拍板 4 点，全部选推荐项"
assert_block "B2 2026-10-11 实测形状 748,593" "约 749K" "Senior Developer · Preview phase 1" \
  "smart zone" "feedback_subagent_resume_context_cap" "先逐条核对"

payload "$A_SYN" "继续"
assert_block "B3 尾部 <synthetic> 零 usage 要跳过、按上一条真实读数判" "约 450K"

payload "$A_BIG" "继续"
assert_block "B4 最后一条 usage 被 300KB tool_result 挡在首读窗口外" "约 450K"

payload "$A_WF" "继续"
assert_block "B5 workflow 子目录 + 带标签前缀的 agentId" "约 450K"

payload "A0000000000000002" "继续"
assert_block "B6 to 写成大写（Claude Code 比对前会转小写）" "约 749K"

payload "$A_REAL" "继续" "a00000000000000aa"
assert_block "B7 在 subagent 里发起（stdin 带 agent_id、transcript_path 仍是主会话的）" "约 749K"

before=$(ok_lines)
payload "$A_OK" "请把下面这批修复全做完。[resume-ok] 只是顺带提一句"
assert_block "B8 [resume-ok] 不在开头不算口子" "约 450K"
assert_ok_not_logged "B8 拦截不留 resume-ok 痕" "$before"

# ============ A 组：必须放行 ============

payload "$A_LOW" "第 2 阶段开工"
assert_allow "A1 399,999 线下放行"

payload "$A_COMPACT" "第 2 阶段开工"
assert_allow "A2 compact 后回落：只认最后一条 usage"

before=$(ok_lines)
payload "$A_OK" "[resume-ok] 第 3 行的拼写改成 colour，别的不动"
assert_allow "A3 [resume-ok] 开头放行"
assert_ok_logged "A3 [resume-ok] 放行留痕" "$before" "$A_OK" 450002

before=$(ok_lines)
payload "$A_OK" $'\n  [resume-ok] 立刻收尾，写交接文件后返回'
assert_allow "A4 [resume-ok] 前有换行和空格也算开头"
assert_ok_logged "A4 留痕" "$before" "$A_OK" 450002

payload "main" "汇报：第 2 阶段做完了"
assert_allow "A5 to=main（盘上有同名超线文件也不认）"

payload "researcher" "开始做 #1"
assert_allow "A6 to=teammate 名（盘上有同名超线文件也不认）"

payload "worker [3fa9c1]" "那边测试过了吗"
assert_allow "A7 to=带 [ref] 的 session 名"

payload "$A_NOFILE" "继续"
assert_allow "A8 agentId 形状对、但本会话没有这个 transcript"

raw_payload '{"tool_name": "SendMessage", "tool_input": {"to": "a0000000000000002", "mess'
assert_allow "A9 stdin JSON 截断损坏"

raw_payload ''
assert_allow "A10 stdin 为空"

payload "$A_JUNK" "继续"
assert_allow "A11 transcript 全是坏行"

raw_payload "{\"session_id\": \"$SID\", \"transcript_path\": \"$TP\", \"tool_name\": \"SendMessage\", \"tool_input\": {\"to\": \"$A_REAL\", \"message\": {\"type\": \"shutdown_request\", \"reason\": \"done\"}}}"
assert_allow "A12 结构化消息（shutdown_request）不是续派"

raw_payload "{\"session_id\": \"$SID\", \"transcript_path\": \"$TP\", \"tool_name\": \"SendMessage\", \"tool_input\": {\"to\": \"$A_REAL\", \"message\": \"\", \"notify_when_idle\": true}}"
assert_allow "A13 纯 notify_when_idle 订阅"

raw_payload "{\"session_id\": \"$SID\", \"transcript_path\": \"$TP\", \"tool_name\": \"Agent\", \"tool_input\": {\"to\": \"$A_REAL\", \"message\": \"继续\"}}"
assert_allow "A14 不是 SendMessage（matcher 配错时不误伤）"

raw_payload "{\"session_id\": \"$SID\", \"tool_name\": \"SendMessage\", \"tool_input\": {\"to\": \"$A_REAL\", \"message\": \"继续\"}}"
assert_allow "A15 没有 transcript_path"

# ============ T 组：耗时 ============
# 5MB 级 transcript（几千条记录），尾部照常 —— 只读尾巴的话和文件大小无关
args=()
for _ in $(seq 1 2500); do args+=(big:1500 u:2:440000:10000); done
mk "$SUB/agent-a00000000000000ee.jsonl" "${args[@]}"
payload "a00000000000000ee" "继续"
ms=$(GUARD="$GUARD" P="$TMP/p.json" python3 -c 'import os,subprocess,time
best = []
for _ in range(5):
    t = time.time()
    with open(os.environ["P"], "rb") as f:
        subprocess.run(["bash", os.environ["GUARD"]], stdin=f, capture_output=True)
    best.append((time.time() - t) * 1000)
print(int(max(best)))')
if [ "$ms" -lt 1000 ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL[time] 5 次里最慢 ${ms}ms（宽松上限 1000ms）"
fi
echo "T1 耗时：5 次里最慢 ${ms}ms（$(wc -c < "$SUB/agent-a00000000000000ee.jsonl" | tr -d ' ') 字节的 transcript）"

echo "PASS $pass / FAIL $fail"
[ "$fail" -eq 0 ]
