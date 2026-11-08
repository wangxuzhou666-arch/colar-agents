#!/usr/bin/env bash
# 每日磁盘清理（LaunchAgent com.colar.disk-cleanup 每天 04:30 跑；安装见 scripts/install_disk_cleanup.sh）。
#
# 为什么（2026-11-07 19:58 磁盘写满，Colar 2026-11-08 拍板「自动清 + 每天跑」）：
#   各会话把 TMPDIR 设到 ~/artifacts/<任务>/tmp，pytest 在每个目录各留最近 3 轮，没人清就一直攒——27 处共约 49G，
#   几天就攒出来，所以按天清、不按周。Docker 构建缓存同样只涨不降（当时 17.7G）。
#
# 清什么（只有这两样，别的一律不碰）：
#   1. ~/artifacts/*/tmp/ 下 CLEAN_AGE_DAYS（默认 2）天内没有任何文件被改过的条目。pytest-of-* 往下看一层，按每一轮
#      pytest-N 单独判（正在跑的那一轮有新文件，不会被删）；失效的 pytest-current 链接一并清。
#      「没改过」看条目里**所有**文件的 mtime，不只看目录本身：目录的 mtime 只随直接子项增删变，深处在写它不变。
#   2. Docker 开着时：docker builder prune -f --reserved-space 5gb（不带 -a，保留 5G cache；bash_pitfall_guard 规则 8
#      给的安全替代——本机有钉死 digest、无法复原的本地镜像，镜像一律不碰）。Docker 没开不启动它。
# 不碰：~/.wt 工作树（拆树要过 wt rm 的门：脏树 / 游离提交 / 不可再生文件）、~/artifacts 里 tmp 以外的产物、镜像。
#
# 用法：bash disk_cleanup.sh [--dry-run]   环境：ARTIFACTS_ROOT（默认 ~/artifacts）· CLEAN_AGE_DAYS（2）·
#       DISK_CLEANUP_LOG（默认 ~/Library/Logs/colar-disk-cleanup.log）· DISK_CLEANUP_DOCKER=0 跳过 Docker
# 自证测试：bash scripts/hooks/tests/test_disk_cleanup.sh
set -u

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1
ROOT="${ARTIFACTS_ROOT:-$HOME/artifacts}"
AGE_DAYS="${CLEAN_AGE_DAYS:-2}"
LOG="${DISK_CLEANUP_LOG:-$HOME/Library/Logs/colar-disk-cleanup.log}"
case "$AGE_DAYS" in ''|*[!0-9]*) echo "disk-cleanup: CLEAN_AGE_DAYS=$AGE_DAYS 不是非负整数" >&2; exit 1 ;; esac
# 「最近」= 过去 AGE_DAYS 天到未来 1 天这个窗口。不能用 find -mmin -N：它把未来时间也算「最近」，而有的测试会把文件
# mtime 改到未来（2026-11-08 实测：织锦 test_gc_default_report_* 把 fabric_images 改到 2033 年，整个 7.2G 的 basetemp 永远清不掉）。
since=$(date -v-"${AGE_DAYS}"d '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "-${AGE_DAYS} days" '+%Y-%m-%d %H:%M:%S')
until=$(date -v+1d '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d '+1 day' '+%Y-%m-%d %H:%M:%S')
mkdir -p "$(dirname "$LOG")"

removed=0
removed_kb=0
free_gb() { df -Pk "$HOME" | awk 'NR==2 {printf "%d", $4 / 1048576}'; }
before_gb=$(free_gb)

is_stale() {  # is_stale <路径>：条目里（含自身）没有任何东西的 mtime 落在「最近」窗口里
  [ -z "$(find "$1" -newermt "$since" ! -newermt "$until" -print 2>/dev/null | head -n 1)" ]
}

drop() {  # drop <路径>：只删 $ROOT/<任务>/tmp/ 之下的东西，路径不对就拒绝（变量被写坏时不能被引到别处）
  case "$1" in
    "$ROOT"/*/tmp/?*) ;;
    *) echo "disk-cleanup: 拒绝删除 tmp 之外的路径：$1" >&2; return 1 ;;
  esac
  local kb
  kb=$(du -sk "$1" 2>/dev/null | awk '{print $1}')
  if [ "$DRY_RUN" = 1 ]; then
    echo "  [dry-run] 会删 $1（${kb:-0}KB）"
  else
    rm -rf "$1"
  fi
  removed=$((removed + 1))
  removed_kb=$((removed_kb + ${kb:-0}))
}

for tmp in "$ROOT"/*/tmp; do
  [ -d "$tmp" ] && [ ! -L "$tmp" ] || continue
  for entry in "$tmp"/* "$tmp"/.[!.]*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    case "$(basename "$entry")" in
      pytest-of-*)
        [ -d "$entry" ] && [ ! -L "$entry" ] || { is_stale "$entry" && drop "$entry"; continue; }
        for run in "$entry"/*; do
          if [ -L "$run" ]; then
            [ -e "$run" ] || drop "$run"          # 失效的 pytest-current
          elif [ -e "$run" ] && is_stale "$run"; then
            drop "$run"
          fi
        done ;;
      *)
        is_stale "$entry" && drop "$entry" ;;
    esac
  done
done

docker_note="Docker 未开，跳过"
if [ "${DISK_CLEANUP_DOCKER:-1}" = 1 ] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if [ "$DRY_RUN" = 1 ]; then
    docker_note="[dry-run] 会跑 docker builder prune -f --reserved-space 5gb"
  else
    docker_note="builder prune：$(docker builder prune -f --reserved-space 5gb 2>&1 | tail -n 1)"
  fi
fi

after_gb=$(free_gb)
summary="$(date '+%Y-%m-%d %H:%M:%S') 删 ${removed} 项 ≈ $((removed_kb / 1048576))G（${ROOT}/*/tmp，${AGE_DAYS} 天未动）；${docker_note}；磁盘剩 ${before_gb}G → ${after_gb}G"
[ "$DRY_RUN" = 1 ] && summary="[dry-run] $summary"
echo "$summary"
echo "$summary" >> "$LOG"
