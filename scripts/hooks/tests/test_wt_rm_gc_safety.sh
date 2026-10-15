#!/usr/bin/env bash
# scripts/wt 的两道「别删不该删的东西」安全门自证（2026-10-14 两起真实事故）：
#
#   wt rm —— 拆树前扫主仓 + 其他 worktree，有 symlink 解析后落在这棵树里就拒绝（织锦 docs/_wt-* 指进 worktree，拆后锚点页 404）
#     R1  主仓有 symlink 指进目标 → exit 2、树保留、stderr 列出「链接 -> 目标」
#     R1b --force 不放行（--force 只管未提交内容）
#     R1c 相对路径的 symlink 同样识别
#     R1d 别的 worktree 里的 symlink 同样识别（不止扫主仓）
#     R2  --ignore-refs 放行 → 树被拆
#     R3  指向别处的 symlink / 没有任何 symlink → 照常拆（不误拒）
#     R4  --ignore-refs 不放行未提交内容；两个旗标一起才全放行（两道门互相独立）
#     R5  node_modules 里的 symlink 不计（约定的剪枝范围）
#     U1  用法文案列出 --ignore-refs
#
#   wt gc —— 只删「正向确认是本仓前 worktree」的孤儿目录（旧版把 ~/.wt/_logs 这种普通目录当孤儿 rm -rf 了）
#     G1  真孤儿（登记没了、.git 文件还在、内容都在对象库里）→ 删
#     G2  _logs 式普通目录 → 留，列「跳过」
#     G3  无 .git 文件的普通目录 → 留
#     G3b .git 是目录的独立仓库 → 留
#     G4  别的仓库的 worktree（在 A 仓跑 gc 不许动 B 仓的树）→ 留；别仓的孤儿 → 留
#     G5  本仓孤儿但有未入库内容（新文件 / 改过的文件）→ 留，且点名文件
#     G6  仍登记着的 worktree → 不碰
#     G7  _ 开头的真孤儿 → 留
#     G8  .git 文件指向本仓「仍存在」的登记，但该目录不是登记的那个位置（拷贝 / 挪位）→ 留
#
# 跑法：bash scripts/hooks/tests/test_wt_rm_gc_safety.sh
# 变异验证：WT=<改坏一条规则的副本> bash 本脚本 → 对应用例必须转红，否则该用例没有判别力。
#
# 隔离（同 test_wt_post_new_hook.sh）：剥掉 GIT_DIR 一类变量；GIT_CONFIG_GLOBAL=/dev/null + GIT_CONFIG_NOSYSTEM=1；
# 所有仓库与 WT_HOME 都在 mktemp 目录里，绝不碰真实 ~/.wt；结尾校验本仓 .git/config 前后字节一致。
# 判断退出码一律不走管道。
set -u
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WT=${WT:-$HERE/../../wt}
SELF_REPO_CONFIG=$(cd "$HERE" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/config
SELF_SUM_BEFORE=$(shasum "$SELF_REPO_CONFIG" 2>/dev/null)
pass=0
fail=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)   # macOS 的 /var → /private/var；wt 内部全用 realpath，期望值也得是
export WT_HOME="$TMP/wt-home"
OUT="$TMP/.stdout.txt"
ERR="$TMP/.stderr.txt"

mkrepo() {
  git init -q -b main "$1"
  mkdir -p "$1/docs"
  echo hello > "$1/docs/a.md"
  echo tracked > "$1/a.txt"
  git -C "$1" add -A
  git -C "$1" -c user.name=wt-test -c user.email=wt-test@localhost commit -q -m init
}
REPO="$TMP/repo";   mkrepo "$REPO"
REPO2="$TMP/repo2"; mkrepo "$REPO2"

RC=0
# $1 仓库目录，其余是 wt 参数；子 shell 里 cd，结果落进全局 RC 与 OUT/ERR 文件
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
# 建 worktree（落在 $WT_HOME/<仓名>-<用途>）；建不起来本身就是 setup 失败
mk()  { run_wt "$REPO"  new "$1"; [ "$RC" = 0 ] || bad "setup: wt new $1"; }
mk2() { run_wt "$REPO2" new "$1"; [ "$RC" = 0 ] || bad "setup: (repo2) wt new $1"; }
in_list() { git -C "$REPO" worktree list --porcelain | grep -qxF "worktree $1"; }

# ======================= wt rm =======================

# ---- R1：主仓有 symlink 指进目标 → 拒绝 ----
mk tgt1
T1="$WT_HOME/repo-tgt1"
ln -s "$T1/docs" "$REPO/docs/_wt-tgt1"
run_wt "$REPO" rm tgt1
if [ "$RC" = 2 ] && [ -d "$T1" ] && in_list "$T1" \
   && grep -qF "$REPO/docs/_wt-tgt1 -> $T1/docs" "$ERR" && grep -qF -- '--ignore-refs' "$ERR"; then ok
else bad "R1 主仓 symlink 指进目标 → exit 2 + 树保留 + 列出「链接 -> 目标」+ 提示 --ignore-refs"; fi

# ---- R1b：--force 不放行 ----
run_wt "$REPO" rm tgt1 --force
if [ "$RC" = 2 ] && [ -d "$T1" ]; then ok; else bad "R1b --force 不放行 symlink 引用"; fi

# ---- R1c：相对路径 symlink ----
rm -f "$REPO/docs/_wt-tgt1"
ln -s "../../wt-home/repo-tgt1/docs" "$REPO/docs/_rel"
run_wt "$REPO" rm tgt1
if [ "$RC" = 2 ] && [ -d "$T1" ] && grep -qF "$REPO/docs/_rel -> $T1/docs" "$ERR"; then ok
else bad "R1c 相对路径 symlink 解析后指进目标 → 拒绝"; fi
rm -f "$REPO/docs/_rel"

# ---- R1d：别的 worktree 里的 symlink ----
mk other1
O1="$WT_HOME/repo-other1"
ln -s "$T1" "$O1/link-to-tgt1"
run_wt "$REPO" rm tgt1
if [ "$RC" = 2 ] && [ -d "$T1" ] && grep -qF "$O1/link-to-tgt1 -> $T1" "$ERR"; then ok
else bad "R1d 其他 worktree 里的 symlink 指进目标 → 拒绝"; fi
rm -f "$O1/link-to-tgt1"

# ---- R2：--ignore-refs 放行 ----
ln -s "$T1/docs" "$REPO/docs/_wt-tgt1"
run_wt "$REPO" rm tgt1 --ignore-refs
if [ "$RC" = 0 ] && [ ! -e "$T1" ] && ! in_list "$T1"; then ok; else bad "R2 --ignore-refs → 树被拆且登记清掉"; fi
rm -f "$REPO/docs/_wt-tgt1"

# ---- R3：指向别处 / 没有 symlink → 照常拆 ----
mk tgt3; mk keep3
ln -s "$WT_HOME/repo-keep3/docs" "$REPO/docs/_wt-keep3"
run_wt "$REPO" rm tgt3
if [ "$RC" = 0 ] && [ ! -e "$WT_HOME/repo-tgt3" ] && [ -d "$WT_HOME/repo-keep3" ]; then ok
else bad "R3 symlink 指向别的树 → 不误拒，目标树照常拆、被指的树不动"; fi
rm -f "$REPO/docs/_wt-keep3"
mk tgt3b
run_wt "$REPO" rm tgt3b
if [ "$RC" = 0 ] && [ ! -e "$WT_HOME/repo-tgt3b" ]; then ok; else bad "R3b 没有任何引用 → 照常拆"; fi

# ---- R4：两道门互相独立 ----
mk tgt4
T4="$WT_HOME/repo-tgt4"
echo wip > "$T4/wip.txt"
ln -s "$T4/docs" "$REPO/docs/_wt-tgt4"
run_wt "$REPO" rm tgt4 --ignore-refs
if [ "$RC" = 2 ] && [ -d "$T4" ] && grep -qF '未提交' "$ERR"; then ok
else bad "R4 --ignore-refs 只放行引用，未提交内容照样拒绝"; fi
run_wt "$REPO" rm tgt4 --ignore-refs --force
if [ "$RC" = 0 ] && [ ! -e "$T4" ]; then ok; else bad "R4b --ignore-refs --force 一起才全放行"; fi
rm -f "$REPO/docs/_wt-tgt4"

# ---- R5：node_modules 内的 symlink 不计 ----
mk tgt5
mkdir -p "$REPO/node_modules/pkg"
ln -s "$WT_HOME/repo-tgt5" "$REPO/node_modules/pkg/lnk"
run_wt "$REPO" rm tgt5
if [ "$RC" = 0 ] && [ ! -e "$WT_HOME/repo-tgt5" ]; then ok; else bad "R5 node_modules 里的 symlink 属约定剪枝范围，不拦"; fi
rm -rf "$REPO/node_modules"

# ---- U1：用法文案 ----
run_wt "$REPO" rm
if [ "$RC" = 1 ] && grep -qF -- '--ignore-refs' "$ERR"; then ok; else bad "U1 用法报错列出 --ignore-refs"; fi

# ======================= wt gc =======================

# 本仓真孤儿：建好树，再把 .git/worktrees/<名> 登记抹掉——目录和 .git 文件还在
orphan_of() {  # $1=仓库 $2=树目录 $3=登记名
  rm -rf "$1/.git/worktrees/$3"
}

mk orph1;  orphan_of "$REPO" "$WT_HOME/repo-orph1" repo-orph1                      # G1 干净真孤儿
mk orph5;  orphan_of "$REPO" "$WT_HOME/repo-orph5" repo-orph5
echo brand-new > "$WT_HOME/repo-orph5/wip.txt"                                       # G5 未入库的新文件
mk orph5b; orphan_of "$REPO" "$WT_HOME/repo-orph5b" repo-orph5b
echo edited >> "$WT_HOME/repo-orph5b/a.txt"                                          # G5 改过的跟踪文件
mk live6                                                                             # G6 仍登记
git -C "$REPO" worktree add -q --detach "$WT_HOME/_old"                              # G7 _ 开头的真孤儿
rm -rf "$REPO/.git/worktrees/_old"
mkdir -p "$WT_HOME/dup8";     cp "$WT_HOME/repo-live6/.git" "$WT_HOME/dup8/.git"     # G8 登记还在，但不是登记的位置
mkdir -p "$WT_HOME/_logs";    echo log  > "$WT_HOME/_logs/run.log"                   # G2
mkdir -p "$WT_HOME/scratch";  echo note > "$WT_HOME/scratch/note.txt"                # G3
mkrepo "$WT_HOME/standalone"                                                         # G3b 独立仓库，干净
mk2 live2                                                                            # G4 别仓的活树（对本仓来说「不在登记里」）
mk2 gone2; orphan_of "$REPO2" "$WT_HOME/repo2-gone2" repo2-gone2                     # G4 别仓的孤儿

run_wt "$REPO" gc
GC_RC=$RC

if [ "$GC_RC" = 0 ] && [ ! -e "$WT_HOME/repo-orph1" ] && grep -qF "清掉孤儿目录 $WT_HOME/repo-orph1" "$OUT"; then ok
else bad "G1 本仓真孤儿（内容全在对象库里）→ 删"; fi

if [ -f "$WT_HOME/_logs/run.log" ] && grep -qF "跳过 $WT_HOME/_logs" "$OUT" && grep -qF '不是 worktree' "$OUT"; then ok
else bad "G2 _logs 式普通目录 → 留 + 列「跳过（不是 worktree）」"; fi

if [ -f "$WT_HOME/scratch/note.txt" ] && grep -qF "跳过 $WT_HOME/scratch" "$OUT"; then ok
else bad "G3 无 .git 文件的普通目录 → 留"; fi

if [ -d "$WT_HOME/standalone/.git" ] && grep -qF "跳过 $WT_HOME/standalone" "$OUT"; then ok
else bad "G3b .git 是目录的独立仓库 → 留（旧版因 git status 为空而误删）"; fi

if [ -d "$WT_HOME/repo2-live2" ] && [ -d "$WT_HOME/repo2-gone2" ]; then ok
else bad "G4 别仓的 worktree / 别仓的孤儿 → 留（旧版在 A 仓跑 gc 会清掉 B 仓干净的树）"; fi

if [ -f "$WT_HOME/repo-orph5/wip.txt" ] && grep -qF 'wip.txt' "$OUT" \
   && [ -f "$WT_HOME/repo-orph5b/a.txt" ] && grep -qF "$WT_HOME/repo-orph5b/a.txt" "$OUT"; then ok
else bad "G5 孤儿里有未入库内容（新文件 / 改过的文件）→ 留 + 点名文件"; fi

if [ -d "$WT_HOME/repo-live6" ] && in_list "$WT_HOME/repo-live6"; then ok; else bad "G6 仍登记的 worktree 不碰"; fi

if [ -d "$WT_HOME/_old" ] && grep -qF "跳过 $WT_HOME/_old" "$OUT"; then ok
else bad "G7 _ 开头的目录即便是真孤儿也不删"; fi

if [ -f "$WT_HOME/dup8/.git" ] && grep -qF "跳过 $WT_HOME/dup8" "$OUT"; then ok
else bad "G8 gitdir 指向本仓仍存在的登记（不是孤儿）→ 留"; fi

# ---- 隔离自证：本仓真实 config 没被测试碰过 ----
if [ "$(shasum "$SELF_REPO_CONFIG" 2>/dev/null)" = "$SELF_SUM_BEFORE" ]; then ok; else
  fail=$((fail + 1)); echo "FAIL ISO 本仓 $SELF_REPO_CONFIG 在测试期间被改动 —— 隔离失效，立刻人工检查"; fi

echo "PASS $pass / FAIL $fail"
[ "$fail" -eq 0 ]
