#!/usr/bin/env bash
# git_config_pollution_check.sh 的判别力自证：
#   P 组（必须命中）：user.name=Test / user.email=test@example.com（大小写不敏感）/ 有工作树却 core.bare=true；
#                     cwd 在子目录、在 linked worktree（报主仓）、不在 git 仓（只查织锦主仓）；
#                     PostToolUse 下 git commit / git -C x commit / git rebase / pytest / check_all 都要触发；
#                     手写格式（节名/键名大小写、引号、行内注释、裸键 bare、同行节头）也要认
#   S 组（必须静默）：干净仓、非 git 目录、PostToolUse 无关命令（含「输出里有 pytest 但命令不是」）、
#                     近似值（Testa / test@example.org）、真 bare 仓的 core.bare=true、core.bare=false、
#                     带子节 / 别的节里的同名键、core.bare 先真后假（取最后一次）、坏 stdin
#   R 组：只读 —— 跑完 config 字节不变；按 hook 打印的恢复命令执行后必须转为静默（命令本身是对的）
#   E 组：调用方漏进来的 GIT_DIR 指向干净仓时，不许把 cwd 所在脏仓遮住
#   T 组：耗时上限（宽松兜底，目标 < 100ms，见输出里的实测值）
#
# 跑法：bash scripts/hooks/tests/test_git_config_pollution_check.sh
# 变异验证：HOOK_SRC=<改坏一条规则的副本> bash 本脚本 → 对应用例必须转红，否则该用例没有判别力。
#
# 隔离（本测试要防的正是「测试里起的 git 打到真仓库」）：
#   - 开头剥掉 GIT_DIR / GIT_INDEX_FILE / GIT_WORK_TREE / GIT_COMMON_DIR；所有仓库都在 mktemp 目录里 git init
#   - GIT_CONFIG_GLOBAL=/dev/null + GIT_CONFIG_NOSYSTEM=1：全局 hooksPath / 模板不在临时仓里触发
#   - hook 把织锦主仓路径写死（不开环境变量后门），这里照 test_fabric_docs_cleanup_notice.sh 的做法
#     sed 一份把它换成临时假仓的副本来跑，绝不读写真实织锦仓
#   - 结尾校验本仓 .git/config 前后字节一致
# 写法上的注意：判断退出码一律不走管道（管道后取 $? 既脆也会被 bash_pitfall_guard 拦）。
set -u
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK_SRC=${HOOK_SRC:-$HERE/../git_config_pollution_check.sh}
SELF_REPO_CONFIG=$(cd "$HERE" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/config
SELF_SUM_BEFORE=$(shasum "$SELF_REPO_CONFIG" 2>/dev/null)
pass=0
fail=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)
FAKE_FABRIC="$TMP/fabric-agent-demo"
HOOK="$TMP/hook_under_test.sh"
sed "s#/Users/colar/Desktop/创业/fabric-agent-demo#$FAKE_FABRIC#g" "$HOOK_SRC" > "$HOOK"
NONGIT="$TMP/not-a-repo"
mkdir -p "$NONGIT"
STDIN_FILE="$TMP/.stdin.json"
OUT="$TMP/.stdout.txt"
ERR="$TMP/.stderr.txt"

make_repo() {   # $1 路径：建一个有一次提交的普通仓
  git init -q "$1"
  git -C "$1" -c user.name=t -c user.email=t@localhost commit -q --allow-empty -m init
}
reset_fabric() { rm -rf "$FAKE_FABRIC"; make_repo "$FAKE_FABRIC"; }

# 写 stdin 夹具：$1 事件(空 = 不带事件字段，模拟手动) · $2 cwd · $3 Bash 命令 · $4 tool_response.stdout
build_payload() {
  python3 -c '
import json, sys
event, cwd, cmd, stdout, path = sys.argv[1:6]
d = {"session_id": "t", "cwd": cwd}
if event:
    d["hook_event_name"] = event
if event == "PostToolUse":
    d.update(tool_name="Bash", tool_input={"command": cmd, "description": "x"},
             tool_response={"stdout": stdout, "stderr": "", "interrupted": False})
open(path, "w").write(json.dumps(d))' "$1" "$2" "${3:-}" "${4:-}" "$STDIN_FILE"
}

RC=0
run_hook() {    # 参数同 build_payload；hook 进程本身的 cwd 固定在非 git 目录，只靠 stdin 的 cwd 定位
  build_payload "$@"
  RC=0
  ( cd "$NONGIT" && bash "$HOOK" ) < "$STDIN_FILE" > "$OUT" 2> "$ERR" || RC=$?
}

expect_hit() {  # $1 标签 · $2 输出必含片段 · 其余透传 run_hook
  local label=$1 needle=$2; shift 2
  run_hook "$@"
  if [ "$RC" = 0 ] && grep -qF -- "$needle" "$OUT"; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL[hit] $label"; echo "   needle: $needle"
    echo "   got(rc=$RC): $(head -c 400 "$OUT") | stderr: $(head -c 200 "$ERR")"; fi
}
expect_silent() {  # $1 标签 · 其余透传 run_hook；必须 exit 0 且 stdout/stderr 全空
  local label=$1; shift
  run_hook "$@"
  if [ "$RC" = 0 ] && [ ! -s "$OUT" ] && [ ! -s "$ERR" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL[silent] $label"
    echo "   got(rc=$RC): $(head -c 400 "$OUT") | stderr: $(head -c 200 "$ERR")"; fi
}

reset_fabric
CLEAN="$TMP/clean"; make_repo "$CLEAN"

# ---------------- P 组：必须命中 ----------------
R1="$TMP/r-name"; make_repo "$R1"; git -C "$R1" config --local user.name Test
expect_hit "P1 user.name=Test 报键名"           "user.name=Test"                         SessionStart "$R1"
expect_hit "P1b 报恢复命令"                     "git -C \\\"$R1\\\" config --local --unset user.name" SessionStart "$R1"
expect_hit "P1c 提醒先查 linked worktree"        "linked worktree"                        SessionStart "$R1"

R2="$TMP/r-email"; make_repo "$R2"; git -C "$R2" config --local user.email TEST@Example.COM
expect_hit "P2 user.email 大小写不敏感"          "--unset user.email"                     SessionStart "$R2"

R3="$TMP/r-upper"; make_repo "$R3"; git -C "$R3" config --local user.name TEST
expect_hit "P3 user.name=TEST 大写也中"          "user.name=TEST"                         SessionStart "$R3"

R4="$TMP/r-bare"; make_repo "$R4"; mkdir -p "$R4/sub"; git -C "$R4" config --local core.bare true
expect_hit "P4 有工作树却 core.bare=true（cwd 在子目录）" "config --local core.bare false"  SessionStart "$R4/sub"

R5="$TMP/r-wtmain"; make_repo "$R5"; git -C "$R5" worktree add -q --detach "$TMP/r-wtlinked"
git -C "$R5" config --local user.name Test
expect_hit "P5 cwd 在 linked worktree → 报主仓根"  "仓库: $R5 "                             SessionStart "$TMP/r-wtlinked"

git -C "$FAKE_FABRIC" config --local user.email test@example.com
expect_hit "P6 cwd 是干净仓 → 仍固定查织锦主仓"   "仓库: $FAKE_FABRIC "                    SessionStart "$CLEAN"
expect_hit "P7 cwd 非 git 目录 → 只查织锦主仓"     "仓库: $FAKE_FABRIC "                    SessionStart "$NONGIT"
reset_fabric

expect_hit "P8 PostToolUse git commit"          "user.name=Test"  PostToolUse "$R1" "git commit -m wip"
expect_hit "P9 PostToolUse git -C <path> commit" "user.name=Test" PostToolUse "$R1" "git -C $R1 commit -m wip"
expect_hit "P10 PostToolUse git rebase"         "user.name=Test"  PostToolUse "$R1" "git rebase origin/main"
expect_hit "P11 PostToolUse pytest"             "user.name=Test"  PostToolUse "$R1" ".venv/bin/python -m pytest tests/ -q"
expect_hit "P12 PostToolUse check_all"          "user.name=Test"  PostToolUse "$R1" "bash scripts/check_all.sh"
# 事件 JSON 契约：PostToolUse 的纯 stdout 进不了模型上下文，必须走 hookSpecificOutput.additionalContext
run_hook PostToolUse "$R1" "git commit -m wip"
if python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
h = d["hookSpecificOutput"]
assert h["hookEventName"] == "PostToolUse" and "user.name=Test" in h["additionalContext"]
assert "user.name" in d["systemMessage"]' "$OUT" 2>/dev/null; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL[json] P13 PostToolUse 输出是合法 JSON 且带 additionalContext"; echo "   got: $(head -c 300 "$OUT")"; fi
run_hook SessionStart "$R1"
if python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["hookSpecificOutput"]["hookEventName"] == "SessionStart"' "$OUT" 2>/dev/null; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL[json] P14 SessionStart 输出 hookEventName=SessionStart"; fi
# 手写格式（hook 用自带最小解析器，不起 git）：节名大小写、键名大小写、引号、行内注释、裸键 = true、同行节头
R9="$TMP/r-handwritten"; make_repo "$R9"
printf '[User]\n\tName = "Test" ; written by hand\n' >> "$R9/.git/config"
expect_hit "P15 [User] Name = \"Test\" ; 注释 也认"   "user.name=Test"        SessionStart "$R9"
R10="$TMP/r-barekey"; make_repo "$R10"; printf '[core]\n\tbare\n' >> "$R10/.git/config"
expect_hit "P16 裸写 bare（无 =）按 true 算"          "core.bare=true"        SessionStart "$R10"
R11="$TMP/r-inline"; make_repo "$R11"; printf '[core] bare = yes\n' >> "$R11/.git/config"
expect_hit "P17 [core] bare = yes 同行节头"           "core.bare=yes"         SessionStart "$R11"

# ---------------- S 组：必须静默 ----------------
expect_silent "S1 干净仓 + 干净织锦"                       SessionStart "$CLEAN"
expect_silent "S2 非 git 目录 + 干净织锦"                   SessionStart "$NONGIT"
expect_silent "S3 PostToolUse 无关命令（脏仓也跳过）"        PostToolUse "$R1" "ls -la"
expect_silent "S4 PostToolUse git status 不触发"           PostToolUse "$R1" "git status --short"
expect_silent "S5 输出里有 pytest/git commit 但命令无关"     PostToolUse "$R1" "cat notes.txt" "ran pytest then git commit"
R6="$TMP/r-near"; make_repo "$R6"
git -C "$R6" config --local user.name "Testa Person"; git -C "$R6" config --local user.email test@example.org
expect_silent "S6 近似值不误报（Testa / example.org）"       SessionStart "$R6"
git init -q --bare "$TMP/real-bare.git"
expect_silent "S7 真 bare 仓的 core.bare=true 不报"         SessionStart "$TMP/real-bare.git"
R7="$TMP/r-barefalse"; make_repo "$R7"; git -C "$R7" config --local core.bare false
expect_silent "S8 core.bare=false（织锦现状）不报"           SessionStart "$R7"
R12="$TMP/r-subsection"; make_repo "$R12"
printf '[user "alias"]\n\tname = Test\n[remote "origin"]\n\temail = test@example.com\n' >> "$R12/.git/config"
expect_silent "S12 带子节的 [user \"x\"] / 别的节里同名键不报"  SessionStart "$R12"
R13="$TMP/r-baretrue-then-false"; make_repo "$R13"; printf '[core]\n\tbare = true\n[core]\n\tbare = false\n' >> "$R13/.git/config"
expect_silent "S13 core.bare 先 true 后 false，取最后一次"      SessionStart "$R13"
rm -rf "$FAKE_FABRIC"
expect_silent "S9 织锦主仓不存在 + 非 git cwd"              SessionStart "$NONGIT"
reset_fabric
printf 'not json' > "$STDIN_FILE"; RC=0
( cd "$NONGIT" && bash "$HOOK" ) < "$STDIN_FILE" > "$OUT" 2> "$ERR" || RC=$?
if [ "$RC" = 0 ] && [ ! -s "$OUT" ] && [ ! -s "$ERR" ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL[silent] S10 坏 stdin 不报错"; fi
: > "$STDIN_FILE"; RC=0
( cd "$NONGIT" && bash "$HOOK" ) < "$STDIN_FILE" > "$OUT" 2> "$ERR" || RC=$?
if [ "$RC" = 0 ] && [ ! -s "$OUT" ] && [ ! -s "$ERR" ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL[silent] S11 空 stdin（手动跑）不报错"; fi

# ---------------- R 组：只读 + 恢复命令可用 ----------------
R8="$TMP/r-all"; make_repo "$R8"
git -C "$R8" config --local user.name Test; git -C "$R8" config --local user.email test@example.com
git -C "$R8" config --local core.bare true
sum_before=$(shasum "$R8/.git/config")
run_hook SessionStart "$R8"
if [ "$(shasum "$R8/.git/config")" = "$sum_before" ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL[readonly] R1 hook 改动了 config —— 必须只读"; fi
# 手动模式拿纯文本，逐条执行 hook 给出的恢复命令，之后必须静默
build_payload "" "$R8"; ( cd "$NONGIT" && bash "$HOOK" ) < "$STDIN_FILE" > "$OUT" 2> "$ERR"
fix_count=0
while IFS= read -r line; do
  fix_count=$((fix_count + 1)); eval "${line#*恢复: }"
done < <(grep '恢复: git -C' "$OUT")
expect_silent "R2 执行 hook 打印的 ${fix_count} 条恢复命令后转为静默" SessionStart "$R8"
if [ "$fix_count" = 3 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL R3 三个键应给出 3 条恢复命令，实得 $fix_count"; fi

# ---------------- E 组：漏进来的 GIT_DIR 不许遮住 cwd 的脏仓 ----------------
build_payload SessionStart "$R1"; RC=0
( cd "$NONGIT" && GIT_DIR="$CLEAN/.git" bash "$HOOK" ) < "$STDIN_FILE" > "$OUT" 2> "$ERR" || RC=$?
if [ "$RC" = 0 ] && grep -qF "仓库: $R1 " "$OUT"; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL[env] E1 GIT_DIR 指向干净仓时仍须报 cwd 所在脏仓"; echo "   got: $(head -c 300 "$OUT")"; fi

# ---------------- T 组：耗时 ----------------
ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
build_payload SessionStart "$R1"
t0=$(ms); for _ in 1 2 3 4 5; do ( cd "$NONGIT" && bash "$HOOK" ) < "$STDIN_FILE" > /dev/null 2>&1; done; t1=$(ms)
check_avg=$(( (t1 - t0) / 5 ))
build_payload PostToolUse "$R1" "ls -la"
t0=$(ms); for _ in 1 2 3 4 5; do ( cd "$NONGIT" && bash "$HOOK" ) < "$STDIN_FILE" > /dev/null 2>&1; done; t1=$(ms)
skip_avg=$(( (t1 - t0) / 5 ))
echo "timing: 检查路径 ${check_avg}ms / 无关命令跳过 ${skip_avg}ms（目标 < 100ms）"
# 兜底上限放宽到 250ms：机器繁忙时不误红，但抓得住「误把 git status 之类重操作塞进 hook」的数量级回归
if [ "$check_avg" -lt 250 ] && [ "$skip_avg" -lt 250 ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL[time] T1 平均耗时超 250ms"; fi

# ---------------- 隔离自证 ----------------
if [ "$(shasum "$SELF_REPO_CONFIG" 2>/dev/null)" = "$SELF_SUM_BEFORE" ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL ISO 本仓 $SELF_REPO_CONFIG 在测试期间被改动 —— 隔离失效，立刻人工检查"; fi

echo "PASS $pass / FAIL $fail"
[ "$fail" -eq 0 ]
