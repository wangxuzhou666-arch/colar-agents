#!/usr/bin/env bash
# prune_handoffs.sh — handoff 落盘的归档 + 清理（/handoff Step 4 retention 规则的执行体）
#
# 背景：/handoff.md Step 4 写了 retention 规则（"/resume 消费后删，或只保留最近 N 个"），
# 但从 2026-07-11 到 2026-09-13 两个月零执行，织锦 repo 累积 379 份 4.2MB。
# 本脚本把那条规则变成真正会跑的机械层。
#
# 策略：保留最近 RETAIN_DAYS 天；更早的先打包进 handoffs-archive/，验证包完整后才删。
# 绝不做无备份删除 —— 归档失败即中止，一个文件都不动。
#
# 用法：
#   bash prune_handoffs.sh                      # 对当前 git repo 跑
#   bash prune_handoffs.sh /path/to/repo        # 指定 repo
#   DRY_RUN=1 bash prune_handoffs.sh            # 只看会删什么，不动手
#   RETAIN_DAYS=30 bash prune_handoffs.sh       # 改保留窗口

set -euo pipefail

RETAIN_DAYS="${RETAIN_DAYS:-14}"
DRY_RUN="${DRY_RUN:-0}"

# ---- 定位 repo（一律绝对路径，不赌 cwd）----
if [[ $# -ge 1 ]]; then
  REPO="$1"
else
  REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
[[ -z "$REPO" ]] && { echo "prune_handoffs: 不在 git repo 里且未传 repo 路径，跳过"; exit 0; }

HANDOFFS="$REPO/.claude/handoffs"
ARCHIVE="$REPO/.claude/handoffs-archive"
[[ -d "$HANDOFFS" ]] || { echo "prune_handoffs: $HANDOFFS 不存在，跳过"; exit 0; }

# ---- 每日自限（接 Stop hook 时用，避免每次 session 结束都跑）----
# ONCE_PER_DAY=1 时，同一天内第二次调用直接静默退出。
if [[ "${ONCE_PER_DAY:-0}" == "1" ]]; then
  STAMP="$ARCHIVE/.last-prune"
  TODAY="$(date +%Y-%m-%d)"
  [[ -f "$STAMP" && "$(cat "$STAMP" 2>/dev/null)" == "$TODAY" ]] && exit 0
  mkdir -p "$ARCHIVE"
  echo "$TODAY" > "$STAMP"
fi

# ---- 算截止日期（保留 >= CUTOFF 的）----
if date -v-1d >/dev/null 2>&1; then          # BSD date (macOS)
  CUTOFF="$(date -v-"${RETAIN_DAYS}"d +%Y-%m-%d)"
else                                          # GNU date
  CUTOFF="$(date -d "${RETAIN_DAYS} days ago" +%Y-%m-%d)"
fi

echo "prune_handoffs: repo=$REPO"
echo "  保留窗口 ${RETAIN_DAYS} 天 → 保留 >= ${CUTOFF} 的，更早的归档后删"

# ---- 挑出该归档的文件 ----
# 文件名形如 2026-09-11T1130[-slug].md → 取前 10 字符当日期。
# 非日期命名（UUID 等）用 mtime 兜底，绝不误判成"很旧"。
OLD=()
SKIPPED=()
while IFS= read -r f; do
  base="$(basename "$f")"
  # 内容级判据：目录里混过 runbook / 临时笔记这类非 handoff 的 .md，
  # 光看命名拦不住。真 handoff 必带 lane: 与 session_id: 两个 frontmatter 字段。
  if ! grep -qE '^\s*session_id\s*:' "$f" || ! grep -qE '^\s*lane\s*:' "$f"; then
    SKIPPED+=("$base")
    continue
  fi
  if [[ "$base" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})T ]]; then
    fdate="${BASH_REMATCH[1]}"
  else
    # 无日期命名：用 mtime
    if stat -f %Sm -t %Y-%m-%d "$f" >/dev/null 2>&1; then
      fdate="$(stat -f %Sm -t %Y-%m-%d "$f")"
    else
      fdate="$(stat -c %y "$f" | cut -d' ' -f1)"
    fi
  fi
  [[ "$fdate" < "$CUTOFF" ]] && OLD+=("$base")
done < <(find "$HANDOFFS" -maxdepth 1 -name "*.md" -type f)

TOTAL="$(find "$HANDOFFS" -maxdepth 1 -name '*.md' -type f | wc -l | tr -d ' ')"
echo "  目录内 ${TOTAL} 个 .md，其中 ${#OLD[@]} 份 handoff 超出保留窗口"
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo "  ⚠️  跳过 ${#SKIPPED[@]} 个非 handoff 文件（缺 lane/session_id，不归档不删）："
  printf '     %s\n' "${SKIPPED[@]}"
fi

if [[ ${#OLD[@]} -eq 0 ]]; then
  echo "  无需清理。"
  exit 0
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "  [DRY_RUN] 会归档并删除以下 ${#OLD[@]} 份："
  printf '    %s\n' "${OLD[@]}" | head -20
  [[ ${#OLD[@]} -gt 20 ]] && echo "    ... 及另外 $(( ${#OLD[@]} - 20 )) 份"
  exit 0
fi

# ---- 归档 ----
mkdir -p "$ARCHIVE"
STAMP="$(date +%Y%m%dT%H%M%S)"
TARBALL="$ARCHIVE/handoffs-pre${CUTOFF}-${STAMP}.tar.gz"

printf '%s\n' "${OLD[@]}" | tar -czf "$TARBALL" -C "$HANDOFFS" -T -

# ---- 验证：包里的条目数必须等于待删数，否则一个都不删 ----
IN_TAR="$(tar -tzf "$TARBALL" | grep -c '\.md$' || true)"
if [[ "$IN_TAR" -ne "${#OLD[@]}" ]]; then
  echo "  ✗ 归档校验失败：包内 ${IN_TAR} 份 != 待删 ${#OLD[@]} 份。不删任何文件。" >&2
  echo "    残留包：$TARBALL" >&2
  exit 1
fi

SIZE="$(du -h "$TARBALL" | cut -f1)"
echo "  ✓ 已归档 ${IN_TAR} 份 → $TARBALL ($SIZE)"

# ---- 删除（归档已验证）----
for b in "${OLD[@]}"; do
  rm -f "$HANDOFFS/$b"
done
REMAIN="$(find "$HANDOFFS" -maxdepth 1 -name '*.md' -type f | wc -l | tr -d ' ')"
echo "  ✓ 已删除 ${#OLD[@]} 份，目录剩余 ${REMAIN} 份"
