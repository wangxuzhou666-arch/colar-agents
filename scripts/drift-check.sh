#!/usr/bin/env bash
# SOUL drift detection — scans soul/SOUL.md for stale terms and broken path refs.
# Usage:    bash scripts/drift-check.sh [path/to/SOUL.md]
# Exit:     always 0 (advisory, never blocks). Silent when no drift detected.
# Config:   soul/drift-blacklist.txt (terms to flag), soul/drift-whitelist.txt (exemptions)

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOUL_PATH="${1:-soul/SOUL.md}"
BLACKLIST="soul/drift-blacklist.txt"
WHITELIST="soul/drift-whitelist.txt"

SOUL_ABS="$ROOT/$SOUL_PATH"
BL_ABS="$ROOT/$BLACKLIST"
WL_ABS="$ROOT/$WHITELIST"

[ -f "$SOUL_ABS" ] || exit 0

WL_CONTENT=""
[ -f "$WL_ABS" ] && WL_CONTENT="$(cat "$WL_ABS")"

is_whitelisted() {
    local key="$1"
    case $'\n'"$WL_CONTENT"$'\n' in
        *$'\n'"$key"$'\n'*) return 0 ;;
        *) return 1 ;;
    esac
}

declare -a HITS=()

# 1. Blacklist term scan
if [ -f "$BL_ABS" ]; then
    while IFS= read -r term || [ -n "$term" ]; do
        [ -z "$term" ] && continue
        case "$term" in \#*) continue ;; esac
        is_whitelisted "BLACKLIST:$term" && continue
        if grep -nF -- "$term" "$SOUL_ABS" >/dev/null 2>&1; then
            line=$(grep -nF -- "$term" "$SOUL_ABS" | head -1)
            HITS+=("BLACKLIST  $line  ->  term=\"$term\"")
        fi
    done < "$BL_ABS"
fi

# 2. Broken path targets (.md/.py/.sh/.json/.yml)
#    Scans both: (a) markdown link syntax ](path)  (b) bare filenames (e.g. `feedback_x.md`)
#    Resolves against: soul/, repo root, AND memory dir (~/.claude/projects/.../memory/)
TMP_PATHS="$(mktemp 2>/dev/null || echo "/tmp/drift-paths.$$")"
{
    # (a) markdown link form: ](path.ext)
    grep -oE '\]\([^)]+\.(md|py|sh|json|ya?ml)\)' "$SOUL_ABS" 2>/dev/null \
        | sed -E 's/^\]\(//; s/\)$//'
    # (b) bare filename form: word_chars.ext (uses backticks or appears as plain token)
    grep -oE '[A-Za-z0-9_./-]+\.(md|py|sh|json|ya?ml)\b' "$SOUL_ABS" 2>/dev/null
} | sort -u > "$TMP_PATHS"

soul_dir="$(dirname "$SOUL_ABS")"
MEM_DIR="$HOME/.claude/projects/-Users-colar-Desktop-colar-agents/memory"
while IFS= read -r path || [ -n "$path" ]; do
    [ -z "$path" ] && continue
    case "$path" in
        http*|https*) continue ;;
        /*|[A-Za-z]:[\\/]*) continue ;;
        ~*) continue ;;
    esac
    is_whitelisted "PATH:$path" && continue
    if [ ! -e "$soul_dir/$path" ] \
       && [ ! -e "$ROOT/$path" ] \
       && [ ! -e "$MEM_DIR/$path" ]; then
        HITS+=("MISSING_PATH  $path")
    fi
done < "$TMP_PATHS"
rm -f "$TMP_PATHS"

if [ ${#HITS[@]} -eq 0 ]; then
    exit 0
fi

echo "[SOUL drift] $(date +%Y-%m-%d) — ${#HITS[@]} hit(s) in $SOUL_PATH"
for h in "${HITS[@]}"; do
    echo "  $h"
done
echo ""
# 纯提示文本(本脚本无 read 输入,交互式菜单是死 UI —— 2026-07-06 修)
echo "修复选项(advisory,自行执行): 改 soul/SOUL.md · 改对应 memory 文件 · 或加白名单豁免:"
echo "  echo 'BLACKLIST:<term>' >> $WHITELIST   # 豁免措辞条目"
echo "  echo 'PATH:<path>'      >> $WHITELIST   # 豁免路径条目"
exit 0
