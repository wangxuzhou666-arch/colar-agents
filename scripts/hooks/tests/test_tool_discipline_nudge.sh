#!/usr/bin/env bash
# tool_discipline_nudge.sh 的判别力自证：正例（整读文件、.env）必须 deny，反例（Read 做不到的用法、单文件有界读取、
# 复合命令）必须放行（零输出）。
#
# 跑法：bash scripts/hooks/tests/test_tool_discipline_nudge.sh
# 变异验证：HOOK=<改坏的副本> bash 本脚本 → 对应用例必须转红，否则用例没有判别力。
#   · .env 检查挪到 tail 整类放行之后 → `tail ~/.env` 转红（安全耦合：放行分支不能先于 .env 检查）
#   · 删掉 tail 整类放行 → tail 的放行例转红
#   · 删掉正则地址 / 多文件 head 放行 → 对应放行例转红
#   · 删掉有界读取放行 → sed -n A,Bp / head -N 的放行例转红
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK=${HOOK:-$HERE/../tool_discipline_nudge.sh}
pass=0
fail=0

run_hook() {
  # $1 = 命令串 → 包成 PreToolUse(Bash) 的 stdin JSON 喂给 hook，
  # 再把 JSON 解回 "deny: <reason>" 一行文本（reason 是中文 + emoji，json.dumps 会转成 \uXXXX，直接 grep 对不上）
  printf '%s' "$1" | python3 -c 'import json,sys
print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.stdin.read()}}))' | bash "$HOOK" | python3 -c 'import json,sys
raw = sys.stdin.read().strip()
if raw:
    out = json.loads(raw)["hookSpecificOutput"]
    print(out["permissionDecision"] + ": " + out["permissionDecisionReason"])'
}

expect_deny() {
  # $1 标签 · $2 命令串 · $3 reason 必含的片段（区分 .env 强措辞与整读提示）
  local out
  out=$(run_hook "$2")
  if printf '%s' "$out" | grep -q '^deny: ' && printf '%s' "$out" | grep -qF -- "$3"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL[deny] $1"
    echo "   cmd: $2"
    echo "   got: ${out:-<allow>}"
  fi
}

expect_allow() {
  # $1 标签 · $2 命令串
  local out
  out=$(run_hook "$2")
  if [ -z "$out" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL[allow] $1"
    echo "   cmd: $2"
    echo "   got: $out"
  fi
}

READ_HINT='Read file_path=<绝对路径> offset=<行> limit=<行数>'
ENV_HINT='禁止读 .env'

# ---- 整读文件 → deny，提示带 Read 的 offset / limit ----
expect_deny  "cat 整读"                         "cat src/x.py"                                     "$READ_HINT"
expect_deny  "cat 多文件"                       "cat src/a.py src/b.py"                            "$READ_HINT"
expect_deny  "head 不带行数"                    "head src/x.py"                                    "$READ_HINT"
expect_deny  "sed -n p 整读"                    "sed -n p src/x.py"                                "$READ_HINT"
expect_deny  "sed -n A,\$p 读到文件尾"          "sed -n '10,\$p' src/x.py"                         "$READ_HINT"
expect_deny  "deny 文案不再说「全灌进 context」" "cat src/x.py"                                     "整读文件请用 Read"

# ---- .env 类：强措辞，且排在所有放行分支之前 ----
expect_deny  "cat .env"                         "cat .env"                                         "$ENV_HINT"
expect_deny  "head -5 .env.local"               "head -5 .env.local"                               "$ENV_HINT"
expect_deny  "tail ~/.env（tail 整类放行不能绕过）" "tail ~/.env"                                   "$ENV_HINT"
expect_deny  "tail -n 3 .env"                   "tail -n 3 /Users/colar/x/.env"                    "$ENV_HINT"
expect_deny  "sed -n 1,5p .env（有界读取也拦）" "sed -n 1,5p ~/.env"                               "$ENV_HINT"
expect_deny  "sed 正则地址读 .env"              "sed -n '/KEY/p' .env"                             "$ENV_HINT"

# ---- tail 整类放行：Read 没有取末尾 N 行的能力 ----
expect_allow "tail -n N 读后台任务 .output"     "tail -n 40 /private/tmp/claude-501/x/tasks/abc.output"
expect_allow "tail -f /dev/null"                "tail -f /dev/null"
expect_allow "tail -c N"                        "tail -c 2000 /Users/colar/x/server.log"
expect_allow "tail 不带选项"                    "tail /Users/colar/x/server.log"

# ---- Read 做不到的：带正则地址的 sed、多文件 head ----
expect_allow "sed -n 正则范围"                  "sed -n '/foo/,/bar/p' f.py"
expect_allow "sed -n 单正则"                    "sed -n '/foo/p' f.py"
expect_allow "sed -n 行号到正则"                "sed -n '3,/bar/p' f.py"
expect_allow "多文件 head -n N"                 "head -n 5 a.txt b.txt"
expect_allow "多文件 head 不带行数"             "head a.txt b.txt"

# ---- 单文件有界读取：静默放行（Colar 2026-11-07 拍板） ----
expect_allow "sed -n A,Bp"                      "sed -n 10,40p src/x.py"
expect_allow "sed -n 'A,Bp' 带引号"             "sed -n '10,40p' src/x.py"
expect_allow "sed -n Np 单行"                   "sed -n '5p' src/x.py"
expect_allow "head -N"                          "head -50 src/x.py"
expect_allow "head -n N"                        "head -n 50 src/x.py"
expect_allow "head -nN 紧贴"                    "head -n50 src/x.py"
expect_allow "head -c N"                        "head -c 200 src/x.py"
expect_allow "head --lines=N"                   "head --lines=20 src/x.py"

# ---- 复合命令 / 非读文件：放行（头注明写的设计，不扩展） ----
expect_allow "cat 进管道"                       "cat src/x.py | wc -l"
expect_allow "cd X && sed -n"                   "cd /Users/colar/x && sed -n 1,5p src/x.py"
expect_allow "重定向"                           "cat src/a.py > /tmp/a.copy"
expect_allow "命令替换"                         "echo \$(cat src/x.py)"
expect_allow "grep 不归这个 hook 管"            "grep -rn foo src"
expect_allow "ls"                               "ls -la"

echo "PASS $pass / FAIL $fail"
[ "$fail" -eq 0 ]
