#!/usr/bin/env bash
# push_email_guard.sh 的判别力自证：正例必须 deny 且文案点名命中的仓 / 身份，反例必须放行（零输出）。
#
# 跑法：bash scripts/hooks/tests/test_push_email_guard.sh
# 变异验证：GUARD=<改坏的副本> bash 本脚本 → 对应用例必须转红，否则用例没有判别力。判定器 push_email_check.py 按 guard
#   所在目录查找，并 import 同目录的 ai_attribution_check.py / shell_segments.py / git_safety_check.py，变异时把 guard 和
#   这四个 .py 一起拷进同一个临时目录，再改其中一个。
#   2026-11-05 实跑 9 个变异体全部转红：noreply 白名单放开（P1/P4/P8 等 12 例）、不排除已推送提交（P3）、
#   忽略本条命令里新建的提交（P8）、查不到可见性按私有放行（P6）、不看提交者（P4）、默认 remote 一律 origin（P15）、
#   不打码（G1/P1b）、不认 --delete（P10）、refspec 取冒号后的目的端（P11/P12）。
#   2026-11-07 gh 可靠性补丁（P6b/P6c、P22-P25）实跑 4 个变异体全部转红：visibility 不把回退目录并进 env（P22）、
#   修法文案改回 git config（P24/P25）、核实提示加到 public 分支（P24）、拦截文案不带原因（P6b/P23）。
#   8 秒超时分支不进测试（假 gh 要 sleep 8 秒太慢），由人工读代码保证。
#
# 分组：P = 拦 / 放的判定；G = 输出契约与开销；ISO = 隔离自证。
#
# 隔离：仓库都在 mktemp 目录里 git init，remote 只是写进配置的 URL；「已推送」用 update-ref 造 remote-tracking 分支，
#   不联网。gh 换成 PATH 最前面的假脚本，按 owner/repo 回答 private 字段并记下每次调用。GIT_CONFIG_GLOBAL=/dev/null +
#   GIT_CONFIG_NOSYSTEM=1；hook 进程的 cwd 固定在非 git 目录，只靠 payload 里的 cwd 定位。结尾校验本仓 .git/config 字节未变。
#   P22/P23 用 env -i 起 hook、PATH 只给 /usr/bin:/bin（有 git、python3，没有 gh），回退目录靠 PUSH_EMAIL_GH_DIRS 指向假 gh 所在目录。
# 邮箱一律用 example.com 的假地址：本仓公开。判断退出码一律不走管道。
set -u
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GUARD=${GUARD:-$HERE/../push_email_guard.sh}
SELF_REPO_CONFIG=$(cd "$HERE" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/config
SELF_SUM_BEFORE=$(shasum "$SELF_REPO_CONFIG" 2>/dev/null)
pass=0
fail=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)
FAKE_HOME="$TMP/home"
NONGIT="$TMP/not-a-repo"
FAKEBIN="$TMP/bin"
GH_LOG="$TMP/gh-calls.log"
mkdir -p "$FAKE_HOME" "$NONGIT" "$FAKEBIN"
: > "$GH_LOG"

PRIVATE=colar@example.com          # 代表私人邮箱
UPSTREAM=maintainer@example.com    # 上游维护者：他的提交已在 origin 上
NOREPLY=1+tester@users.noreply.github.com

# 假 gh：只认 gh api repos/<owner>/<repo> --jq .private；colar-memory 是私有仓，flaky/* 模拟断网
cat > "$FAKEBIN/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GH_LOG"
case "\$2" in
  repos/wangxuzhou666-arch/colar-memory) echo true ;;
  repos/flaky/*) exit 1 ;;
  repos/*) echo false ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKEBIN/gh"

commit_as() {   # $1 仓库 · $2 作者邮箱 · $3 提交者邮箱 · $4 消息：做一次空提交
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL="$3" git -C "$1" -c user.name=t -c user.email="$2" \
    commit -q --allow-empty -m "$4"
}
mk_fork() {     # $1 路径：照抄 slime 的布局，origin = 上游（main 已推送），fork = 自己的 fork，HEAD 在分支 fix 上
  git init -q -b main "$1"
  git -C "$1" remote add origin https://github.com/THUDM/slime
  git -C "$1" remote add fork https://github.com/wangxuzhou666-arch/slime.git
  commit_as "$1" "$UPSTREAM" "$UPSTREAM" "upstream work"
  git -C "$1" update-ref refs/remotes/origin/main HEAD
  git -C "$1" switch -q -c fix
}
mk_single() {   # $1 路径 · $2 origin URL：一个私人邮箱的提交，什么都没推过
  git init -q -b main "$1"
  git -C "$1" remote add origin "$2"
  commit_as "$1" "$PRIVATE" "$PRIVATE" "work"
}

LEAK="$TMP/leak";           mk_fork "$LEAK";      commit_as "$LEAK" "$PRIVATE" "$PRIVATE" "fix"
CLEAN="$TMP/clean";         mk_fork "$CLEAN";     commit_as "$CLEAN" "$NOREPLY" "$NOREPLY" "fix"
UPONLY="$TMP/uponly";       mk_fork "$UPONLY"
COMMITTER="$TMP/committer"; mk_fork "$COMMITTER"; commit_as "$COMMITTER" "$NOREPLY" "$PRIVATE" "fix"
NEWCOMMIT="$TMP/newcommit"; mk_fork "$NEWCOMMIT"; commit_as "$NEWCOMMIT" "$NOREPLY" "$NOREPLY" "fix"
git -C "$NEWCOMMIT" config user.email "$PRIVATE"
NEWCOMMIT_OK="$TMP/newcommit-ok"; mk_fork "$NEWCOMMIT_OK"; commit_as "$NEWCOMMIT_OK" "$NOREPLY" "$NOREPLY" "fix"
git -C "$NEWCOMMIT_OK" config user.email "$NOREPLY"
PUSHREMOTE="$TMP/pushremote"; mk_fork "$PUSHREMOTE"; commit_as "$PUSHREMOTE" "$PRIVATE" "$PRIVATE" "fix"
git -C "$PUSHREMOTE" config branch.fix.pushRemote fork
PRIVATE_REPO="$TMP/private"; mk_single "$PRIVATE_REPO" https://github.com/wangxuzhou666-arch/colar-memory.git
FLAKY="$TMP/flaky";         mk_single "$FLAKY" https://github.com/flaky/repo.git
HF="$TMP/hf";               mk_single "$HF" https://huggingface.co/datasets/someone/data
SSH_FORK="$TMP/ssh-fork";   mk_single "$SSH_FORK" git@github.com:wangxuzhou666-arch/slime.git

run_guard() {   # $1 payload 里的 cwd · $2 命令串 → 打印 "deny: <reason>"；放行时无输出
  python3 -c 'import json, sys
print(json.dumps({"session_id": "t", "cwd": sys.argv[1], "hook_event_name": "PreToolUse",
                  "tool_name": "Bash", "tool_input": {"command": sys.argv[2]}}))' "$1" "$2" \
    | ( cd "$NONGIT" && HOME="$FAKE_HOME" PATH="$FAKEBIN:$PATH" bash "$GUARD" ) \
    | python3 -c 'import json, sys
raw = sys.stdin.read().strip()
if raw:
    out = json.loads(raw)["hookSpecificOutput"]
    print(out["permissionDecision"] + ": " + out["permissionDecisionReason"])'
}

expect_deny() {   # $1 标签 · $2 cwd · $3 命令串 · $4 reason 必含片段（钉住命中的是哪个仓 / 哪个身份）
  local out
  out=$(run_guard "$2" "$3")
  if printf '%s' "$out" | grep -q '^deny: ' && printf '%s' "$out" | grep -qF -- "$4"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL[deny] $1"; echo "   cmd: $3"; echo "   got: ${out:-<allow>}"
  fi
}

expect_allow() {  # $1 标签 · $2 cwd · $3 命令串
  local out
  out=$(run_guard "$2" "$3")
  if [ -z "$out" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL[allow] $1"; echo "   cmd: $3"; echo "   got: $out"
  fi
}

run_guard_env() {   # $1 cwd · $2 命令串 · $3 hook 进程的 PATH · $4 PUSH_EMAIL_GH_DIRS → 同 run_guard，但 env -i 起 hook
  python3 -c 'import json, sys
print(json.dumps({"session_id": "t", "cwd": sys.argv[1], "hook_event_name": "PreToolUse",
                  "tool_name": "Bash", "tool_input": {"command": sys.argv[2]}}))' "$1" "$2" \
    | ( cd "$NONGIT" && env -i HOME="$FAKE_HOME" PATH="$3" PUSH_EMAIL_GH_DIRS="$4" \
          GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$GUARD" ) \
    | python3 -c 'import json, sys
raw = sys.stdin.read().strip()
if raw:
    out = json.loads(raw)["hookSpecificOutput"]
    print(out["permissionDecision"] + ": " + out["permissionDecisionReason"])'
}

expect_deny_env() {   # $1 标签 · $2 cwd · $3 命令串 · $4 PATH · $5 PUSH_EMAIL_GH_DIRS · $6.. reason 必含的片段
  local label=$1 cwd=$2 cmd=$3 hook_path=$4 gh_dirs=$5 out piece ok=1
  shift 5
  out=$(run_guard_env "$cwd" "$cmd" "$hook_path" "$gh_dirs")
  printf '%s' "$out" | grep -q '^deny: ' || ok=0
  for piece in "$@"; do printf '%s' "$out" | grep -qF -- "$piece" || ok=0; done
  if [ "$ok" = 1 ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL[deny] $label"; echo "   cmd: $cmd"; echo "   got: ${out:-<allow>}"; fi
}

expect_allow_env() {  # $1 标签 · $2 cwd · $3 命令串 · $4 PATH · $5 PUSH_EMAIL_GH_DIRS
  local out
  out=$(run_guard_env "$2" "$3" "$4" "$5")
  if [ -z "$out" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL[allow] $1"; echo "   cmd: $3"; echo "   got: $out"; fi
}

# ---------------- P 组：拦 / 放 ----------------
expect_deny  "P1 fork 上的新提交带私人邮箱"                 "$LEAK" "git push fork fix"                        "wangxuzhou666-arch/slime"
expect_deny  "P1b 文案点名 author，邮箱打码"                "$LEAK" "git push fork fix"                        "author c***@example.com"
expect_allow "P2 新提交是 noreply"                          "$CLEAN" "git push fork fix"
expect_allow "P3 只有上游已推送的别人的提交"                "$UPONLY" "git push fork HEAD"
expect_deny  "P4 作者 noreply、提交者是私人邮箱"            "$COMMITTER" "git push fork fix"                   "committer c***@example.com"
expect_allow "P5 私有仓"                                    "$PRIVATE_REPO" "git push origin HEAD"
expect_deny  "P6 gh 查不到可见性，按公开处理"               "$FLAKY" "git push origin HEAD"                    "按公开处理"
expect_deny  "P6b 文案带 gh 的退出码"                       "$FLAKY" "git push origin HEAD"                    "gh 退出码 1"
expect_deny  "P6c 查不到那一支提示先核实"                   "$FLAKY" "git push origin HEAD"                    "gh repo view flaky/repo --json visibility"
expect_allow "P7 非 GitHub remote"                          "$HF" "git push origin HEAD"
expect_deny  "P8 同一条命令里先提交再推，身份是私人邮箱"    "$NEWCOMMIT" "git add -A && git commit -m x && git push fork fix" "本条命令里新建的提交"
expect_allow "P9 同上，身份是 noreply"                      "$NEWCOMMIT_OK" "git commit -m x && git push fork fix"
expect_allow "P10 --delete 只删远端分支"                    "$LEAK" "git push fork --delete fix"
expect_allow "P11 :分支 refspec 是删除"                     "$LEAK" "git push fork :fix"
expect_deny  "P12 git -C + src:dst refspec"                 "$NONGIT" "git -C $LEAK push fork HEAD:refs/heads/x" "wangxuzhou666-arch/slime"
expect_deny  "P13 会话 cwd 不在仓里，cd 进仓再推"           "$NONGIT" "cd $LEAK && git push -u fork fix"       "wangxuzhou666-arch/slime"
expect_deny  "P14 bash -c 包着的 push"                      "$LEAK" "bash -c 'git push fork fix'"              "wangxuzhou666-arch/slime"
expect_deny  "P15 不写 remote：走 branch.fix.pushRemote"    "$PUSHREMOTE" "git push"                           "wangxuzhou666-arch/slime"
expect_deny  "P16 不写 remote 也没有 pushRemote：origin"    "$LEAK" "git push"                                 "THUDM/slime"
expect_deny  "P17 --all 推全部分支"                         "$LEAK" "git push --all fork"                      "wangxuzhou666-arch/slime"
expect_deny  "P18 SSH 写法的 remote"                        "$SSH_FORK" "git push origin main"                 "wangxuzhou666-arch/slime"
expect_allow "P19 子 shell 里的 cd 不外泄"                  "$NONGIT" "(cd $LEAK && git status) && git push fork fix"
expect_allow "P20 remote 是变量：推断不了，放行"            "$LEAK" "git push \$REMOTE fix"
expect_allow "P21 只是提到 push"                            "$LEAK" "echo push && git status"

# P22/P23：hook 进程 PATH 里没有 gh。回退目录里有 gh → 识别出私有仓放行；回退目录里也没有 → 按公开处理，文案自带原因。
BARE_PATH=/usr/bin:/bin
EMPTY_DIR="$TMP/empty-dir"; mkdir -p "$EMPTY_DIR"
if env -i PATH="$BARE_PATH" bash -c 'command -v gh' > /dev/null 2>&1; then
  echo "SKIP P22/P23：$BARE_PATH 里本来就有 gh，造不出「PATH 里没有 gh」"
else
  expect_allow_env "P22 PATH 里没有 gh，回退目录里有：识别为私有仓" "$PRIVATE_REPO" "git push origin HEAD" "$BARE_PATH" "$FAKEBIN"
  expect_deny_env  "P23 PATH 和回退目录都没有 gh：按公开处理，文案带原因和核实提示" "$PRIVATE_REPO" "git push origin HEAD" \
    "$BARE_PATH" "$EMPTY_DIR" "gh 不在 PATH" "gh repo view"
fi

# P24：确认公开的那支，修法用 -c 传身份、不写本地配置，也不带「先核实」那句
LEAK_OUT=$(run_guard "$LEAK" "git push fork fix")
FIX_PREFIX='git -c user.name=wangxuzhou666-arch -c user.email='
if printf '%s' "$LEAK_OUT" | grep -qF -- "$FIX_PREFIX" \
   && ! printf '%s' "$LEAK_OUT" | grep -qF -- "git config user." \
   && ! printf '%s' "$LEAK_OUT" | grep -qF -- "gh repo view"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "FAIL P24 public 分支的文案契约（带 -c 修法 · 不含 git config user. · 不含 gh repo view）"; echo "   got: $LEAK_OUT"
fi

# P25：文案里的修法在临时仓里真能跑，author / committer 都变 noreply，且不往本地配置写 user.*
# 提交里要有真改动：amend 一个空提交会被 git 拒绝（--allow-empty 才行），那不是文案要覆盖的场景
FIXREPO="$TMP/fixrepo"; mk_fork "$FIXREPO"
echo change > "$FIXREPO/file.txt"; git -C "$FIXREPO" add file.txt
commit_as "$FIXREPO" "$PRIVATE" "$PRIVATE" "fix"
FIX_CMD=$(printf '%s' "$LEAK_OUT" | grep -m1 -oE 'git -c user\.name=[^ ]+ -c user\.email=[^ ]+ commit --amend --no-edit --reset-author')
if [ -z "$FIX_CMD" ]; then
  fail=$((fail + 1)); echo "FAIL P25 从拦截文案里取不到修法命令：$LEAK_OUT"
else
  ( cd "$FIXREPO" && bash -c "$FIX_CMD" ) > /dev/null 2>&1
  NEW_IDENTITY=$(git -C "$FIXREPO" log -1 --format='%ae %ce')
  LOCAL_USER=$(git -C "$FIXREPO" config --local --get-regexp '^user\.' 2>/dev/null)
  if [ "$NEW_IDENTITY" = "${NEW_IDENTITY%% *} ${NEW_IDENTITY%% *}" ] \
     && [[ "${NEW_IDENTITY%% *}" == *@users.noreply.github.com ]] && [ -z "$LOCAL_USER" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL P25 修法执行后身份不对或污染了本地配置：identity=[$NEW_IDENTITY] local_user=[$LOCAL_USER]"
  fi
fi

# ---------------- G 组：输出契约与开销 ----------------
out=$(run_guard "$LEAK" "git push fork fix")
if printf '%s' "$out" | grep -qF "$PRIVATE"; then
  fail=$((fail + 1)); echo "FAIL G1 拦截文案露出了完整邮箱：$out"
else pass=$((pass + 1)); fi

: > "$GH_LOG"
run_guard "$CLEAN" "git push fork fix" > /dev/null
run_guard "$UPONLY" "git push fork HEAD" > /dev/null
if [ -s "$GH_LOG" ]; then
  fail=$((fail + 1)); echo "FAIL G2 没有命中却调了 gh：$(cat "$GH_LOG")"
else pass=$((pass + 1)); fi

LONE="$TMP/lone"; mkdir -p "$LONE"; cp "$GUARD" "$LONE/"
out=$(python3 -c 'import json; print(json.dumps({"cwd": "'"$LEAK"'", "tool_input": {"command": "git push fork fix"}}))' \
  | ( cd "$NONGIT" && PATH="$FAKEBIN:$PATH" bash "$LONE/$(basename "$GUARD")" ))
if [ -z "$out" ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL G3 判定器缺失时应放行（fail-open），实际：$out"; fi

# ---------------- 隔离自证 ----------------
if [ "$(shasum "$SELF_REPO_CONFIG" 2>/dev/null)" = "$SELF_SUM_BEFORE" ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL ISO 本仓 $SELF_REPO_CONFIG 在测试期间被改动 —— 隔离失效，立刻人工检查"; fi

echo "PASS $pass / FAIL $fail"
[ "$fail" -eq 0 ]
