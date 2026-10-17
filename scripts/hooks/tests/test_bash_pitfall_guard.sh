#!/usr/bin/env bash
# bash_pitfall_guard.sh 的判别力自证：正例必须 deny 且落在对的规则上，反例必须放行（零输出）。
#
# 跑法：bash scripts/hooks/tests/test_bash_pitfall_guard.sh
# 变异验证：GUARD=<改坏一条规则的副本> bash 本脚本 → 该规则的正例必须转红，否则用例没有判别力。
#
# 规则 6 / 7 / 8 / 9 的判定器（zsh_wordsplit_check.py / zsh_modifier_check.py / docker_prune_check.py /
# git_safety_check.py，后两个共用 shell_segments.py）按 guard 自身所在目录查找，所以变异时要把 guard 副本和
# 这五个 .py 一起拷进同一个临时目录，再改其中一个。
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

# ---- 规则 7：未加花括号的 $NAME:<字母> 被 zsh 当修饰符吃掉 ----
# 正例钉 '${b}:r' 是为了同时验证 NAME / 字母 的提取与提示里的修法，不只是"被拦了"。
# 正例 1 = 2026-10-06 事故原句（:r 吞掉扩展名，15 次 push 全败）
expect_deny  "R7 原始事故 refs/heads/\$b:refs/heads/\$b" "git push origin \"refs/heads/\$b:refs/heads/\$b\"" '${b}:r'
expect_deny  "R7 循环里的同一句"               "for b in feat/x feat/y; do git push origin \"refs/heads/\$b:refs/heads/\$b\"; done" '${b}:r'
expect_deny  "R7 裸（无引号）\$dir:h"          "cd \$dir:h && ls"                                   '${dir}:h'
expect_deny  "R7 下划线开头的名字 \$_tag:e"    "echo \"\$_tag:extra\""                              '${_tag}:e'
expect_deny  "R7 双引号里的撇号不开单引号"     "echo \"it's \$b:r\"; echo 'x'"                      '${b}:r'
expect_deny  "R7 单引号段之后的裸 \$b:t"       "awk '{print \$1}' f; echo \$b:t"                    '${b}:t'
expect_allow "R7 \${b}: 已加花括号"            "git push origin \"refs/heads/\${b}:refs/heads/\${b}\""
expect_allow "R7 \$HOST:\$PORT"                "curl \$HOST:\$PORT/health"
expect_allow "R7 \$HOST:8080"                  "curl \$HOST:8080/health"
expect_allow "R7 PATH=\$PATH:/usr/bin"         "export PATH=\$PATH:/usr/bin"
expect_allow "R7 \"\$a\":rest 引号先于冒号收口" "echo \"\$a\":rest"
expect_allow "R7 \$1:x 位置参数"               "echo \$1:x \"\$2:y\""
expect_allow "R7 \$b: 冒号后跟空格"            "echo \"\$b: running\""
expect_allow "R7 \${b:-x} 默认值语法"          "echo \"\${b:-x}\""
expect_allow "R7 \${arr[@]} 数组展开"          "for x in \"\${arr[@]}\"; do echo \"\${x}:ok\"; done"
expect_allow "R7 \\\$ 转义的美元符"            "echo \"\\\$b:r\""
expect_allow "R7 单引号 awk \$NF\":\"\$2"      "awk '{print \$NF\":\"\$2}' f"
expect_allow "R7 单引号 perl 脚本里的 \$x:r"   "perl -e 'print \$x:r'"
expect_allow "R7 单引号 sed 脚本里的 \$x:h"    "sed 's/\$x:h/y/' f"
expect_allow "R7 单引号不平衡则放行不猜"       "echo 'unterminated \$b:r"

# ---- 规则 8：会删镜像 / build cache 的 docker 全局清理 ----
# 正例钉「命中 <标签>」，同时验证判定器认出的是哪一类，不只是"被拦了"。
# 正例 1 = 2026-10-07 事故原句（删掉 colar/pptagent-lab:v1d-f60543fb…，B3 硬阻塞）
expect_deny  "R8 原始事故 image prune -a -f; builder prune -a -f" "docker image prune -a -f; docker builder prune -a -f" "命中 docker image prune -a"
expect_deny  "R8 image prune -af"              "docker image prune -af"                             "命中 docker image prune -a"
expect_deny  "R8 image prune -fa"              "docker image prune -fa"                             "命中 docker image prune -a"
expect_deny  "R8 image prune --all --force"    "docker image prune --all --force"                   "命中 docker image prune -a"
expect_deny  "R8 -a 配 --filter 也不豁免"      "docker image prune -a --filter until=24h -f"        "命中 docker image prune -a"
expect_deny  "R8 system prune -af"             "docker system prune -af"                            "命中 docker system prune -a"
expect_deny  "R8 system prune --all"           "docker system prune --all --volumes"                "命中 docker system prune -a"
expect_deny  "R8 builder prune -a -f"          "docker builder prune -a -f"                         "命中 docker builder prune -a"
expect_deny  "R8 buildx prune --all --force"   "docker buildx prune --all --force"                  "命中 docker buildx prune -a"
expect_deny  "R8 buildx --builder x prune -a"  "docker buildx --builder desktop-linux prune -af"    "命中 docker buildx prune -a"
expect_deny  "R8 docker rmi 指定镜像"          "docker rmi colar/pptagent-lab:v1d"                  "命中 docker rmi"
expect_deny  "R8 docker image rm"              "docker image rm -f 4a875bff"                        "命中 docker image rm"
expect_deny  "R8 docker image remove 别名"     "docker image remove f29eecdc"                       "命中 docker image remove"
expect_deny  "R8 ; 之后"                       "docker ps; docker system prune -af"                 "命中 docker system prune -a"
expect_deny  "R8 && 之后"                      "df -h && docker image prune -af"                    "命中 docker image prune -a"
expect_deny  "R8 | 之后"                       "yes | docker system prune -a"                       "命中 docker system prune -a"
expect_deny  "R8 | xargs docker rmi"           "docker images -q | xargs -n 1 docker rmi"           "命中 docker rmi"
expect_deny  "R8 换行分隔的第二行"             $'df -h\ndocker builder prune -a -f'                 "命中 docker builder prune -a"
expect_deny  "R8 反斜杠续行"                   $'docker builder prune \\\n  --all -f'               "命中 docker builder prune -a"
expect_deny  "R8 env 赋值前缀"                 "DOCKER_HOST=unix:///var/run/docker.sock docker image prune -af" "命中 docker image prune -a"
expect_deny  "R8 --context xxx"                "docker --context colima image prune -a -f"          "命中 docker image prune -a"
expect_deny  "R8 -H tcp://…"                   "docker -H tcp://127.0.0.1:2375 system prune -af"    "命中 docker system prune -a"
expect_deny  "R8 --host=… rmi"                 "docker --host=unix:///x.sock rmi abc"               "命中 docker rmi"
expect_deny  "R8 sudo / 绝对路径 docker"       "sudo /usr/local/bin/docker rmi abc"                 "命中 docker rmi"
expect_deny  "R8 bash -c 包裹"                 "bash -c 'docker image prune -af'"                   "命中 docker image prune -a"
expect_deny  "R8 if 条件里"                    "if docker system prune -af; then echo ok; fi"       "命中 docker system prune -a"
expect_deny  "R8 \$(…) 命令替换里"             "echo \$(docker rmi abc)"                            "命中 docker rmi"
expect_deny  "R8 放行前缀只管紧跟的那一条"     "ALLOW_DOCKER_PRUNE=1 docker image prune -af && docker rmi abc" "命中 docker rmi"
expect_deny  "R8 放行值必须是 1"               "ALLOW_DOCKER_PRUNE=0 docker rmi abc"                "命中 docker rmi"
expect_deny  "R8 export 不是放行（非全局开关）" "export ALLOW_DOCKER_PRUNE=1; docker image prune -af" "命中 docker image prune -a"
expect_allow "R8 放行前缀 + image prune -a"    "ALLOW_DOCKER_PRUNE=1 docker image prune -a -f"
expect_allow "R8 放行前缀在 sudo 之前的赋值"   "sudo ALLOW_DOCKER_PRUNE=1 docker rmi abc"
expect_allow "R8 不带 -a 的 image prune"       "docker image prune -f"
expect_allow "R8 不带 -a 的 prune + --filter"  "docker image prune --filter until=24h -f"
expect_allow "R8 不带 -a 的 system prune"      "docker system prune -f"
expect_allow "R8 builder prune --reserved-space" "docker builder prune --reserved-space 10GB -f"
expect_allow "R8 container prune 不删镜像"     "docker container prune -f"
expect_allow "R8 docker ps -a 的 -a"           "docker ps -a"
expect_allow "R8 docker images -a"             "docker images -a"
expect_allow "R8 image ls --digests"           "docker image ls --digests | grep pptagent"
expect_allow "R8 inspect"                      "docker inspect colar/pptagent-lab:v1d && docker image inspect abc"
expect_allow "R8 --help"                       "docker image prune -a --help"
expect_allow "R8 grep 参数里的字样"            "grep -rn \"docker image prune -a\" /Users/colar/x/RUNBOOK.md"
expect_allow "R8 rg 单引号里的字样"            "rg 'docker rmi|docker system prune -af' docs/"
expect_allow "R8 echo 未加引号也只是参数"      "echo docker rmi abc"
expect_allow "R8 commit message 里提到"        "git commit -m \"docs: never run docker system prune -af\""
expect_allow "R8 注释里"                       "docker image ls # 别跑 docker system prune -af"
expect_allow "R8 heredoc 正文里"               $'cat > /Users/colar/x/RUNBOOK.md <<\'EOF\'\n不要运行 docker image prune -a\ndocker rmi abc\nEOF\necho done'
expect_allow "R8 docker run -a stdout 不是 prune" "docker run --rm -a stdout alpine echo hi"

# ---- 规则 9：跳过仓库钩子（--no-verify）/ 强推 ----
# 正例钉「命中 <标签>」：同时验证判定器认出的是哪一类、哪个旗标，不只是"被拦了"。
expect_deny  "R9 commit --no-verify"           "git commit --no-verify -m wip"                      "命中 git commit --no-verify"
expect_deny  "R9 commit -n"                    "git commit -n -m wip"                               "命中 git commit -n"
expect_deny  "R9 commit -anm 合写"             "git commit -anm wip"                                "命中 git commit -n"
expect_deny  "R9 -C 目录 + && 之后"            "git add -A && git -C /Users/colar/x commit --no-verify -m x" "命中 git commit --no-verify"
expect_deny  "R9 merge --no-verify"            "git merge --no-verify origin/main"                  "命中 git merge --no-verify"
expect_deny  "R9 push --no-verify"             "git push --no-verify origin feat/x"                 "命中 git push --no-verify"
expect_deny  "R9 push --force"                 "git push --force origin feat/x"                     "命中 git push --force"
expect_deny  "R9 push -f"                      "git push -f origin feat/x"                          "命中 git push -f"
expect_deny  "R9 push -uf 合写"                "git push -uf origin feat/x"                         "命中 git push -f"
expect_deny  "R9 --force-with-lease"           "git push --force-with-lease origin feat/x"          "命中 git push --force-with-lease"
expect_deny  "R9 --force-with-lease=ref:sha"   "git push --force-with-lease=feat/x:abc123 origin feat/x" "命中 git push --force-with-lease"
expect_deny  "R9 --force-if-includes"          "git push --force-if-includes origin feat/x"         "命中 git push --force-if-includes"
expect_deny  "R9 +refspec"                     "git push origin +feat/x"                            "命中 git push +feat/x"
expect_deny  "R9 引号里的 +refspec 照样是 refspec" "git push origin \"+HEAD:refs/heads/feat/x\""   "命中 git push +HEAD:refs/heads/feat/x"
expect_deny  "R9 旗标写在位置参数之后"         "cd /Users/colar/x && git push origin HEAD --force"  "命中 git push --force"
expect_deny  "R9 -c k=v 全局选项之后"          "git -c core.editor=true push -f origin x"           "命中 git push -f"
expect_deny  "R9 bash -c 包裹"                 "bash -c 'git push -f origin x'"                     "命中 git push -f"
expect_deny  "R9 for 循环里"                   "for b in a b; do git push -f origin \$b; done"      "命中 git push -f"
expect_deny  "R9 放行前缀只管紧跟的那一条"     "ALLOW_GIT_FORCE=1 git push -f origin x && git push -f origin y" "命中 git push -f"
expect_deny  "R9 export 不是放行（非全局开关）" "export ALLOW_GIT_FORCE=1; git push -f origin x"    "命中 git push -f"
expect_deny  "R9 放行值必须是 1"               "ALLOW_GIT_FORCE=0 git push -f origin x"             "命中 git push -f"
expect_deny  "R9 强推的前缀不放行跳钩子"       "ALLOW_GIT_FORCE=1 git push --no-verify origin x"    "命中 git push --no-verify"
expect_deny  "R9 跳钩子的前缀不放行强推"       "ALLOW_NO_VERIFY=1 git push --no-verify --force origin x" "命中 git push --force"
expect_allow "R9 ALLOW_GIT_FORCE=1 放行强推"   "ALLOW_GIT_FORCE=1 git push --force-with-lease origin x"
expect_allow "R9 ALLOW_NO_VERIFY=1 放行跳钩子" "ALLOW_NO_VERIFY=1 git commit --no-verify -m x"
expect_allow "R9 放行前缀在 sudo 之后的赋值"   "sudo ALLOW_GIT_FORCE=1 git push -f origin x"
expect_allow "R9 push -n 是 --dry-run"         "git push -n origin feat/x"
expect_allow "R9 --dry-run 演习不拦"           "git push --dry-run --force origin feat/x"
expect_allow "R9 --delete 删远端分支"          "git push origin --delete feat/x"
expect_allow "R9 -d 删远端分支"                "git push origin -d feat/x"
expect_allow "R9 :分支 删远端分支"             "git push origin :feat/x"
expect_allow "R9 普通推送 -u"                  "git push -u origin feat/x"
expect_allow "R9 -o 的值不是旗标"              "git push -o ci.skip origin feat/x"
expect_allow "R9 --no-force-with-lease 是取消" "git push --no-force-with-lease origin feat/x"
expect_allow "R9 commit -mn：n 是 message"     "git commit -mn"
expect_allow "R9 commit -uno：no 是 -u 的值"   "git commit -uno -m x"
expect_allow "R9 commit --verify"              "git commit --verify -m x"
expect_allow "R9 commit message 里提到"        "git commit -m \"docs: never use --no-verify or git push --force\""
expect_allow "R9 merge -n 是 --no-stat"        "git merge -n origin/main"
expect_allow "R9 git stash push 不是 push"     "git stash push -m wip"
expect_allow "R9 fetch --force 不碰远端"       "git fetch --force origin"
expect_allow "R9 grep 参数里的字样"            "grep -rn \"git push --force\" /Users/colar/x/docs"
expect_allow "R9 echo 未加引号也只是参数"      "echo git push --force"
expect_allow "R9 heredoc 正文里"               $'cat > /Users/colar/x/AGENTS.md <<\'EOF\'\n禁止 git push --force 与 git commit --no-verify\nEOF\necho done'
expect_allow "R9 --help"                       "git push --force --help"

echo "PASS $pass / FAIL $fail"
[ "$fail" -eq 0 ]
