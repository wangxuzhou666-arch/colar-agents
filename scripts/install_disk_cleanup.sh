#!/usr/bin/env bash
# 安装 / 卸载每日磁盘清理的 LaunchAgent（com.colar.disk-cleanup，每天 04:30 跑 scripts/disk_cleanup.sh）。
# 用法：bash install_disk_cleanup.sh [--uninstall]
#
# plist 里写的是**主工作树**的脚本路径（git 公共目录的上一级），不是调用者所在的树：从 worktree 里跑安装，
# 写进去的若是 worktree 路径，树一拆 LaunchAgent 就静默失效（wt-discipline「产物随 worktree 蒸发」同类坑）。
# 机器在 04:30 睡着时，launchd 会在唤醒后补跑一次。docker 走 Docker Desktop 装的 /usr/local/bin。
set -euo pipefail

LABEL=com.colar.disk-cleanup
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "已卸载 $LABEL"
  exit 0
fi

COMMON_DIR="$(git -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir)"
SCRIPT="$(dirname "$COMMON_DIR")/scripts/disk_cleanup.sh"
[ -f "$SCRIPT" ] || { echo "主工作树里没有 ${SCRIPT}（改动还没合进主树？）" >&2; exit 1; }

mkdir -p "$(dirname "$PLIST")" "$HOME/Library/Logs"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$SCRIPT</string></array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>4</integer><key>Minute</key><integer>30</integer></dict>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/colar-disk-cleanup.launchd.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/colar-disk-cleanup.launchd.log</string>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
</dict>
</plist>
PLIST
plutil -lint "$PLIST" >/dev/null
launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "已安装 $LABEL → ${SCRIPT}（每天 04:30；日志 ~/Library/Logs/colar-disk-cleanup.log）"
