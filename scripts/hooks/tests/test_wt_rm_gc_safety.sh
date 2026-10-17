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
#     U1  用法文案列出 --ignore-refs / --export-ignored；U2 未知参数 → exit 1
#
#   wt rm —— 2026-10-17 新增的门（织锦 2026-10-16 分支清理暴露的三类「拆树丢东西」+ 不再 rm -rf 兜底）
#     D1  detached HEAD 上有独有提交 → exit 2、树保留、列出提交；D1b 没有放行开关；D2 挂上分支后照常拆
#     W1  分支上有不在任何远端的提交 → 只警告、照常拆、分支保留；W2 都已推送 → 不警告
#     H1  有进程 cwd 在树里 → exit 2、列出 pid；H2 有进程开着树里的文件、cwd 在别处 → exit 2（Docker 占 config.yml 的形态）
#     H1b 占用门没有放行开关；H3 进程退出 / 句柄关掉后照常拆
#     I0  wt new 把建树时就有的被忽略条目（仓库钩子补的种子库）记进登记目录，树不变脏
#     I1  只有补灌产物 + 未跟踪的 .venv 链接 → 不带开关照常拆（主仓 .venv 原样）
#     I2  可再生的（缓存名 / pyc / .DS_Store / symlink / 与主仓逐字节相同 / 改过的补灌产物 / 目录里只有这些）→ 不拦
#     I3  不可再生的 → exit 2、逐项列出、提示两个开关；I3b --force 不放行；I3c 两个开关二选一
#     I4  --export-ignored → 按相对路径导出（含中文名）+ 可回验的 sha256 清单、不带可再生的，然后拆
#     I5  --ignored-ok → 不导出直接拆；I6 同一天导出两次 → 另起目录，不覆盖
#     F1  git worktree remove 拒绝（树被 lock）→ exit 2、不 rm -rf、树原样（摘下的 .venv 链接挂回）；F1b 解锁后照常拆
#     F2  不是本仓 worktree 的目录 → exit 2、原样不动（旧版会 rm -rf）
#     F3  登记还在、目录已没 → 只清登记；F4 两样都没有 → exit 1
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
BG_PIDS=""   # 占用门用例起的后台进程：无论成败都要收掉
cleanup() { [ -z "$BG_PIDS" ] || kill $BG_PIDS 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
TMP=$(cd "$TMP" && pwd -P)   # macOS 的 /var → /private/var；wt 内部全用 realpath，期望值也得是
export WT_HOME="$TMP/wt-home"
export WT_EVIDENCE_HOME="$TMP/evidence"   # 导出落点：绝不写进真实的 ~/fabric-evidence
export WT_LSOF_GAP=0                      # 占用门 3 次采样之间不等：用例里的占用进程是常驻的，等不等结果一样
OUT="$TMP/.stdout.txt"
ERR="$TMP/.stderr.txt"
REAL_EVIDENCE="$HOME/fabric-evidence"
REAL_EVIDENCE_BEFORE=$(ls -a "$REAL_EVIDENCE" 2>/dev/null)

g() { git -c user.name=wt-test -c user.email=wt-test@localhost "$@"; }

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
if [ "$RC" = 1 ] && grep -qF -- '--ignore-refs' "$ERR" && grep -qF -- '--export-ignored' "$ERR"; then ok
else bad "U1 用法报错列出 --ignore-refs / --export-ignored"; fi
run_wt "$REPO" rm tgt1 --bogus
if [ "$RC" = 1 ]; then ok; else bad "U2 未知参数 → exit 1（不再当成目标路径）"; fi

# ======================= wt rm：2026-10-17 新增的门 =======================

# ---- D：游离提交 ----
mk det1
T=$WT_HOME/repo-det1
g -C "$T" commit -q --allow-empty -m lost-work-det1
run_wt "$REPO" rm det1
if [ "$RC" = 2 ] && [ -d "$T" ] && grep -qF 'lost-work-det1' "$ERR" && grep -qF 'switch -c' "$ERR"; then ok
else bad "D1 detached HEAD 上有独有提交 → exit 2、树保留、列出提交、提示 switch -c"; fi
run_wt "$REPO" rm det1 --force --ignore-refs --ignored-ok
if [ "$RC" = 2 ] && [ -d "$T" ]; then ok; else bad "D1b 游离提交没有放行开关"; fi
git -C "$T" switch -q -c keep-det1
run_wt "$REPO" rm det1
if [ "$RC" = 0 ] && [ ! -e "$T" ] && git -C "$REPO" show-ref --verify --quiet refs/heads/keep-det1; then ok
else bad "D2 提交挂上分支后 → 照常拆、分支保留"; fi

# ---- W：分支上有不在任何远端的提交 → 只警告 ----
run_wt "$REPO" new w1 --branch wb1     # REPO 没有 origin：从 HEAD 切
T=$WT_HOME/repo-w1
g -C "$T" commit -q --allow-empty -m w1-work
run_wt "$REPO" rm w1
if [ "$RC" = 0 ] && [ ! -e "$T" ] && grep -qF '不在任何远端' "$ERR" \
   && git -C "$REPO" show-ref --verify --quiet refs/heads/wb1; then ok
else bad "W1 分支上有未推送提交 → 照常拆 + 警告、分支保留"; fi
RREMOTE="$TMP/rremote.git"; RREPO="$TMP/rrepo"
git init -q --bare -b main "$RREMOTE"
mkrepo "$RREPO"; git -C "$RREPO" remote add origin "$RREMOTE"; git -C "$RREPO" push -q origin main
run_wt "$RREPO" new w2 --branch wb2
T=$WT_HOME/rrepo-w2
g -C "$T" commit -q --allow-empty -m w2-work
git -C "$T" push -q origin wb2
run_wt "$RREPO" rm w2
if [ "$RC" = 0 ] && [ ! -e "$T" ] && ! grep -qF '不在任何远端' "$ERR"; then ok; else bad "W2 提交都已推送 → 不警告"; fi

# ---- H：有进程在用这棵树 ----
mk proc1; mk proc2
T=$WT_HOME/repo-proc1; T2=$WT_HOME/repo-proc2
( cd "$T" && exec sleep 60 ) & P1=$!
( exec 3< "$T2/a.txt"; cd /; exec sleep 60 ) & P2=$!
BG_PIDS="$P1 $P2"
sleep 0.5
run_wt "$REPO" rm proc1
if [ "$RC" = 2 ] && [ -d "$T" ] && grep -qF "pid=$P1 " "$ERR" && grep -qF '[cwd]' "$ERR"; then ok
else bad "H1 有进程 cwd 在树里 → exit 2、树保留、列出 pid"; fi
run_wt "$REPO" rm proc2
if [ "$RC" = 2 ] && [ -d "$T2" ] && grep -qF "pid=$P2 " "$ERR" && grep -qF "$T2/a.txt" "$ERR"; then ok
else bad "H2 有进程开着树里的文件、cwd 在别处 → exit 2、列出 pid 与文件"; fi
run_wt "$REPO" rm proc1 --force --ignore-refs --ignored-ok
if [ "$RC" = 2 ] && [ -d "$T" ]; then ok; else bad "H1b 占用门没有放行开关"; fi
kill "$P1" "$P2" 2>/dev/null; wait "$P1" "$P2" 2>/dev/null; BG_PIDS=""
run_wt "$REPO" rm proc1
if [ "$RC" = 0 ] && [ ! -e "$T" ]; then ok; else bad "H3 进程退出后 → 照常拆"; fi
run_wt "$REPO" rm proc2
if [ "$RC" = 0 ] && [ ! -e "$T2" ]; then ok; else bad "H3b 句柄关掉后 → 照常拆"; fi

# ---- I：被忽略文件 ----
IREPO="$TMP/irepo"
git init -q -b main "$IREPO"
cat > "$IREPO/.gitignore" <<'EOF'
*.log
data/*.db
cache/
notes/
__pycache__/
.DS_Store
node_modules/
.venv/
conf/local.json
EOF
mkdir -p "$IREPO/data" "$IREPO/pkg" "$IREPO/scripts" "$IREPO/conf"
echo keep > "$IREPO/data/README.md"; echo 'x = 1' > "$IREPO/pkg/m.py"; echo '{}' > "$IREPO/conf/base.json"
# 仓库钩子：建树时补一个被忽略的种子库（织锦 wt-post-new.sh 用 .backup 补 data/demo.db 的同形）
cat > "$IREPO/scripts/wt-post-new.sh" <<'EOF'
#!/usr/bin/env bash
echo seed > "$2/data/seed.db"
EOF
git -C "$IREPO" add -A; g -C "$IREPO" commit -q -m init
mkdir -p "$IREPO/.venv/bin"                  # wt new 会 symlink 进树；.venv/ 只匹配目录，树里这条链接是「未跟踪」
echo '{"k": 1}' > "$IREPO/conf/local.json"   # 主仓被忽略的本地配置
mki() { run_wt "$IREPO" new "$1"; [ "$RC" = 0 ] || bad "setup: (irepo) wt new $1"; }
TODAY=$(date +%Y-%m-%d)

mki rec1
T=$WT_HOME/irepo-rec1
REC="$(git -C "$T" rev-parse --absolute-git-dir)/wt-hydrated"
if [ -f "$REC" ] && grep -qxF 'data/seed.db' "$REC" && [ -z "$(git -C "$T" status --porcelain | grep -vxF '?? .venv')" ]; then ok
else bad "I0 wt new 把建树时就有的被忽略条目（钩子补的 data/seed.db）记进登记目录，树不因此变脏"; fi
run_wt "$IREPO" rm rec1
if [ "$RC" = 0 ] && [ ! -e "$T" ] && [ -d "$IREPO/.venv/bin" ]; then ok
else bad "I1 只有补灌产物 + 未跟踪的 .venv 链接 → 不带开关照常拆，主仓 .venv 原样"; fi

mki regen1
T=$WT_HOME/irepo-regen1
mkdir -p "$T/pkg/__pycache__" "$T/node_modules/x" "$T/cache"
echo c > "$T/pkg/__pycache__/m.cpython-312.pyc"; echo n > "$T/node_modules/x/i.js"; echo d > "$T/.DS_Store"
echo p > "$T/cache/a.pyc"; echo d > "$T/cache/.DS_Store"      # 被忽略目录里只有可再生的
ln -s "$IREPO/data/README.md" "$T/linked.log"                  # 被忽略的 symlink
cp -p "$IREPO/conf/local.json" "$T/conf/local.json"            # 与主仓同路径逐字节相同
echo changed >> "$T/data/seed.db"                              # 补灌产物改过也还是补灌产物
run_wt "$IREPO" rm regen1
if [ "$RC" = 0 ] && [ ! -e "$T" ]; then ok
else bad "I2 可再生的被忽略文件（缓存名 / pyc / .DS_Store / symlink / 主仓同款 / 改过的补灌产物）→ 不拦"; fi

mki keep1
T=$WT_HOME/irepo-keep1
mkdir -p "$T/notes" "$T/cache/sub"
echo idea > "$T/notes/idea.md"; echo zh > "$T/notes/中文 笔记.md"
echo later > "$T/data/later.db"
echo modified > "$T/conf/local.json"       # 主仓有同路径文件、但内容不同
echo bin > "$T/cache/sub/real.bin"         # 被忽略目录里混着真文件
echo p > "$T/cache/a.pyc"
run_wt "$IREPO" rm keep1
if [ "$RC" = 2 ] && [ -d "$T" ] && grep -qF 'notes/' "$ERR" && grep -qF 'data/later.db' "$ERR" \
   && grep -qF 'conf/local.json' "$ERR" && grep -qF 'cache/' "$ERR" && ! grep -qF 'data/seed.db' "$ERR" \
   && grep -qF -- '--export-ignored' "$ERR" && grep -qF -- '--ignored-ok' "$ERR"; then ok
else bad "I3 不可再生的被忽略文件 → exit 2、树保留、逐项列出（补灌产物不在列）、提示两个放行开关"; fi
run_wt "$IREPO" rm keep1 --force
if [ "$RC" = 2 ] && [ -d "$T" ]; then ok; else bad "I3b --force 不放行被忽略文件（各门各放各的）"; fi
run_wt "$IREPO" rm keep1 --export-ignored --ignored-ok
if [ "$RC" = 1 ] && [ -d "$T" ]; then ok; else bad "I3c --export-ignored 与 --ignored-ok 二选一"; fi
run_wt "$IREPO" rm keep1 --export-ignored
EV="$WT_EVIDENCE_HOME/$TODAY-wt-irepo-keep1"
if [ "$RC" = 0 ] && [ ! -e "$T" ] && [ -f "$EV/MANIFEST.sha256" ] && [ "$(cat "$EV/notes/idea.md" 2>/dev/null)" = idea ] \
   && [ -f "$EV/notes/中文 笔记.md" ] && [ -f "$EV/data/later.db" ] && [ -f "$EV/conf/local.json" ] \
   && [ -f "$EV/cache/sub/real.bin" ] && [ ! -e "$EV/cache/a.pyc" ] && [ ! -e "$EV/data/seed.db" ] \
   && ( cd "$EV" && shasum -a 256 -c --quiet MANIFEST.sha256 ) >/dev/null 2>&1 && grep -qF "$EV" "$OUT"; then ok
else bad "I4 --export-ignored → 按相对路径导出（含中文名）+ 可回验的 sha256 清单、不带可再生的，然后拆树"; fi

mki keep2
T=$WT_HOME/irepo-keep2
mkdir -p "$T/notes"; echo x > "$T/notes/x.md"
run_wt "$IREPO" rm keep2 --ignored-ok
if [ "$RC" = 0 ] && [ ! -e "$T" ] && [ ! -e "$WT_EVIDENCE_HOME/$TODAY-wt-irepo-keep2" ]; then ok
else bad "I5 --ignored-ok → 不导出直接拆"; fi

for round in 1 2; do
  mki keep3; mkdir -p "$WT_HOME/irepo-keep3/notes"; echo "r$round" > "$WT_HOME/irepo-keep3/notes/r.md"
  run_wt "$IREPO" rm keep3 --export-ignored
done
EV_DIRS=$(ls -d "$WT_EVIDENCE_HOME/$TODAY-wt-irepo-keep3"* 2>/dev/null | wc -l | tr -d ' ')
if [ "$RC" = 0 ] && [ "$EV_DIRS" = 2 ] && [ "$(cat "$WT_EVIDENCE_HOME/$TODAY-wt-irepo-keep3/notes/r.md")" = r1 ]; then ok
else bad "I6 同一天同一棵树导出两次 → 另起目录，第一次的证据原样"; fi

# ---- F：git worktree remove 拒绝就停，不再 rm -rf 兜底 ----
mki lock1
T=$WT_HOME/irepo-lock1
git -C "$IREPO" worktree lock --reason resident-line "$T"
run_wt "$IREPO" rm lock1
if [ "$RC" = 2 ] && [ -f "$T/data/README.md" ] && grep -qF 'git worktree remove 不肯拆' "$ERR" \
   && grep -qF 'resident-line' "$ERR" && [ -L "$T/.venv" ]; then ok
else bad "F1 git worktree remove 拒绝（树被 lock）→ exit 2、不 rm -rf、树原样（.venv 链接挂回）、报出 git 的原因"; fi
git -C "$IREPO" worktree unlock "$T"
run_wt "$IREPO" rm lock1
if [ "$RC" = 0 ] && [ ! -e "$T" ]; then ok; else bad "F1b 解锁后照常拆"; fi
mkdir -p "$TMP/plain-dir"; echo precious > "$TMP/plain-dir/file.txt"
run_wt "$REPO" rm "$TMP/plain-dir"
if [ "$RC" = 2 ] && [ -f "$TMP/plain-dir/file.txt" ] && grep -qF '不是本仓登记的 worktree' "$ERR"; then ok
else bad "F2 不是本仓 worktree 的目录 → exit 2、原样不动（在登记检查这一步就拦下）"; fi
mk gone1
rm -rf "$WT_HOME/repo-gone1"
run_wt "$REPO" rm gone1
if [ "$RC" = 0 ] && ! in_list "$WT_HOME/repo-gone1"; then ok; else bad "F3 登记还在、目录已没 → 只清登记、exit 0"; fi
run_wt "$REPO" rm never-existed
if [ "$RC" = 1 ]; then ok; else bad "F4 既没目录也没登记 → exit 1"; fi

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

# ---- 隔离自证：本仓真实 config 没被测试碰过；真实证据目录没多出东西 ----
if [ "$(shasum "$SELF_REPO_CONFIG" 2>/dev/null)" = "$SELF_SUM_BEFORE" ]; then ok; else
  fail=$((fail + 1)); echo "FAIL ISO 本仓 $SELF_REPO_CONFIG 在测试期间被改动 —— 隔离失效，立刻人工检查"; fi
if [ "$(ls -a "$REAL_EVIDENCE" 2>/dev/null)" = "$REAL_EVIDENCE_BEFORE" ]; then ok; else
  fail=$((fail + 1)); echo "FAIL ISO2 $REAL_EVIDENCE 在测试期间多了东西 —— WT_EVIDENCE_HOME 隔离失效，立刻人工检查"; fi

echo "PASS $pass / FAIL $fail"
[ "$fail" -eq 0 ]
