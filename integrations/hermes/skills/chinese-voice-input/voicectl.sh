#!/usr/bin/env bash
# chinese-voice-input 的进程管理层：后台启停 / 查状态 / 安静自启。
#
# 这个文件住在 skill 目录（跟 colar-agents 一起进 git），
# `~/.claude-voice-cn/start.sh` 只是 install.sh 生成的一层薄壳，把路径传进来后 exec 到这儿。
# 这样拆是为了：改这里的逻辑不需要重跑 install.sh，重跑 install.sh 也不会冲掉用户的 config.sh。
#
# 本文件只管「怎么起、怎么停、在不在跑」。
# 录音 / 识别 / 打字的逻辑全在 voice_daemon.py，这里一行都不碰。
#
# 用法（都由 start.sh 转发过来）：
#   start.sh                 前台运行，Ctrl+C 退出（排障用，日志直接打在终端）
#   start.sh start           后台启动，有输出
#   start.sh autostart       后台启动，安静版（给 Claude Code SessionStart hook 用）
#   start.sh status          打印运行状态
#   start.sh stop            停掉后台 daemon
#   start.sh restart         stop + start
#   start.sh --probe         按键名探测（透传给 voice_daemon.py，前台）

# 刻意不用 set -e：这个脚本会被 hook 调用，任何一步失败都不该让 session 启动流程见血。
set -uo pipefail

RUN_DIR="${HOME}/.claude-voice-cn"
PID_FILE="${RUN_DIR}/daemon.pid"
LOG_FILE="${RUN_DIR}/daemon.log"
PREV_LOG_FILE="${RUN_DIR}/daemon.log.prev"
READY_FILE="${RUN_DIR}/daemon.ready"
AUDIO_BUSY_FILE="${RUN_DIR}/audio_op.busy"
LOCK_DIR="${RUN_DIR}/.start.lock"
DISABLE_FILE="${RUN_DIR}/autostart.disabled"

# mkdir 启动锁被认定「陈旧」的年龄阈值（秒）。正常的 start_background 流程
# 一秒内就完事（见下方 sleep 0.6 的探活），超过这个阈值还残留，基本可以
# 断定是上次异常强杀（比如 SIGKILL）导致 EXIT trap 没机会跑、rmdir 从未
# 执行，而不是真的有并发的启动流程在跑。不清掉的话 autostart 会永久静默
# 失效——quiet 模式下"抢不到锁就直接放弃"一个字都不打印，用户完全无感知
# （2026-09-01 专家团审核指出）。
STALE_LOCK_SECONDS=30

# 由 start.sh 传入；单独跑本文件时退回默认落点。
VOICE_PYTHON="${VOICE_PYTHON:-${RUN_DIR}/venv/bin/python}"
VOICE_DAEMON_PY="${VOICE_DAEMON_PY:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/voice_daemon.py}"

# voice_daemon.py 就绪后会 touch 这个文件，退出时删掉 —— status 靠它区分
# 「进程活着但还在下/载模型」和「真的在听了」。
export VOICE_READY_FILE="${READY_FILE}"

# voice_daemon.py 在跑开/关流这类可能卡死的原生调用期间会 touch 这个文件，
# 完成后删掉 —— status 靠它的存在时长判断是不是卡在音频操作里，这种「进程
# 活着、也不是在下模型、但按键静默无响应」的半死状态之前完全不可观测
# （2026-09-01 专家团审核指出：新加的 _audio_op_lock 会让卡死从「彻底冻死」
# 变成「静默空等最长 MAX_SECONDS 才放弃」，但没有任何外部信号能看出这一点）。
export VOICE_AUDIO_BUSY_FILE="${AUDIO_BUSY_FILE}"

# ---------------------------------------------------------------- 工具 ----

# 打印存活的 daemon pid（成功返回 0）。pidfile 存在不算数，要进程真活着、
# 且命令行确实是我们的 daemon —— 否则 pid 被系统回收给别的进程时会误判成「在跑」。
running_pid() {
  [[ -f "${PID_FILE}" ]] || return 1
  local pid
  pid="$(cat "${PID_FILE}" 2>/dev/null)"
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  ps -p "${pid}" -o command= 2>/dev/null | grep -q "voice_daemon.py" || return 1
  printf '%s' "${pid}"
}

clear_stale_state() {
  rm -f "${PID_FILE}" "${READY_FILE}"
}

# ------------------------------------------------------------ 后台启动 ----

# start_background <quiet:0|1>
start_background() {
  local quiet="$1" pid

  if pid="$(running_pid)"; then
    [[ "${quiet}" == "1" ]] || echo "已在运行，pid=${pid}（要重启用 restart）"
    return 0
  fi

  # 两个 session 同时开时会同时走到这儿。mkdir 是原子的，抢不到锁的那个直接放弃，
  # 免得拉起两个实例抢麦克风。
  mkdir -p "${RUN_DIR}"
  if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    # 抢不到锁不代表真的有并发——也可能是上次异常强杀留下的残留（见上方
    # STALE_LOCK_SECONDS 的注释）。用 mtime 判断陈旧，陈旧就强制清掉重抢一次。
    local lock_mtime lock_age
    lock_mtime="$(stat -f %m "${LOCK_DIR}" 2>/dev/null || echo 0)"
    lock_age=$(( $(date +%s) - lock_mtime ))
    if (( lock_age > STALE_LOCK_SECONDS )); then
      rmdir "${LOCK_DIR}" 2>/dev/null
      if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
        [[ "${quiet}" == "1" ]] || echo "另一个启动流程正在进行，跳过。"
        return 0
      fi
    else
      [[ "${quiet}" == "1" ]] || echo "另一个启动流程正在进行，跳过。"
      return 0
    fi
  fi
  trap 'rmdir "${LOCK_DIR}" 2>/dev/null' EXIT

  # 拿到锁后再查一次：可能就是刚才那个抢先的把 daemon 拉起来了。
  if pid="$(running_pid)"; then
    [[ "${quiet}" == "1" ]] || echo "已在运行，pid=${pid}"
    return 0
  fi

  if [[ ! -x "${VOICE_PYTHON}" ]]; then
    echo "[chinese-voice-input] 找不到 venv python：${VOICE_PYTHON}（先跑 install.sh）" >&2
    return 1
  fi
  if [[ ! -f "${VOICE_DAEMON_PY}" ]]; then
    echo "[chinese-voice-input] 找不到 daemon 脚本：${VOICE_DAEMON_PY}" >&2
    return 1
  fi

  clear_stale_state
  # 每次启动留一份上一轮的日志再截断 —— 不然日志会无限长，
  # 而且 status 判读时分不清哪几行是这次跑出来的。
  [[ -f "${LOG_FILE}" ]] && mv -f "${LOG_FILE}" "${PREV_LOG_FILE}"

  # cd 到 HOME：daemon 会活得比调用方久，不该攥着某个项目目录不放。
  cd "${HOME}" || return 1
  nohup "${VOICE_PYTHON}" "${VOICE_DAEMON_PY}" >"${LOG_FILE}" 2>&1 &
  pid=$!
  echo "${pid}" >"${PID_FILE}"

  # 只探活一下「有没有立刻炸」（venv 坏了 / import 失败 / 热键名写错这类）。
  # 权限类的静默失效和模型下载都发生在这之后，这里等不到，也不该等 —— 见 SKILL.md Pitfalls。
  sleep 0.6
  if ! kill -0 "${pid}" 2>/dev/null; then
    rm -f "${PID_FILE}"
    local tail_line
    tail_line="$(tail -n 3 "${LOG_FILE}" 2>/dev/null | tr '\n' ' ')"
    echo "[chinese-voice-input] daemon 启动即退出：${tail_line:-无日志}（详见 ${LOG_FILE}）" >&2
    return 1
  fi

  if [[ "${quiet}" != "1" ]]; then
    echo "已在后台启动，pid=${pid}"
    echo "  日志：${LOG_FILE}"
    echo "  首次启动要下模型（约 500MB），下完才会真正开始听 —— 用 status 看进度。"
  fi
  return 0
}

# ---------------------------------------------------------------- 状态 ----

cmd_status() {
  local pid
  if pid="$(running_pid)"; then
    if [[ -f "${READY_FILE}" ]]; then
      echo "运行中 pid=${pid} —— 已就绪，按住热键即可说话"
    else
      echo "运行中 pid=${pid} —— 尚未就绪（在下载 / 载入模型，首次可能几分钟）"
    fi
    echo "  日志：${LOG_FILE}"
    local last
    last="$(tail -n 1 "${LOG_FILE}" 2>/dev/null)"
    [[ -n "${last}" ]] && echo "  最后一行：${last}"
    # 「进程活着、也不在下模型」不等于「按键真的有响应」——如果正卡在开/关流
    # 这类原生调用里，daemon.py 会 touch AUDIO_BUSY_FILE，这里读它的年龄，
    # 别让这种半死状态完全不可见（2026-09-01 专家团审核指出的 mustFix）。
    if [[ -f "${AUDIO_BUSY_FILE}" ]]; then
      local busy_started busy_age
      busy_started="$(cut -d. -f1 <"${AUDIO_BUSY_FILE}" 2>/dev/null)"
      if [[ "${busy_started}" =~ ^[0-9]+$ ]]; then
        busy_age=$(( $(date +%s) - busy_started ))
        if (( busy_age > 3 )); then
          echo "  ⚠️ 音频操作已持续 ${busy_age}s 未完成——正常应是毫秒级，疑似卡在开/关流；最长会自动放弃一次按键，不需要手动 stop"
        fi
      fi
    fi
  else
    if [[ -f "${PID_FILE}" ]]; then
      echo "未运行（清掉了一个残留 pidfile）"
      clear_stale_state
    else
      echo "未运行"
    fi
    [[ -f "${LOG_FILE}" ]] && echo "  上次的日志：${LOG_FILE}"
  fi
  [[ -f "${DISABLE_FILE}" ]] && echo "  注意：自动启动已关闭（存在 ${DISABLE_FILE}）"
  return 0
}

# ---------------------------------------------------------------- 停止 ----

cmd_stop() {
  local pid
  if ! pid="$(running_pid)"; then
    if [[ -f "${PID_FILE}" ]]; then
      echo "未运行（清掉了一个残留 pidfile）"
      clear_stale_state
    else
      echo "未运行"
    fi
    return 0
  fi

  kill -TERM "${pid}" 2>/dev/null
  # daemon 收到 SIGTERM 会把监听关掉再退；模型载入阶段还没装信号处理器，
  # 那时是默认行为直接死，也没问题。
  local i
  for i in $(seq 1 25); do
    kill -0 "${pid}" 2>/dev/null || break
    sleep 0.2
  done
  if kill -0 "${pid}" 2>/dev/null; then
    echo "SIGTERM 5s 没退，改用 SIGKILL。"
    kill -KILL "${pid}" 2>/dev/null
    sleep 0.3
  fi
  clear_stale_state
  echo "已停止（原 pid=${pid}）"
  return 0
}

# ------------------------------------------------------------ 前台运行 ----

run_foreground() {
  local pid
  if pid="$(running_pid)"; then
    echo "后台已经有一个在跑了（pid=${pid}），前台再起一个会跟它抢麦克风。" >&2
    echo "先 \`stop\` 再前台跑，或者直接看 \`status\` / 日志 ${LOG_FILE}。" >&2
    return 1
  fi
  clear_stale_state
  # 前台跑也写 pidfile（2026-08-29 事故修复）：`running_pid` 是唯一的单实例判据，
  # 之前只有后台启动会写它 —— 前台跑着的时候 pidfile 是空的，导致后台 start 那一侧的
  # 单实例检查完全看不到这个前台实例，会再拉起第二个 daemon 一起抢同一个全局热键，
  # 表现为同一句话被两个进程各自录音、各自转录、各自打字，看起来像"结果重复"
  # （实测：2026-08-29 一段 foreground+background 并存的窗口期内确认复现）。
  # `exec` 只替换进程镜像、pid 不变，所以先写 $$ 再 exec 记录的就是最终 python 进程的 pid。
  echo "$$" >"${PID_FILE}"
  exec "${VOICE_PYTHON}" "${VOICE_DAEMON_PY}" "$@"
}

# ---------------------------------------------------------------- 分发 ----

case "${1:-}" in
  "" | --foreground | foreground)
    run_foreground
    ;;
  start | --daemon)
    start_background 0
    ;;
  autostart | --daemon-quiet)
    # 给 Claude Code 的 SessionStart hook 用：正常情况下**一个字都不往 stdout 打**
    # （hook 的 stdout 会被塞进 session 的系统提示里），只有真炸了才往 stderr 打一行。
    # 无论如何都 exit 0 —— 语音输入没起来不该影响开 session。
    if [[ -f "${DISABLE_FILE}" || "${VOICE_AUTOSTART:-1}" == "0" ]]; then
      exit 0
    fi
    start_background 1
    exit 0
    ;;
  status)
    cmd_status
    ;;
  stop)
    cmd_stop
    ;;
  restart)
    cmd_stop >/dev/null
    start_background 0
    ;;
  --probe)
    # 探测模式不开麦克风，跟后台 daemon 并存无害（两个监听器互不影响），
    # 所以刻意绕开「已在运行就拒绝」的那道闸——不然查个键名还得先把 daemon 停了。
    exec "${VOICE_PYTHON}" "${VOICE_DAEMON_PY}" --probe
    ;;
  *)
    # daemon 自己的其它参数，原样透传，前台跑。
    run_foreground "$@"
    ;;
esac
