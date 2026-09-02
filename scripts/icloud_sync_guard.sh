#!/usr/bin/env bash
# iCloud 同步守卫 —— 扫 ~/Desktop 与 ~/Documents 下所有「构建产物 / 依赖目录」，
# 把还在 iCloud 同步域里的批量标记为不同步。advisory：没发现漂移就完全静默。
#
# 为什么需要它：开着「桌面与文稿」同步时，这两个目录下的一切都会被 iCloud 逐份上传并在
# 本地保留完整副本（等于每个大文件占双份）。而 isExcludedFromSync 是「目录自身的属性，
# 不随重建继承」——每次 rm -rf .next、npm ci 重建 node_modules，排除属性就跟着没了，
# 目录悄悄掉回同步域。2026-09-01 实测过这条：删掉 .next 后属性确实丢失。
#
# 为什么是全局巡检而不是逐项目挂 postinstall / check_all.sh：
#   · postinstall 只在 npm i 后触发，完全不覆盖 .next（.next 是 dev/build 时建的）
#   · check_all.sh 在 commit 前才跑，那时 .next 已经在同步域里躺了几小时
#   · 两者都要写进 package.json，会跟着 git 走到别人机器上——而这是本机开着 iCloud 才有的问题
#   · ~/Desktop 下有 7 个项目都有同样问题，逐项目配置是 7 份重复，还漏掉以后新建的
#
# 用法：
#   bash icloud_sync_guard.sh            # 修复漂移（有发现才输出）
#   bash icloud_sync_guard.sh --dry-run  # 只报告，不改
set -uo pipefail

BIN="$HOME/.local/bin/icloud-exclude"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

[ -x "$BIN" ] || { echo "[icloud-guard] 缺少 $BIN（用 swiftc -O 从 colar-agents/scripts/icloud_exclude.swift 编译）" >&2; exit 1; }

# 只收「可重建的构建产物 / 依赖目录」。刻意不含 dist/ 与 build/——那两个名字在有些项目里
# 是源码或需要留存的产物，误排除会让它们失去 iCloud 备份而无声无息。
NAMES=(node_modules .next __pycache__ .venv .turbo .pytest_cache .mypy_cache .ruff_cache)

expr_args=()
for i in "${!NAMES[@]}"; do
  [ "$i" -gt 0 ] && expr_args+=(-o)
  expr_args+=(-name "${NAMES[$i]}")
done

targets=()
for root in "$HOME/Desktop" "$HOME/Documents"; do
  [ -d "$root" ] || continue
  # -prune：命中即不再深入（node_modules 里往往还嵌着 node_modules），既提速又避免重复设置
  while IFS= read -r d; do
    [ -n "$d" ] && targets+=("$d")
  done < <(find "$root" -type d \( "${expr_args[@]}" \) -prune -print 2>/dev/null)
done

[ "${#targets[@]}" -eq 0 ] && exit 0

if [ "$DRY" = "1" ]; then
  pending=$("$BIN" --status "${targets[@]}" 2>/dev/null | grep -c "^同步中" || true)
  echo "[icloud-guard] 扫到 ${#targets[@]} 个目录，其中 ${pending:-0} 个仍在同步域"
  "$BIN" --status "${targets[@]}" 2>/dev/null | grep "^同步中" || true
  exit 0
fi

# 二进制对「原本已排除」的静默，所以这里的输出天然等于本次新修复的条目
out=$("$BIN" "${targets[@]}" 2>/dev/null)
if [ -n "$out" ]; then
  n=$(printf '%s\n' "$out" | grep -c "已排除" || true)
  echo "[icloud-guard] 修复 ${n} 个掉回 iCloud 同步域的目录（共扫 ${#targets[@]} 个）:"
  printf '%s\n' "$out" | sed 's/^/  /'
fi
