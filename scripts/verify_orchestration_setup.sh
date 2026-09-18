#!/usr/bin/env bash
#
# verify_orchestration_setup.sh
#
# 一键检查 2026-09-18 这批"编排纪律"配置是否全部到位（7 项，见下）。
# 不依赖 cwd —— 全部路径写死成绝对路径。直接跑：
#   bash /Users/colar/Desktop/colar-agents/scripts/verify_orchestration_setup.sh
#
# 每项检查独立输出一行：
#   ✓ <项目>                 —— 通过
#   ✗ <项目>: <具体哪里不对>   —— 失败，附体检时抓到的具体原因
#
# 全绿 exit 0；任何一项失败 exit 1。不用 set -e —— 单项检查失败不能让脚本
# 提前退出，否则看不到全貌（7 项要一次跑完，逐项报告，而不是撞到第一个红灯就停）。

set -uo pipefail

# ---------------------------------------------------------------------------
# 绝对路径常量 —— "不依赖 cwd" 是硬性要求，这里全部写死，不用相对路径拼接
# ---------------------------------------------------------------------------
AGENTS_ROOT="/Users/colar/Desktop/colar-agents"
SETTINGS_JSON="/Users/colar/.claude/settings.json"
HOOK_SCRIPT="$AGENTS_ROOT/scripts/hooks/explore_read_nudge.sh"
SENIOR_DEV_MD="$AGENTS_ROOT/engineering/engineering-senior-developer.md"
AGENT_INFRA_MD="$AGENTS_ROOT/engineering/engineering-agent-infra.md"
VC_CRITIC_MD="$AGENTS_ROOT/specialized/idea-vc-critic.md"
RUN_EVAL_SH="$AGENTS_ROOT/eval/run-eval.sh"
SOUL_MD="$AGENTS_ROOT/soul/SOUL.md"
ORCH_AUDIT_PY="$AGENTS_ROOT/scripts/orchestration_audit.py"

FAIL=0

ok()  { printf '✓ %s\n' "$1"; }
bad() { printf '✗ %s: %s\n' "$1" "$2"; FAIL=1; }

# 从一个 agent .md 的 YAML frontmatter（第一个 --- 到第二个 --- 之间）里取出
# `model:` 这行的值。这台机器没装 pyyaml，不假装有——纯 sed/grep 抠字符串：
#   1) sed 取 frontmatter 区间（含首尾两条 ---）
#   2) grep 取第一条 ^model: 行（frontmatter 里只应有一条）
#   3) sed 依次去掉 "model:" 前缀、"# 注释" 后缀、行尾空白
# 现有文件的真实格式是 `model: sonnet  # 2026-09-18 opus->sonnet...`，第 3 步的
# 去注释是必需的——不然比较会变成整行 vs "sonnet"，永远判失败。
extract_model() {
  local md_file="$1"
  [[ -f "$md_file" ]] || return 1
  sed -n '/^---[[:space:]]*$/,/^---[[:space:]]*$/p' "$md_file" 2>/dev/null \
    | grep -m1 '^model:' \
    | sed -e 's/^model:[[:space:]]*//' -e 's/#.*$//' -e 's/[[:space:]]*$//'
}

echo "验证 2026-09-18 编排纪律配置"
echo "============================"

# ---------------------------------------------------------------------------
# 1) hook 已挂进 settings.json 的 hooks.UserPromptSubmit
#    防的是：explore_read_nudge.sh 写好了、能跑，但忘了在 settings.json 里接线，
#    实际用户发 prompt 时根本不会触发它——脚本存在 ≠ 生效。
#    用 python3 解析 JSON（不是 grep 猜字符串），按真实嵌套结构
#    hooks.UserPromptSubmit[].hooks[].command 找 "explore_read_nudge" 子串；
#    command 里实际写的是 $HOME/... 而不是字面绝对路径，所以只能匹配子串，
#    不能要求整段路径完全相等。
# ---------------------------------------------------------------------------
check1_out="$(python3 - "$SETTINGS_JSON" <<'PYEOF' 2>&1
import json, sys

settings_path = sys.argv[1]
try:
    with open(settings_path) as f:
        data = json.load(f)
except OSError as e:
    print(f"读取 {settings_path} 失败: {e}")
    sys.exit(1)
except json.JSONDecodeError as e:
    print(f"{settings_path} 不是合法 JSON: {e}")
    sys.exit(1)

ups = data.get("hooks", {}).get("UserPromptSubmit")
if not isinstance(ups, list):
    print("settings.json 里 hooks.UserPromptSubmit 不存在或不是数组")
    sys.exit(1)

found = False
for group in ups:
    for h in (group.get("hooks") or []):
        if "explore_read_nudge" in (h.get("command") or ""):
            found = True

if not found:
    print("hooks.UserPromptSubmit 里没有任何 command 含 'explore_read_nudge' 的条目")
    sys.exit(1)
sys.exit(0)
PYEOF
)"
check1_code=$?
if [[ $check1_code -eq 0 ]]; then
  ok 'hook 已挂进 settings.json UserPromptSubmit'
else
  bad 'hook 已挂进 settings.json UserPromptSubmit' "$check1_out"
fi

# ---------------------------------------------------------------------------
# 2) explore_read_nudge.sh 存在且有可执行位
#    防的是：脚本被移动/改名，或者可执行位被某次 chmod/同步操作意外抹掉——
#    settings.json 里接了线，但线的另一头是个打不开或权限不对的文件。
# ---------------------------------------------------------------------------
if [[ ! -e "$HOOK_SCRIPT" ]]; then
  bad 'explore_read_nudge.sh 存在且可执行' "文件不存在: $HOOK_SCRIPT"
elif [[ ! -f "$HOOK_SCRIPT" ]]; then
  bad 'explore_read_nudge.sh 存在且可执行' "路径存在但不是普通文件: $HOOK_SCRIPT"
elif [[ ! -x "$HOOK_SCRIPT" ]]; then
  bad 'explore_read_nudge.sh 存在且可执行' "文件存在但没有可执行位（需要 chmod +x）: $HOOK_SCRIPT"
else
  ok 'explore_read_nudge.sh 存在且可执行'
fi

# ---------------------------------------------------------------------------
# 3) hook 真的跑一遍：喂一个 transcript_path 指向不存在文件的 payload，
#    必须"静默（无输出）+ exit 0"（fail-open）。
#    防的是：hook 对"文件不存在"这类边界输入处理错误——真实场景里 transcript_path
#    随时可能因为竞态/权限/清理而暂时读不到，hook 一旦在这种情况下报错或非零退出，
#    就会拖垮它所挂载的 UserPromptSubmit（每次用户发消息都要跑这一串 hook）。
#    这里是真的执行它（走 settings.json 里同款的 `bash <path>` 调用方式），
#    检查真实 stdout + exit code，不是只看文件存在。
# ---------------------------------------------------------------------------
check3_out="$(printf '%s' '{"transcript_path":"/nonexistent"}' | bash "$HOOK_SCRIPT" 2>&1)"
check3_code=$?
if [[ $check3_code -ne 0 ]]; then
  bad 'hook 对不存在的 transcript_path 静默 fail-open' "退出码是 $check3_code（期望 0）；输出: $check3_out"
elif [[ -n "$check3_out" ]]; then
  bad 'hook 对不存在的 transcript_path 静默 fail-open' "退出码 0，但不是静默——实际输出: $check3_out"
else
  ok 'hook 对不存在的 transcript_path 静默 fail-open'
fi

# ---------------------------------------------------------------------------
# 4) engineering-senior-developer.md 的 frontmatter model == sonnet
#    防的是：2026-09-18 从 opus 降到 sonnet 这次改动被后续编辑悄悄改回、
#    或者被误改成别的值——这条 agent 已用 eval 验过 sonnet 够用，退回 opus
#    是白花钱，改成其他值则完全没验过。
# ---------------------------------------------------------------------------
if [[ ! -f "$SENIOR_DEV_MD" ]]; then
  bad 'senior-developer model == sonnet' "文件不存在: $SENIOR_DEV_MD"
else
  model_senior_dev="$(extract_model "$SENIOR_DEV_MD")"
  if [[ -z "$model_senior_dev" ]]; then
    bad 'senior-developer model == sonnet' "frontmatter 里找不到 model: 行（$SENIOR_DEV_MD）"
  elif [[ "$model_senior_dev" == "sonnet" ]]; then
    ok 'senior-developer model == sonnet'
  else
    bad 'senior-developer model == sonnet' "实际值是 '$model_senior_dev'（$SENIOR_DEV_MD）"
  fi
fi

# ---------------------------------------------------------------------------
# 5) engineering-agent-infra.md 和 idea-vc-critic.md 的 model 都 == opus
#    防的是：这两个"判断类 / 改系统本身出错代价高"的 agent（改 AI 基础设施本身、
#    评估创业决策）被误降级到 sonnet——2026-09-18 就是为它们把 model 从"继承主
#    loop 默认值"改成显式钉死 opus，钉死的意义就在于不会被后续改动悄悄漂移。
# ---------------------------------------------------------------------------
check5_msg=""
if [[ ! -f "$AGENT_INFRA_MD" ]]; then
  check5_msg="$AGENT_INFRA_MD 不存在"
else
  model_agent_infra="$(extract_model "$AGENT_INFRA_MD")"
  if [[ -z "$model_agent_infra" ]]; then
    check5_msg="$AGENT_INFRA_MD 的 frontmatter 里找不到 model: 行"
  elif [[ "$model_agent_infra" != "opus" ]]; then
    check5_msg="$AGENT_INFRA_MD 实际值是 '$model_agent_infra'"
  fi
fi
if [[ ! -f "$VC_CRITIC_MD" ]]; then
  check5_msg="${check5_msg:+$check5_msg; }$VC_CRITIC_MD 不存在"
else
  model_vc_critic="$(extract_model "$VC_CRITIC_MD")"
  if [[ -z "$model_vc_critic" ]]; then
    check5_msg="${check5_msg:+$check5_msg; }$VC_CRITIC_MD 的 frontmatter 里找不到 model: 行"
  elif [[ "$model_vc_critic" != "opus" ]]; then
    check5_msg="${check5_msg:+$check5_msg; }$VC_CRITIC_MD 实际值是 '$model_vc_critic'"
  fi
fi

if [[ -z "$check5_msg" ]]; then
  ok 'agent-infra 和 vc-critic model == opus'
else
  bad 'agent-infra 和 vc-critic model == opus' "$check5_msg"
fi

# ---------------------------------------------------------------------------
# 6) eval/run-eval.sh 里 JUDGE_MODEL 已定义，且 judge 调用用 $JUDGE_MODEL 不是 $MODEL
#    防的是：judge（评分尺子）和被测 agent 共用同一个 model 变量——一旦有人用
#    --model 切换被测模型，尺子会跟着一起动，pass rate 的前后对比就失去意义
#    （"sonnet 写、sonnet 判" 对比 "opus 写、opus 判"，差异无法归因到被测的一侧）。
#    只查字符串"存在"不够，要落到 run_judge() 这个函数体本身：确认它实际调用的
#    是 $JUDGE_MODEL，而不是变量名前缀撞车的 $MODEL。
# ---------------------------------------------------------------------------
if [[ ! -f "$RUN_EVAL_SH" ]]; then
  bad 'run-eval.sh judge 用 $JUDGE_MODEL 而非 $MODEL' "文件不存在: $RUN_EVAL_SH"
elif ! grep -Eq '^JUDGE_MODEL=' "$RUN_EVAL_SH"; then
  bad 'run-eval.sh judge 用 $JUDGE_MODEL 而非 $MODEL' '没有找到 JUDGE_MODEL= 的赋值行'
else
  judge_fn_body="$(sed -n '/^run_judge() {/,/^}$/p' "$RUN_EVAL_SH")"
  if [[ -z "$judge_fn_body" ]]; then
    bad 'run-eval.sh judge 用 $JUDGE_MODEL 而非 $MODEL' '没找到 run_judge() 函数体（函数名可能改了）'
  elif ! grep -qF -- '--model "$JUDGE_MODEL"' <<<"$judge_fn_body"; then
    bad 'run-eval.sh judge 用 $JUDGE_MODEL 而非 $MODEL' 'run_judge() 里没有用 --model "$JUDGE_MODEL" 调用 claude'
  elif grep -qF -- '--model "$MODEL"' <<<"$judge_fn_body"; then
    bad 'run-eval.sh judge 用 $JUDGE_MODEL 而非 $MODEL' 'run_judge() 里还在用 --model "$MODEL"——尺子会跟着被测模型一起动'
  else
    ok 'run-eval.sh judge 用 $JUDGE_MODEL 而非 $MODEL'
  fi
fi

# ---------------------------------------------------------------------------
# 7) SOUL.md 含"主 loop 只做薄编排"这条规则，且 scripts/orchestration_audit.py 存在
#    防的是：规则和审计脚本只落地一半——feedback_fable_thin_orchestrator_model_routing.md
#    早在 2026-07-03 就写下这条铁律，但 SOUL 一直没接 pointer，两个半月零执行，
#    是"规则写下但触达不到执行点"的先例。规则文字有了但没有脚本能审计是否遵守，
#    或者反过来脚本有了但规则没写进 SOUL，都等于没做完。
# ---------------------------------------------------------------------------
check7_msg=""
if [[ ! -f "$SOUL_MD" ]]; then
  check7_msg="$SOUL_MD 不存在"
elif ! grep -qF -- '主 loop 只做薄编排' "$SOUL_MD"; then
  check7_msg="$SOUL_MD 里没有找到「主 loop 只做薄编排」这句话"
fi
if [[ ! -f "$ORCH_AUDIT_PY" ]]; then
  check7_msg="${check7_msg:+$check7_msg; }$ORCH_AUDIT_PY 不存在"
fi

if [[ -z "$check7_msg" ]]; then
  ok 'SOUL.md 规则 + orchestration_audit.py 双落地'
else
  bad 'SOUL.md 规则 + orchestration_audit.py 双落地' "$check7_msg"
fi

exit "$FAIL"
