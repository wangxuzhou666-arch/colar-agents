#!/usr/bin/env bash
# .githooks/pre-commit 里 house-rules 风格 digest 守卫（`compile --check --staged`）的判别力自证 —— CODING-STYLE R.7。
#   P 组（必须拦，exit 1，且 stderr 钉到具体哪个 stale 输出 —— R.7 ③）：
#     P1 改了条款、只 stage CODING-STYLE.md
#     P2 重新 compile 了但忘了 `git add` digest（--staged 的存在理由；只看工作树的旧手写守卫会放行）
#     P3 手改 inject target 里 style-digest 块内的内容
#   N 组（必须放行 —— 覆盖明写的放行例外，R.7 ①）：
#     N0 刚 compile 过的干净基线
#     N1 compile 后把 rules + digest + inject targets 一起 stage
#     N2 改 inject target 里 marker 块之外的内容
#     N3 条款改动只在工作树、没 stage（按将要提交的内容判，不看工作树）
#     N4 环境里 HOUSE_RULES_BIN 指向不存在的路径 → 不拦，但 stderr 必须有响亮 WARNING（静默跳过 = 这道门从此再也不会红）
#     N5 环境里 HOUSE_RULES_PY 指向不存在的解释器（如 brew 升级 Python 后）→ 同上
#     N6 仓里没有 .house-rules.json → 静默跳过（core.hooksPath 可被多仓共用）
#   M 组（退回旧行为必须转绿 —— R.7 ②，证明 P1 的红来自 house-rules 块而非别处巧合）：
#     M1 删掉 `# house-rules:begin…end` 块（= 接 house-rules 之前的 hook）→ P1 场景放行
#     M2 在块上方插一行 `exit 0`（`house-rules init` 把块放在 shebang 正下方，块上方的早退会让守卫变死代码）→ P1 场景放行
#
# 跑法：bash .githooks/tests/test_pre_commit_digest_guard.sh
# 变异验证：HOOK_SRC=<改坏的 hook 副本> bash 本脚本 → 对应用例必须转红。
# hook 块是 portable 版（不写死机器路径），所以本脚本自己定位 house-rules：HOUSE_RULES_BIN 环境变量 → PATH 上的
# house-rules → ~/Desktop/house-rules/bin/house-rules；HOUSE_RULES_PY 环境变量 → python3.12 → python3（须 ≥3.10）。
# 解析结果 export 给每次 fixture 提交，hook 走的是同一份；找不到则 exit 2。
#
# 隔离：fixture 是 mktemp 目录里新 git init 的仓，只拷入 .house-rules.json 指向的文件；剥掉 GIT_DIR 等变量，
# GIT_CONFIG_GLOBAL=/dev/null + GIT_CONFIG_NOSYSTEM=1；结尾校验本仓 .git/config 与 HEAD 前后不变。
# 判断退出码一律不走管道。
set -u
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
REAL_HOOK="$REPO/.githooks/pre-commit"
HOOK_SRC=${HOOK_SRC:-$REAL_HOOK}

HOUSE_RULES_BIN="${HOUSE_RULES_BIN:-$(command -v house-rules || true)}"
if [ -z "$HOUSE_RULES_BIN" ] && [ -f "$HOME/Desktop/house-rules/bin/house-rules" ]; then
  HOUSE_RULES_BIN="$HOME/Desktop/house-rules/bin/house-rules"
fi
HOUSE_RULES_PY="${HOUSE_RULES_PY:-$(command -v python3.12 || command -v python3 || true)}"
if [ ! -f "$HOUSE_RULES_BIN" ] || ! "$HOUSE_RULES_PY" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
  echo "cannot run: house-rules not available (HOUSE_RULES_PY='$HOUSE_RULES_PY' HOUSE_RULES_BIN='$HOUSE_RULES_BIN'); set HOUSE_RULES_BIN to the house-rules script and HOUSE_RULES_PY to a 3.10+ interpreter" >&2
  exit 2
fi
# portable hook 先看这两个环境变量；export 后每次 fixture 提交都用同一份工具
export HOUSE_RULES_BIN HOUSE_RULES_PY

config_before=$(cksum < "$REPO/.git/config")
head_before=$(git -C "$REPO" rev-parse HEAD)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/digest-guard.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
FX="$WORK/repo"; ERR="$WORK/stderr"; mkdir -p "$FX/.githooks"

# 只拷 .house-rules.json 里点名的文件，fixture 不碰真仓的其余内容
"$HOUSE_RULES_PY" - "$REPO" "$FX" <<'EOF'
import json, shutil, sys
from pathlib import Path
src, dst = Path(sys.argv[1]), Path(sys.argv[2])
cfg = json.loads((src / ".house-rules.json").read_text(encoding="utf-8"))
names = [".house-rules.json", *cfg["rules_files"], cfg.get("digest", "CODING-STYLE.digest.md"), *cfg.get("inject_targets", [])]
for name in names:
    (dst / name).parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src / name, dst / name)
EOF
RULES=$("$HOUSE_RULES_PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["rules_files"][0])' "$FX/.house-rules.json")
DIGEST=$("$HOUSE_RULES_PY" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("digest", "CODING-STYLE.digest.md"))' "$FX/.house-rules.json")
TARGET=$("$HOUSE_RULES_PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["inject_targets"][0])' "$FX/.house-rules.json")

G() { git -C "$FX" -c user.name=fx -c user.email=fx@example.invalid -c commit.gpgsign=false "$@"; }
compile() { "$HOUSE_RULES_PY" "$HOUSE_RULES_BIN" compile --repo "$FX" >/dev/null; }
install_hook() { cp "$1" "$FX/.githooks/pre-commit"; chmod +x "$FX/.githooks/pre-commit"; }
FRESH=""  # N0 的提交：已知 fresh 的起点；N4/N5 会故意提交 stale 状态，所以每例都回到这里
reset_fresh() { G reset -q --hard "$FRESH"; install_hook "$HOOK_SRC"; }
try_commit() { G commit -q --allow-empty -m "$1" >/dev/null 2>"$ERR"; }

# 改一条条款：在 P3.4 行第一个句号前插字，短规则和源文件 hash 都会变
edit_clause() {
  "$HOUSE_RULES_PY" - "$FX/$RULES" <<'EOF'
import sys
from pathlib import Path
path = Path(sys.argv[1]); lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
idx = next(i for i, line in enumerate(lines) if "[P3.4]" in line)
lines[idx] = lines[idx].replace("。", "，断点同理。", 1) if "。" in lines[idx] else lines[idx].rstrip("\n") + " (edited)\n"
path.write_text("".join(lines), encoding="utf-8")
EOF
}
# $1 = inside | outside：改 inject target 的 marker 块之内 / 之外
edit_target() {
  "$HOUSE_RULES_PY" - "$FX/$TARGET" "$1" <<'EOF'
import sys
from pathlib import Path
path, where = Path(sys.argv[1]), sys.argv[2]
text = path.read_text(encoding="utf-8")
if where == "inside":
    assert "P3.1 | nice |" in text, "injected block has no P3.1 line"
    text = text.replace("P3.1 | nice |", "P3.1 | should-fix |", 1)
else:
    text += "\nA line outside the style-digest markers.\n"
path.write_text(text, encoding="utf-8")
EOF
}

pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass+1)); }
bad() { echo "  FAIL $1"; sed 's/^/       | /' "$ERR"; fail=$((fail+1)); }
# $1 label, $2 expected rc, $3 actual rc, $4 (optional) fixed string stderr must contain
expect() {
  if [ "$2" != "$3" ]; then bad "$1 (expected exit $2, got $3)"; return; fi
  if [ -n "${4:-}" ] && ! grep -qF -- "$4" "$ERR"; then bad "$1 (exit $3, but stderr lacks: $4)"; return; fi
  ok "$1 (exit $3)"
}
expect_quiet() { if [ -s "$ERR" ]; then bad "$1 (expected empty stderr)"; else ok "$1 (stderr empty)"; fi; }

G init -q
G config core.hooksPath .githooks
install_hook "$HOOK_SRC"
compile  # 起点与真仓当前是否 stale 无关

echo "== N0 fresh baseline"
G add -A; try_commit "fresh"; expect "N0 fresh digest is allowed" 0 $?
FRESH=$(G rev-parse HEAD)

echo "== P1 clause edited, only the rules file staged"
edit_clause; G add "$RULES"; try_commit "stale"
expect "P1 stale digest is blocked" 1 $? "stale: $DIGEST (digest, the STAGED version is out of date)"

echo "== P2 recompiled in the working tree, digest not staged"
reset_fresh; edit_clause; compile; G add "$RULES"; try_commit "forgot-add"
expect "P2 unstaged regenerated digest is blocked" 1 $? "stale: $DIGEST (digest, the STAGED version is out of date)"

echo "== N1 recompiled and every output staged"
reset_fresh; edit_clause; compile; G add -A; try_commit "recompiled"
expect "N1 recompiled + staged is allowed" 0 $?

echo "== P3 hand edit inside an injected block"
reset_fresh; edit_target inside; G add "$TARGET"; try_commit "hand-edit"
expect "P3 hand-edited injected block is blocked" 1 $? "stale: $TARGET (injected block, the STAGED version is out of date)"

echo "== N2 edit outside the markers of an inject target"
reset_fresh; edit_target outside; G add "$TARGET"; try_commit "outside"
expect "N2 edit outside the markers is allowed" 0 $?

echo "== N3 clause edit only in the working tree"
reset_fresh; edit_clause; try_commit "wt-only"
expect "N3 unstaged clause edit is not judged" 0 $?

echo "== N4 HOUSE_RULES_BIN missing (stale staged state)"
# 子 shell 里改已 export 的变量：只影响这一次提交，不污染后续用例
reset_fresh; edit_clause; G add "$RULES"
( HOUSE_RULES_BIN="$WORK/no-such-house-rules"; try_commit "no-bin" )
expect "N4 missing house-rules does not block, warns" 0 $? "house-rules: WARNING: cannot find the house-rules executable"
grep -qF "pre-commit is NOT running" "$ERR" && ok "N4 warning says the check is not running" || bad "N4 warning does not say the check is not running"

echo "== N5 HOUSE_RULES_PY missing (stale staged state)"
reset_fresh; edit_clause; G add "$RULES"
( HOUSE_RULES_PY="$WORK/no-such-python"; try_commit "no-py" )
expect "N5 missing interpreter does not block, warns" 0 $? "house-rules: WARNING: $WORK/no-such-python is missing or older than Python 3.10"
grep -qF "pre-commit is NOT running" "$ERR" && ok "N5 warning says the check is not running" || bad "N5 warning does not say the check is not running"

echo "== N6 repo without .house-rules.json (stale staged state)"
reset_fresh; edit_clause; G add "$RULES"; mv "$FX/.house-rules.json" "$WORK/house-rules.json.away"
try_commit "no-config"; expect "N6 no config is skipped" 0 $?; expect_quiet "N6 skip is silent"
mv "$WORK/house-rules.json.away" "$FX/.house-rules.json"

echo "== M1 hook without the house-rules block, P1 scenario -> must turn green"
reset_fresh; sed '/^# house-rules:begin$/,/^# house-rules:end$/d' "$HOOK_SRC" > "$WORK/hook-m1"
if ! grep -q "^# house-rules:begin$" "$HOOK_SRC" || grep -q "^# house-rules:begin" "$WORK/hook-m1"; then bad "M1 could not strip the block"; fi
install_hook "$WORK/hook-m1"; edit_clause; G add "$RULES"; try_commit "m1"
expect "M1 without the block the stale commit passes" 0 $?

echo "== M2 'exit 0' above the block, P1 scenario -> must turn green"
reset_fresh; sed 's/^# house-rules:begin$/exit 0\
# house-rules:begin/' "$HOOK_SRC" > "$WORK/hook-m2"
install_hook "$WORK/hook-m2"; edit_clause; G add "$RULES"; try_commit "m2"
expect "M2 an early exit kills the guard" 0 $?

echo "== isolation"
[ "$(cksum < "$REPO/.git/config")" = "$config_before" ] && ok "real .git/config unchanged" || { echo "  FAIL real .git/config changed"; fail=$((fail+1)); }
[ "$(git -C "$REPO" rev-parse HEAD)" = "$head_before" ] && ok "real HEAD unchanged" || { echo "  FAIL real HEAD changed"; fail=$((fail+1)); }

echo "== result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
