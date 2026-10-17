#!/usr/bin/env bash
# scripts/wt 的「wt park」契约自证（暂停一条线：tag 存档 → 拆树 → 删分支；tag 消息本身就是恢复清单）：
#   OK  已推送的分支 → exit 0：本地有 annotated tag archive/paused/<YYYYMMDD>/<分支>，消息逐字为
#       「archive: <分支> @ <40 位 sha> — <原因>」；远端 tag 剥皮后 == tip；树拆掉；本地分支、上游配置、远端分支都删掉
#   RS  照提示恢复：wt new <用途> --branch <分支> <tag> → 回到同一个 tip
#   EX  不可再生的被忽略文件 → 导出到 <证据目录>/<YYYY-MM-DD>-park-<树目录名>/（清单可回验），可再生的不导出
#   LO  从没推过的分支 → exit 0、tag 推上去、本地分支删掉、不碰远端分支
#   DT  脏树 → exit 2、不打 tag
#   DU  detached 且有独有提交 → exit 2、不打 tag、提示 switch -c；DC detached 没有独有提交 → exit 2、提示直接 wt rm
#   RA  origin/<分支> 有本地没有的提交 → exit 2、不打 tag；LA 本地领先 origin/<分支> → exit 2、提示先 push、不打 tag
#   TC  同名 tag 已指向别的提交 → exit 2、不覆盖、树原样
#   RR  拆树被占用门拦下 → exit 2、tag 已推、分支与树都还在；进程退出后重跑 → 复用 tag、走完
#   FF  fetch 失败 → exit 1、不打 tag；MN 主工作树 → exit 2；U1 没给 --reason → exit 1
#
# 跑法：bash scripts/hooks/tests/test_wt_park.sh
# 变异验证：WT=<改坏一条规则的副本> bash 本脚本 → 对应用例必须转红，否则该用例没有判别力。
#
# 隔离（同 test_wt_new_branch_base.sh）：剥掉 GIT_DIR 一类变量；GIT_CONFIG_GLOBAL=/dev/null + GIT_CONFIG_NOSYSTEM=1；
# 「远端」是 mktemp 下的 bare 仓；WT_HOME / WT_EVIDENCE_HOME 指向临时目录；结尾校验本仓 .git/config 前后字节一致、
# 真实证据目录没多出东西。判断退出码一律不走管道。
set -u
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=wt-test GIT_AUTHOR_EMAIL=wt-test@localhost GIT_COMMITTER_NAME=wt-test GIT_COMMITTER_EMAIL=wt-test@localhost

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WT=${WT:-$HERE/../../wt}
SELF_REPO_CONFIG=$(cd "$HERE" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/config
SELF_SUM_BEFORE=$(shasum "$SELF_REPO_CONFIG" 2>/dev/null)
REAL_EVIDENCE="$HOME/fabric-evidence"
REAL_EVIDENCE_BEFORE=$(ls -a "$REAL_EVIDENCE" 2>/dev/null)
pass=0
fail=0

TMP=$(mktemp -d)
BG_PIDS=""
cleanup() { [ -z "$BG_PIDS" ] || kill $BG_PIDS 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
TMP=$(cd "$TMP" && pwd -P)
export WT_HOME="$TMP/wt-home"
export WT_EVIDENCE_HOME="$TMP/evidence"
export WT_LSOF_GAP=0
OUT="$TMP/.stdout.txt"
ERR="$TMP/.stderr.txt"
STAMP=$(date +%Y%m%d)
TODAY=$(date +%Y-%m-%d)

commit()     { git -C "$1" commit -q --allow-empty -m "$2"; }
tip()        { git -C "$1" rev-parse HEAD 2>/dev/null; }
has_branch() { git -C "$LOCAL" show-ref --verify --quiet "refs/heads/$1"; }
has_tag()    { git -C "$LOCAL" show-ref --verify --quiet "refs/tags/$1"; }
remote_has() { [ -n "$(git -C "$REMOTE" for-each-ref "$1")" ]; }
in_list()    { git -C "$LOCAL" worktree list --porcelain | grep -qxF "worktree $1"; }

# ---- 远端 + seed（别的写入方）+ 本地克隆；仓里忽略 notes/ 与 __pycache__/ ----
REMOTE="$TMP/remote.git"
SEED="$TMP/seed"
LOCAL="$TMP/local"
git init -q --bare -b main "$REMOTE"
git init -q -b main "$SEED"
printf 'notes/\n__pycache__/\n' > "$SEED/.gitignore"
echo base > "$SEED/a.txt"
git -C "$SEED" add -A
commit "$SEED" main-1
git -C "$SEED" remote add origin "$REMOTE"
git -C "$SEED" push -q origin main
git clone -q "$REMOTE" "$LOCAL"

RC=0
run_wt() {
  local repo=$1; shift
  RC=0
  ( cd "$repo" && bash "$WT" "$@" ) > "$OUT" 2> "$ERR" || RC=$?
}
ok()  { pass=$((pass + 1)); }
bad() {
  fail=$((fail + 1))
  echo "FAIL $1"
  echo "   rc=$RC"
  echo "   stdout: $(LC_ALL=C tr '\n' '|' < "$OUT")"
  echo "   stderr: $(LC_ALL=C tr '\n' '|' < "$ERR")"
}
mk() { run_wt "$LOCAL" new "$@"; [ "$RC" = 0 ] || bad "setup: wt new $*"; }
# 起一棵带已推送分支的树：$1 用途 $2 分支
mk_pushed() { mk "$1" --branch "$2"; commit "$WT_HOME/local-$1" "$2-work"; git -C "$WT_HOME/local-$1" push -q -u origin "$2"; }

# ---- OK：已推送的分支 ----
mk_pushed p1 feat/p
T=$WT_HOME/local-p1
P1_TIP=$(tip "$T")
TAG="archive/paused/$STAMP/feat/p"
run_wt "$LOCAL" park p1 --reason "等设计稿"
if [ "$RC" = 0 ] && has_tag "$TAG" && [ "$(git -C "$LOCAL" cat-file -t "refs/tags/$TAG")" = tag ] \
   && [ "$(git -C "$LOCAL" for-each-ref --format='%(contents:subject)' "refs/tags/$TAG")" = "archive: feat/p @ $P1_TIP — 等设计稿" ] \
   && [ "$(git -C "$LOCAL" ls-remote origin "refs/tags/$TAG^{}" | cut -f1)" = "$P1_TIP" ] \
   && [ ! -e "$T" ] && ! in_list "$T" && ! has_branch feat/p \
   && ! git -C "$LOCAL" config --get branch.feat/p.remote >/dev/null \
   && ! remote_has refs/heads/feat/p && grep -qF '恢复' "$OUT"; then ok
else bad "OK 已推送分支 → tag 消息逐字、远端剥皮 == tip、树拆掉、本地分支/上游配置/远端分支都删掉"; fi

# ---- RS：照提示恢复 ----
run_wt "$LOCAL" new p1r --branch feat/p "$TAG"
if [ "$RC" = 0 ] && [ "$(tip "$WT_HOME/local-p1r")" = "$P1_TIP" ]; then ok
else bad "RS wt new <用途> --branch <分支> <tag> → 回到同一个 tip"; fi

# ---- EX：不可再生的被忽略文件先导出 ----
mk_pushed p2 feat/ex
T=$WT_HOME/local-p2
mkdir -p "$T/notes" "$T/pkg/__pycache__"
echo idea > "$T/notes/idea.md"; echo c > "$T/pkg/__pycache__/m.pyc"
run_wt "$LOCAL" park p2 --reason "导出用例"
EV="$WT_EVIDENCE_HOME/$TODAY-park-local-p2"
if [ "$RC" = 0 ] && [ ! -e "$T" ] && [ "$(cat "$EV/notes/idea.md" 2>/dev/null)" = idea ] && [ ! -e "$EV/pkg" ] \
   && ( cd "$EV" && shasum -a 256 -c --quiet MANIFEST.sha256 ) >/dev/null 2>&1 && grep -qF "$EV" "$OUT"; then ok
else bad "EX 不可再生的被忽略文件导出到 <日期>-park-<树目录名>/（清单可回验）、可再生的不导出，然后拆树"; fi

# ---- LO：从没推过的分支 ----
mk p3 --branch feat/lo
T=$WT_HOME/local-p3
commit "$T" lo-work
LO_TIP=$(tip "$T")
run_wt "$LOCAL" park p3 --reason "本地实验"
if [ "$RC" = 0 ] && [ "$(git -C "$LOCAL" ls-remote origin "refs/tags/archive/paused/$STAMP/feat/lo^{}" | cut -f1)" = "$LO_TIP" ] \
   && ! has_branch feat/lo && [ ! -e "$T" ] && ! remote_has refs/heads/feat/lo; then ok
else bad "LO 没推过的分支 → tag 推上去、本地分支删掉、树拆掉"; fi

# ---- DT：脏树 ----
mk_pushed p4 feat/dt
T=$WT_HOME/local-p4
echo wip > "$T/wip.txt"
run_wt "$LOCAL" park p4 --reason x
if [ "$RC" = 2 ] && [ -f "$T/wip.txt" ] && ! has_tag "archive/paused/$STAMP/feat/dt" && has_branch feat/dt; then ok
else bad "DT 脏树 → exit 2、不打 tag、分支与树都不动"; fi

# ---- DU / DC：detached ----
mk p5
T=$WT_HOME/local-p5
commit "$T" detached-unique
TAGS_BEFORE=$(git -C "$LOCAL" for-each-ref refs/tags/archive/ | wc -l)
run_wt "$LOCAL" park p5 --reason x
if [ "$RC" = 2 ] && [ -d "$T" ] && grep -qF 'switch -c' "$ERR" \
   && [ "$(git -C "$LOCAL" for-each-ref refs/tags/archive/ | wc -l)" = "$TAGS_BEFORE" ]; then ok
else bad "DU detached 且有独有提交 → exit 2、不打 tag、提示 switch -c"; fi
mk p6
run_wt "$LOCAL" park p6 --reason x
if [ "$RC" = 2 ] && [ -d "$WT_HOME/local-p6" ] && grep -qF '直接 wt rm' "$ERR"; then ok
else bad "DC detached 没有独有提交 → exit 2、提示直接 wt rm"; fi

# ---- RA：origin/<分支> 有本地没有的提交 ----
mk_pushed p7 feat/ra
T=$WT_HOME/local-p7
git -C "$SEED" fetch -q origin
git -C "$SEED" switch -q -c feat/ra origin/feat/ra
commit "$SEED" someone-else
git -C "$SEED" push -q origin feat/ra
git -C "$SEED" switch -q main
run_wt "$LOCAL" park p7 --reason x
if [ "$RC" = 2 ] && [ -d "$T" ] && ! has_tag "archive/paused/$STAMP/feat/ra" && grep -qF '本地没有的提交' "$ERR"; then ok
else bad "RA origin/<分支> 有本地没有的提交 → exit 2、不打 tag"; fi

# ---- LA：本地领先 origin/<分支> ----
mk_pushed p8 feat/la
T=$WT_HOME/local-p8
commit "$T" unpushed
run_wt "$LOCAL" park p8 --reason x
if [ "$RC" = 2 ] && [ -d "$T" ] && ! has_tag "archive/paused/$STAMP/feat/la" && grep -qF '先 git push' "$ERR"; then ok
else bad "LA 本地领先 origin/<分支> → exit 2、提示先 push、不打 tag"; fi

# ---- TC：同名 tag 已指向别的提交 ----
mk_pushed p9 feat/tc
T=$WT_HOME/local-p9
git -C "$LOCAL" tag -a "archive/paused/$STAMP/feat/tc" -m "someone else" origin/main
run_wt "$LOCAL" park p9 --reason x
if [ "$RC" = 2 ] && [ -d "$T" ] && has_branch feat/tc && grep -qF '指向别的提交' "$ERR" \
   && [ "$(git -C "$LOCAL" rev-parse "archive/paused/$STAMP/feat/tc^{commit}")" = "$(git -C "$LOCAL" rev-parse origin/main)" ]; then ok
else bad "TC 同名 tag 已指向别的提交 → exit 2、不覆盖、分支与树都不动"; fi

# ---- RR：拆树被占用门拦下 → 重跑复用 tag ----
mk_pushed p10 feat/rr
T=$WT_HOME/local-p10
RR_TAG="archive/paused/$STAMP/feat/rr"
( exec 3< "$T/a.txt"; cd /; exec sleep 60 ) & HOLD=$!
BG_PIDS=$HOLD
sleep 0.5
run_wt "$LOCAL" park p10 --reason "被占着"
if [ "$RC" = 2 ] && [ -d "$T" ] && has_branch feat/rr && remote_has refs/heads/feat/rr \
   && [ -n "$(git -C "$LOCAL" ls-remote origin "refs/tags/$RR_TAG")" ] && grep -qF "pid=$HOLD " "$ERR" \
   && grep -qF 'tag 会复用' "$ERR"; then ok
else bad "RR 拆树被占用门拦下 → exit 2、tag 已推、分支与树都还在、提示重跑"; fi
kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null; BG_PIDS=""
run_wt "$LOCAL" park p10 --reason "被占着"
if [ "$RC" = 0 ] && grep -qF '复用已有 tag' "$OUT" && [ ! -e "$T" ] && ! has_branch feat/rr && ! remote_has refs/heads/feat/rr; then ok
else bad "RR2 进程退出后重跑 → 复用 tag、拆树、删分支"; fi

# ---- FF：fetch 失败 ----
DEAD="$TMP/dead"
git clone -q "$REMOTE" "$DEAD"
run_wt "$DEAD" new p11 --branch feat/ff
commit "$WT_HOME/dead-p11" ff-work
git -C "$DEAD" remote set-url origin "$TMP/no-such-remote.git"
run_wt "$DEAD" park p11 --reason x
if [ "$RC" = 1 ] && [ -d "$WT_HOME/dead-p11" ] \
   && ! git -C "$DEAD" show-ref --verify --quiet "refs/tags/archive/paused/$STAMP/feat/ff" \
   && grep -qF 'fetch origin 失败' "$ERR"; then ok
else bad "FF fetch 失败 → exit 1、不打 tag、树原样"; fi

# ---- MN / U1 ----
run_wt "$LOCAL" park "$LOCAL" --reason x
if [ "$RC" = 2 ]; then ok; else bad "MN 主工作树 → exit 2"; fi
run_wt "$LOCAL" park p9
if [ "$RC" = 1 ] && [ -d "$WT_HOME/local-p9" ]; then ok; else bad "U1 没给 --reason → exit 1"; fi

# ---- 隔离自证 ----
if [ "$(shasum "$SELF_REPO_CONFIG" 2>/dev/null)" = "$SELF_SUM_BEFORE" ]; then ok; else
  fail=$((fail + 1)); echo "FAIL ISO 本仓 $SELF_REPO_CONFIG 在测试期间被改动 —— 隔离失效，立刻人工检查"; fi
if [ "$(ls -a "$REAL_EVIDENCE" 2>/dev/null)" = "$REAL_EVIDENCE_BEFORE" ]; then ok; else
  fail=$((fail + 1)); echo "FAIL ISO2 $REAL_EVIDENCE 在测试期间多了东西 —— WT_EVIDENCE_HOME 隔离失效，立刻人工检查"; fi

echo "PASS $pass / FAIL $fail"
[ "$fail" -eq 0 ]
