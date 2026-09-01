#!/usr/bin/env bash
# 定时健康检查 —— 不是排障工具，是兜底。
#
# 2026-08-28 一天内实测过三种不同性质的卡死/失效（丢松开信号、关闭音频流卡死、
# 睡眠唤醒后设备表失效），每种都单独打了补丁，但没法保证以后不会再冒出第四种。
# 与其继续见招拆招，加一道更粗暴但更可靠的兜底：daemon 运行超过阈值就主动重启一次，
# 用「定期重开」换稳定性，不指望单个长时间存活的进程能扛住所有系统级异常。
#
# 2026-09-01 补第二条触发路径：故障态检测。上面那条是**预防性**的（只看 uptime），
# 探不到「没跑满阈值就卡死」的情况 —— 当天 CoreAudio 三个调用全部超时 10s、daemon
# 进程还活着且 status 仍报「已就绪」，healthcheck 因未满 2h 直接跳过，全程没兜住。
# 所以加一条：读 daemon.log 判断当前是否处于故障态，是就立刻重启，不等阈值。
#
# 由 launchd 定时调用（同目录 com.colar.voice-cn-healthcheck.plist），不是给人手动跑的，
# 但手动跑也无害——没到阈值 / 无故障 / daemon 没在跑 / 正在录音转录中，都会直接跳过。

set -uo pipefail

RUN_DIR="${HOME}/.claude-voice-cn"
PID_FILE="${RUN_DIR}/daemon.pid"
LOG_FILE="${RUN_DIR}/daemon.log"
CONFIG_FILE="${RUN_DIR}/config.sh"
START_SH="${RUN_DIR}/start.sh"
FAULT_STAMP="${RUN_DIR}/healthcheck.last_fault_restart"

# shellcheck disable=SC1090
[[ -f "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}"
MAX_UPTIME_HOURS="${VOICE_MAX_UPTIME_HOURS:-2}"
# 故障重启的冷却窗口：权限缺失这类 restart 修不好的病，会让故障态一直成立，
# 没有冷却就变成每 30 分钟无效重启一次。冷却期内只在日志里提醒，不再动手。
FAULT_COOLDOWN_SECONDS="${VOICE_FAULT_COOLDOWN_SECONDS:-3600}"

# 没在跑就不归这脚本管——那是 SessionStart autostart 的事，健康检查只重启，不负责拉起。
[[ -f "${PID_FILE}" ]] || exit 0
pid="$(cat "${PID_FILE}" 2>/dev/null)"
[[ "${pid}" =~ ^[0-9]+$ ]] || exit 0
kill -0 "${pid}" 2>/dev/null || exit 0

now_epoch=$(date +%s)

do_restart() {
  echo "[voice-healthcheck $(date '+%H:%M:%S')] $1" >>"${LOG_FILE}" 2>&1
  exec bash "${START_SH}" restart >>"${LOG_FILE}" 2>&1
}

# ── 触发路径一：故障态检测（不等 uptime 阈值）────────────────────────────────
# 判据是**行序**而不是时间戳：daemon.log 的行只有 HH:MM:SS、没有日期，跨天比时间会翻车。
# 在最近一段日志里，若「最后一条故障行」出现在「最后一条成功识别行」之后，
# 就认为此刻处于故障态。restart 会截断 daemon.log（上一轮进 .prev），新日志里没有故障行，
# 所以修好之后不会反复触发。
if [[ -f "${LOG_FILE}" ]]; then
  tail_log="$(tail -n 200 "${LOG_FILE}" 2>/dev/null)"

  # 正在录音就别打断，等下一轮（30 分钟后）再判。
  if [[ "$(printf '%s\n' "${tail_log}" | tail -n 1)" == *"录音中"* ]]; then
    exit 0
  fi

  last_fault=$(printf '%s\n' "${tail_log}" | grep -nE '判定卡死|麦克风打开失败|打开音频流失败' | tail -n 1 | cut -d: -f1)
  last_ok=$(printf '%s\n' "${tail_log}" | grep -nE '识别（|就绪。按住' | tail -n 1 | cut -d: -f1)
  last_fault="${last_fault:-0}"
  last_ok="${last_ok:-0}"

  if (( last_fault > 0 && last_fault > last_ok )); then
    last_fault_restart=0
    [[ -f "${FAULT_STAMP}" ]] && last_fault_restart=$(stat -f %m "${FAULT_STAMP}" 2>/dev/null || echo 0)
    if (( now_epoch - last_fault_restart < FAULT_COOLDOWN_SECONDS )); then
      echo "[voice-healthcheck $(date '+%H:%M:%S')] 检测到故障态，但距上次故障重启不足 ${FAULT_COOLDOWN_SECONDS}s，本轮跳过。重启修不好的故障多半是权限问题，见 SKILL.md 的 Pitfalls 表。" >>"${LOG_FILE}" 2>&1
      exit 0
    fi
    touch "${FAULT_STAMP}"
    do_restart "检测到音频故障态（日志末尾故障行晚于最后一次成功识别），立刻重启。"
  fi
fi

# ── 触发路径二：预防性重启（原有逻辑）──────────────────────────────────────
# 用 pidfile 自身的 mtime 当「这一轮 daemon 是什么时候起的」——
# 每次启动都会重写这个文件，比解析 `ps -o etime` 简单可靠（etime 的格式随运行时长在变）。
pid_file_epoch=$(stat -f %m "${PID_FILE}" 2>/dev/null) || exit 0
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

do_restart "已运行 ${uptime_hours}h ≥ 阈值 ${MAX_UPTIME_HOURS}h，主动重启一次（预防性，非故障触发）。"
