#!/usr/bin/env bash
# bash_pitfall_guard.sh 的判别力自证：正例必须 deny 且落在对的规则上，反例必须放行（零输出）。
#
# 跑法：bash scripts/hooks/tests/test_bash_pitfall_guard.sh
# 变异验证：GUARD=<改坏一条规则的副本> bash 本脚本 → 该规则的正例必须转红，否则用例没有判别力。
#
# 每条规则至少 2 正 2 反，反例优先覆盖规则本身明写的放行例外（venv 绝对路径、cd 锚定、引号等），
# 因为那些例外才是最容易被后来人"顺手收紧"改坏的部分。
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GUARD=${GUARD:-$HERE/../bash_pitfall_guard.sh}
pass=0
fail=0

run_guard() {
  # $1 = 命令串（可多行）→ 包成 PreToolUse(Bash) 的 stdin JSON 喂给 guard，
  # 再把 guard 的 JSON 解回 "deny: <reason>" 一行文本（reason 是中文，json.dumps 会转成 \uXXXX，直接 grep 对不上）
  printf '%s' "$1" | python3 -c 'import json,sys
print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.stdin.read()}}))' | bash "$GUARD" | python3 -c 'import json,sys
raw = sys.stdin.read().strip()
if raw:
    out = json.loads(raw)["hookSpecificOutput"]
    print(out["permissionDecision"] + ": " + out["permissionDecisionReason"])'
}

expect_deny() {
  # $1 标签 · $2 命令串 · $3 reason 必含的片段（把 deny 钉到具体哪条规则，防止"被别的规则顺手拦下"冒充通过）
  local out
  out=$(run_guard "$2")
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
  out=$(run_guard "$2")
  if [ -z "$out" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL[allow] $1"
    echo "   cmd: $2"
    echo "   got: $out"
  fi
}

# ---- 规则 1：--include/--exclude 的 glob 未加引号 ----
expect_deny  "R1 裸 --include=*.py"            "grep -rn foo --include=*.py ."                     "include"
expect_deny  "R1 裸 --exclude=*.pyc"           "grep -rn foo --exclude=*.pyc src"                  "include"
expect_allow "R1 单引号 --include='*.py'"      "grep -rn foo --include='*.py' ."
expect_allow "R1 双引号 --include=\"*.py\""    "grep -rn foo --include=\"*.py\" ."

# ---- 规则 2：路由组 / 动态段括号路径未加引号 ----
expect_deny  "R2 裸 (console) 路径"            "git diff frontend/src/app/(console)/page.tsx"      "glob 元字符"
expect_deny  "R2 裸 [id] 路径"                 "test -f src/app/hub/[id]/page.tsx"                 "glob 元字符"
expect_allow "R2 单引号包住 (console)"         "git diff 'frontend/src/app/(console)/page.tsx'"
expect_allow "R2 双引号包住 [id]"              "ls \"src/app/[id]\""
expect_allow "R2 \$(git rev-parse) 不是路径括号" "git log \$(git rev-parse HEAD)..HEAD --oneline"

# ---- 规则 3：系统 python3 跑 pytest ----
expect_deny  "R3 python3 -m pytest"            "python3 -m pytest api/tests -q"                    "系统 python3"
expect_deny  "R3 python3 -m unittest"          "cd /Users/colar/x && python3 -m unittest discover" "系统 python3"
expect_allow "R3 绝对路径 .venv 的 python"     "/Users/colar/Desktop/x/.venv/bin/python -m pytest -q"
expect_allow "R3 cd 锚定后 .venv/bin/python3"  "cd /Users/colar/Desktop/x && .venv/bin/python3 -m pytest -q"
expect_allow "R3 python3 -c 不是跑 pytest"     "python3 -c \"import pytest; print(pytest.__version__)\""

# ---- 规则 4：相对路径 source .venv / 裸 .venv 可执行 ----
expect_deny  "R4 source .venv/bin/activate"    "source .venv/bin/activate && pytest -q"            "cwd 会漂"
expect_deny  "R4 裸 .venv/bin/python"          ".venv/bin/python scripts/x.py"                     "cwd 会漂"
expect_allow "R4 绝对路径 .venv"               "/Users/colar/Desktop/创业/fabric-agent-demo/.venv/bin/python -m pytest"
expect_allow "R4 同条命令先 cd 绝对路径"       "cd /Users/colar/Desktop/x && .venv/bin/python -m pytest"
expect_allow "R4 cd \$(git rev-parse --show-toplevel) 锚定" "cd \$(git rev-parse --show-toplevel) && source .venv/bin/activate"

# ---- 规则 5：管道后判退出码 ----
expect_deny  "R5 管道后 echo \$?"              "pytest -q | tail -3; echo \$?"                     "管道"
expect_deny  "R5 tee 后 if [ \$? -ne 0 ]"      $'make 2>&1 | tee log.txt\nif [ $? -ne 0 ]; then exit 1; fi' "管道"
expect_allow "R5 无管道的 \$?"                 "pytest -q; echo \$?"
expect_allow "R5 管道用 pipestatus"            "pytest -q | tail -3; echo \${pipestatus[1]}"

# ---- 规则 6：zsh 不对裸 $VAR 分词 ----
# 正例 1 = 2026-09-15 织锦原始实例（grep -rlE 管道赋值 → pytest $FILES，30 路径当 1 参数）
expect_deny  "R6 原始实例 grep -rlE → pytest \$FILES" \
  $'R=/Users/colar/Desktop/创业/fabric-agent-demo\nFILES=$(grep -rlE \'routers\\.hub\' $R/api/tests --include=\'*.py\' | grep -v conftest)\nAPI_ENV=dev $R/.venv/bin/python -m pytest $FILES -q -p no:cacheprovider' \
  "分词"
expect_deny  "R6 find → for f in \$FILES"      "FILES=\$(find src -name '*.py'); for f in \$FILES; do wc -l \$f; done" "分词"
expect_deny  "R6 git diff --name-only → \${CHANGED}" $'CHANGED=$(git diff --name-only HEAD~1)\nnpx eslint ${CHANGED}' "分词"
expect_deny  "R6 反引号 ls → wc -l \$LIST"     "LIST=\`ls docs\`; wc -l \$LIST"                     "分词"
expect_deny  "R6 export + rg -l → pytest \$TESTS" "export TESTS=\$(rg -l 'hub' api/tests); pytest \$TESTS" "分词"
expect_allow "R6 \${=FILES} 已显式分词"        "FILES=\$(find src -name '*.py'); pytest \${=FILES}"
expect_allow "R6 \"\$FILES\" 加引号是有意单参数" "FILES=\$(find src -name '*.py'); pytest \"\$FILES\""
expect_allow "R6 单行生产者 git rev-parse"     "SHA=\$(git rev-parse HEAD); git log \$SHA..HEAD --oneline"
expect_allow "R6 非列表生产者 git log -1"      "MSG=\$(git log -1 --format=%s); git commit -m \$MSG"
expect_allow "R6 echo \$FILES | wc -l 数行是对的" "FILES=\$(find src -name '*.py'); echo \$FILES | wc -l"
expect_allow "R6 内联 \$(find) 会分词"         "pytest \$(find api/tests -name 'test_*.py') -q"
expect_allow "R6 数组 FILES=(\$(find))"        "FILES=(\$(find src -name '*.py')); pytest \$FILES"
expect_allow "R6 整条包在 bash -c 里"          "bash -c 'FILES=\$(find src -name \"*.py\"); pytest \$FILES'"
expect_allow "R6 setopt shwordsplit 已开"      "setopt shwordsplit; FILES=\$(find src -name '*.py'); pytest \$FILES"
expect_allow "R6 [ -n \$FILES ] 不吃列表"      "FILES=\$(find src -name '*.py'); [ -n \$FILES ] && echo ok"
expect_allow "R6 here-string <<< \$FILES"      "FILES=\$(git ls-files '*.py'); while read -r f; do wc -l \$f; done <<< \$FILES"
expect_allow "R6 只赋值不消费"                 "FILES=\$(find src -name '*.py'); COUNT=\$FILES"

echo "PASS $pass / FAIL $fail"
[ "$fail" -eq 0 ]
