#!/usr/bin/env bash
# UserPromptSubmit：磁盘水位提醒。家目录所在卷剩余 < DISK_WARN_GB（默认 40）时往上下文里注入一行；够就一个字都不输出。
#
# 为什么（2026-11-07 19:58 磁盘写满，Colar 2026-11-08 拍板）：盘是几天里慢慢攒满的（pytest 临时目录、工作树里的种子库、
#   Docker 缓存），没人看水位，直到部署门报假红、Docker 引擎崩掉才发现。macOS 的 swap 与数据卷共用一个 APFS 容器，
#   内存吃紧时 swap 涨也在吃盘——所以 40G 起就提醒，留出 swap 涨上去的余量。
# 低于 DISK_BLOCK_GB（默认 20，与 heavy_slot.py 的 HEAVY_MIN_DISK_GB、wt new 的 WT_MIN_DISK_GB 一致）时，
#   全量门 / 覆盖率 / 新建工作树已经会被拒绝，提醒里说清楚，免得会话以为是别的原因。
# 自证测试：bash scripts/hooks/tests/test_disk_watermark.sh（DISK_WATERMARK_FAKE_GB 注入剩余 GB）。
# 脚本自身异常一律静默退出 0，不阻断用户输入。

warn_gb="${DISK_WARN_GB:-40}"
block_gb="${DISK_BLOCK_GB:-20}"
if [ -n "${DISK_WATERMARK_FAKE_GB:-}" ]; then
  free_gb="$DISK_WATERMARK_FAKE_GB"
else
  free_gb=$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {printf "%d", $4 / 1048576}')
fi
case "$free_gb" in ''|*[!0-9]*) exit 0 ;; esac
[ "$free_gb" -ge "$warn_gb" ] && exit 0

hint="能清什么：bash \$HOME/Desktop/colar-agents/scripts/disk_cleanup.sh --dry-run；不用的工作树 wt rm / wt park；du -sh ~/.wt/* ~/artifacts/* | sort -h | tail"
if [ "$free_gb" -lt "$block_gb" ]; then
  echo "[disk-watermark::hook-only] ⛔ 磁盘只剩 ${free_gb}G（低于 ${block_gb}G）：全量门 / 覆盖率 / 新建工作树此刻会被拒绝。先腾空间，别起新的重任务。${hint}"
else
  echo "[disk-watermark::hook-only] ⚠ 磁盘只剩 ${free_gb}G（低于 ${warn_gb}G 提醒线，${block_gb}G 起会拒绝全量门和新建工作树）。${hint}"
fi
exit 0
