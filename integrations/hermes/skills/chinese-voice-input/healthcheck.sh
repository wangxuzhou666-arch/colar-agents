#!/usr/bin/env bash
# 定时健康检查 —— 不是排障工具，是兜底。
#
# 2026-08-28 一天内实测过三种不同性质的卡死/失效（丢松开信号、关闭音频流卡死、
# 睡眠唤醒后设备表失效），每种都单独打了补丁，但没法保证以后不会再冒出第四种。
# 与其继续见招拆招，加一道更粗暴但更可靠的兜底：daemon 运行超过阈值就主动重启一次，
# 用「定期重开」换稳定性，不指望单个长时间存活的进程能扛住所有系统级异常。
#
# 由 launchd 定时调用（同目录 com.colar.voice-cn-healthcheck.plist），不是给人手动跑的，
# 但手动跑也无害——没到阈值 / daemon 没在跑 / 正在录音转录中，都会直接跳过。

set -uo pipefail

RUN_DIR="${HOME}/.claude-voice-cn"
PID_FILE="${RUN_DIR}/daemon.pid"
LOG_FILE="${RUN_DIR}/daemon.log"
CONFIG_FILE="${RUN_DIR}/config.sh"
START_SH="${RUN_DIR}/start.sh"

# shellcheck disable=SC1090
[[ -f "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}"
MAX_UPTIME_HOURS="${VOICE_MAX_UPTIME_HOURS:-2}"

# 没在跑就不归这脚本管——那是 SessionStart autostart 的事，健康检查只重启，不负责拉起。
[[ -f "${PID_FILE}" ]] || exit 0
pid="$(cat "${PID_FILE}" 2>/dev/null)"
[[ "${pid}" =~ ^[0-9]+$ ]] || exit 0
kill -0 "${pid}" 2>/dev/null || exit 0

# 用 pidfile 自身的 mtime 当「这一轮 daemon 是什么时候起的」——
# 每次启动都会重写这个文件，比解析 `ps -o etime` 简单可靠（etime 的格式随运行时长在变）。
pid_file_epoch=$(stat -f %m "${PID_FILE}" 2>/dev/null) || exit 0
now_epoch=$(date +%s)
uptime_hours=$(( (now_epoch - pid_file_epoch) / 3600 ))

(( uptime_hours < MAX_UPTIME_HOURS )) && exit 0

# 日志最近 30 秒内有更新，说明可能正在录音/转录，这轮先跳过，等下一轮健康检查再判断，
# 免得重启打断一次正在进行的识别。
if [[ -f "${LOG_FILE}" ]]; then
  log_epoch=$(stat -f %m "${LOG_FILE}" 2>/dev/null) || log_epoch=0
  if (( now_epoch - log_epoch < 30 )); then
    exit 0
  fi
fi

echo "[voice-healthcheck $(date '+%H:%M:%S')] 已运行 ${uptime_hours}h ≥ 阈值 ${MAX_UPTIME_HOURS}h，主动重启一次（预防性，非故障触发）。" >>"${LOG_FILE}" 2>&1
exec bash "${START_SH}" restart >>"${LOG_FILE}" 2>&1
