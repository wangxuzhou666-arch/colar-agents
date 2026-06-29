#!/usr/bin/env bash
# sync-agents.sh — Sync agent files from master library to project .claude/agents/
# Usage: ./sync-agents.sh [project-path]  (defaults to current dir)
# Reads: <project>/.claude/agent-config.yaml
#
# Cross-platform: MASTER_LIB is auto-detected from this script's location
# (assumes scripts/ sits inside agency-agents/). Works on macOS (bash 3.2)
# and Windows Git Bash / WSL — no bash 4+ features used.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MASTER_LIB="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT="${1:-.}"
# Canonicalize so "." / relative / trailing-slash all resolve before the $HOME test
PROJECT="$(cd "$PROJECT" 2>/dev/null && pwd || echo "$PROJECT")"
CONFIG="$PROJECT/.claude/agent-config.yaml"

# Dual policy:
#   user-level (~/.claude/agents) → symlink (live: editing master reflects instantly)
#   project-level                 → cp     (snapshot: project pins a version, master edits don't leak in)
# See agency-agents/CLAUDE.md "Agent 自动发现". Override with SYNC_MODE=link|copy if ever needed.
if [[ "${SYNC_MODE:-}" == "link" ]]; then
  LINK_MODE=1
elif [[ "${SYNC_MODE:-}" == "copy" ]]; then
  LINK_MODE=0
elif [[ "$PROJECT" == "$HOME" ]]; then
  LINK_MODE=1
else
  LINK_MODE=0
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: No agent-config.yaml found at $CONFIG"
  exit 1
fi

TARGET="$PROJECT/.claude/agents"
mkdir -p "$TARGET"

SYNCED=0
SKIPPED=0
ERRORS=0

# Parse YAML without dependencies — simple line-based parser
MODE=""
FILES=()

while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" ]] && continue

  if [[ "$line" == "include:" ]]; then
    MODE="include"
    continue
  elif [[ "$line" == "categories:" ]]; then
    MODE="categories"
    continue
  elif [[ "$line" =~ ^[a-z] ]]; then
    MODE=""
    continue
  fi

  if [[ "$MODE" == "include" && "$line" =~ ^[[:space:]]*-[[:space:]]+(.*) ]]; then
    FILES+=("${BASH_REMATCH[1]}")
  elif [[ "$MODE" == "categories" && "$line" =~ ^[[:space:]]*-[[:space:]]+(.*) ]]; then
    category="${BASH_REMATCH[1]}"
    if [[ -d "$MASTER_LIB/$category" ]]; then
      for f in "$MASTER_LIB/$category"/*.md; do
        [[ -f "$f" ]] && FILES+=("$category/$(basename "$f")")
      done
    else
      echo "WARN: category '$category' not found in master library"
      ERRORS=$((ERRORS+1))
    fi
  fi
done < "$CONFIG"

# Deduplicate (bash 3.2 compatible — no readarray)
if [[ ${#FILES[@]} -gt 0 ]]; then
  DEDUPED=()
  while IFS= read -r rel; do
    DEDUPED+=("$rel")
  done < <(printf '%s\n' "${FILES[@]}" | sort -u)
  FILES=("${DEDUPED[@]}")
fi

# Build expected-basename newline list for stale detection (bash 3.2 compatible)
EXPECTED_LIST=""
for rel in "${FILES[@]}"; do
  EXPECTED_LIST="$EXPECTED_LIST$(basename "$rel")"$'\n'
done

# Sync files
for rel in "${FILES[@]}"; do
  src="$MASTER_LIB/$rel"
  dest="$TARGET/$(basename "$rel")"

  if [[ ! -f "$src" ]]; then
    echo "WARN: $rel not found in $MASTER_LIB"
    ERRORS=$((ERRORS+1))
    continue
  fi

  if [[ "$LINK_MODE" == "1" ]]; then
    # Symlink mode: dest should be a symlink pointing at the master file.
    if [[ -L "$dest" && "$(readlink "$dest")" == "$src" ]]; then
      SKIPPED=$((SKIPPED+1))
      continue
    fi
    # Replace whatever is there (stale symlink, or a drifted real-file copy) with a fresh link.
    ln -sfn "$src" "$dest"
    SYNCED=$((SYNCED+1))
  else
    # Copy mode (snapshot). Skip only if an identical *real file* is already there.
    if [[ -f "$dest" && ! -L "$dest" ]] && cmp -s "$src" "$dest"; then
      SKIPPED=$((SKIPPED+1))
      continue
    fi
    # If a stale symlink is sitting here, drop it first so we write a real copy, not through the link.
    [[ -L "$dest" ]] && rm -f "$dest"
    cp "$src" "$dest"
    SYNCED=$((SYNCED+1))
  fi
done

# Report stale (file present in target but not in config)
STALE=0
if [[ -d "$TARGET" ]]; then
  for f in "$TARGET"/*.md; do
    [[ -f "$f" ]] || continue
    base=$(basename "$f")
    if ! printf '%s\n' "$EXPECTED_LIST" | grep -Fxq "$base"; then
      STALE=$((STALE+1))
    fi
  done
fi

total=$(ls "$TARGET"/*.md 2>/dev/null | wc -l | tr -d ' ')
MODE_LABEL=$([[ "$LINK_MODE" == "1" ]] && echo "symlink (live)" || echo "copy (snapshot)")
echo "Done [$MODE_LABEL]: $SYNCED synced, $SKIPPED unchanged, $ERRORS errors, $STALE stale (in target but not in config)"
echo "Target: $TARGET ($total agents total)"
echo "Master: $MASTER_LIB"
