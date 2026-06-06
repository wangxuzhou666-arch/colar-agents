#!/usr/bin/env bash
# Memory drift detection — scans memory/ vs MEMORY.md for index mismatch + stale candidates.
#
# Usage:    bash scripts/memory_drift_check.sh
# Exit:     always 0 (advisory, never blocks). Silent when clean.
# Why:      MEMORY.md is human-curated index for groupings/visual anchors. This script
#           detects drift but does NOT auto-modify (preserves curation). Output is paste-ready
#           — copy frontmatter snippets into MEMORY.md sections by hand.
#
# Output sections:
#   1. Unindexed files (dir 有 / MEMORY.md 没指 → 写入纪律失效信号)
#   2. Dead links (MEMORY.md 指了 / dir 没文件 → 删除后忘清理 index)
#   3. Stale candidates (短 + 老 + 无视觉锚 → archive 候选,不强制删)

set -u

MEMORY_DIR="${HOME}/.claude/projects/-Users-colar-Desktop-agency-agents/memory"
INDEX="${MEMORY_DIR}/MEMORY.md"

[ -d "$MEMORY_DIR" ] || { echo "memory dir not found: $MEMORY_DIR" >&2; exit 0; }
[ -f "$INDEX" ] || { echo "MEMORY.md not found: $INDEX" >&2; exit 0; }

cd "$MEMORY_DIR"

ACTUAL_FILE=$(mktemp)
INDEXED_FILE=$(mktemp)
trap 'rm -f "$ACTUAL_FILE" "$INDEXED_FILE"' EXIT

ls feedback_*.md project_*.md user_*.md reference_*.md 2>/dev/null | sort > "$ACTUAL_FILE"
# Tiered index: MEMORY.md 是热索引, 冷条目下沉到 *-index.md 子索引(reference-index.md 等)。
# 三者一起算 "indexed", 否则外移到子索引的文件会被误报 unindexed。
INDEX_FILES="MEMORY.md"
for sub in *-index.md transcripts/INDEX.md; do
    [ -f "$sub" ] && INDEX_FILES="$INDEX_FILES $sub"
done
grep -hoE '(feedback|project|user|reference)_[a-z_0-9]+\.md' $INDEX_FILES 2>/dev/null | sort -u > "$INDEXED_FILE"

UNINDEXED=$(comm -23 "$ACTUAL_FILE" "$INDEXED_FILE")
DEAD=$(comm -13 "$ACTUAL_FILE" "$INDEXED_FILE")

ANY_HIT=0

# Section 1: Unindexed
if [ -n "$UNINDEXED" ]; then
    ANY_HIT=1
    echo "=== UNINDEXED (dir 有 / MEMORY.md 没指) ==="
    echo "$UNINDEXED" | while read -r f; do
        [ -z "$f" ] && continue
        name=$(awk '/^---$/{c++; next} c==1 && /^name:/{sub(/^name:[[:space:]]*/, ""); print; exit}' "$f")
        desc=$(awk '/^---$/{c++; next} c==1 && /^description:/{sub(/^description:[[:space:]]*/, ""); print; exit}' "$f")
        echo "  $f"
        [ -n "$name" ] && echo "    name: $name"
        [ -n "$desc" ] && echo "    desc: $desc"
    done
    echo
fi

# Section 2: Dead links
if [ -n "$DEAD" ]; then
    ANY_HIT=1
    echo "=== DEAD LINKS (MEMORY.md 指了 / dir 没文件) ==="
    echo "$DEAD" | sed 's/^/  /'
    echo
fi

# Section 3: SOUL ↔ memory content overlap
# 提取 SOUL 所有 **bold** 短语作 axiom 关键词,扫 memory frontmatter name/description
# 是否子串命中。命中 = 候选重复(SOUL 已 cover,不该再写 memory)
SOUL_PATH="${HOME}/.claude/CLAUDE.md"
if [ -f "$SOUL_PATH" ]; then
    SOUL_PHRASES=$(mktemp)
    # 提取 **X** 中文/英文 bold 短语,长度 ≥ 4 char(过滤单字符 / 短虚词)
    grep -oE '\*\*[^*]{4,40}\*\*' "$SOUL_PATH" \
        | sed 's/\*\*//g' \
        | sort -u > "$SOUL_PHRASES"

    OVERLAP=""
    for f in feedback_*.md; do
        [ -f "$f" ] || continue
        meta=$(awk '/^---$/{c++; next} c==1 && /^(name|description):/' "$f" | head -2 | tr '[:upper:]' '[:lower:]')
        [ -z "$meta" ] && continue
        while IFS= read -r phrase; do
            [ -z "$phrase" ] && continue
            phrase_lc=$(echo "$phrase" | tr '[:upper:]' '[:lower:]')
            if echo "$meta" | grep -qF "$phrase_lc" 2>/dev/null; then
                OVERLAP="$OVERLAP  $f  ←→ SOUL: '$phrase'"$'\n'
            fi
        done < "$SOUL_PHRASES"
    done

    rm -f "$SOUL_PHRASES"

    if [ -n "$OVERLAP" ]; then
        ANY_HIT=1
        echo "=== SOUL ↔ MEMORY OVERLAP (memory frontmatter 含 SOUL bold axiom 短语) ==="
        printf '%s' "$OVERLAP"
        echo "  注: 候选重复。SOUL 已 cover 该 axiom,memory 可能多余。"
        echo "  → 决策: 删 memory(SOUL 已写) / 升级 SOUL(memory 更细致) / 保留(细化案例,加 pointer)"
        echo
    fi
fi

# Section 4: Stale candidates (UX heuristic — 短 + 60d+ + 无视觉锚)
STALE=$(find . -maxdepth 1 -name "feedback_*.md" -mtime +60 -size -1500c 2>/dev/null | while read -r f; do
    lines=$(wc -l < "$f" 2>/dev/null)
    [ -z "$lines" ] && continue
    if [ "$lines" -lt 25 ]; then
        if ! grep -qE '🔴|⚠️|🆕|🚨|🔄' "$f" 2>/dev/null; then
            mtime=$(stat -f "%Sm" -t "%Y-%m-%d" "$f" 2>/dev/null)
            echo "  $mtime  ${lines}L  $(basename "$f")"
        fi
    fi
done | sort)

if [ -n "$STALE" ]; then
    ANY_HIT=1
    echo "=== STALE CANDIDATES (短文件 + 60d+ 未改 + 无视觉锚 → archive 候选) ==="
    echo "$STALE"
    echo "  注: 这是 advisory,不删。先 grep 验证无 active 引用再决定。"
    echo
fi

# Counts (always print, even when clean)
FB=$(ls feedback_*.md 2>/dev/null | wc -l | tr -d ' ')
PJ=$(ls project_*.md 2>/dev/null | wc -l | tr -d ' ')
US=$(ls user_*.md 2>/dev/null | wc -l | tr -d ' ')
RF=$(ls reference_*.md 2>/dev/null | wc -l | tr -d ' ')
TR=$(ls transcripts/*.md 2>/dev/null | wc -l | tr -d ' ')
LN=$(wc -l < MEMORY.md | tr -d ' ')

if [ "$ANY_HIT" -eq 0 ]; then
    echo "✓ memory drift clean — feedback:$FB / project:$PJ / user:$US / reference:$RF / transcripts:$TR · MEMORY.md:${LN}L"
else
    echo "=== COUNTS ==="
    echo "  feedback:$FB / project:$PJ / user:$US / reference:$RF / transcripts:$TR"
    echo "  MEMORY.md: ${LN} lines (200 truncate limit)"
fi

exit 0
