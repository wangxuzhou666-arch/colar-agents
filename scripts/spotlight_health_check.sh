#!/usr/bin/env bash
# Spotlight 索引死锁检测 — 判断 mds_stores 是「正在健康重建」还是「卡死空转」，
# 卡死时弹 macOS 通知给出修复命令。只检测不修复（修复需 sudo，刻意不自动化）。
#
# 背景（为什么存在）：
#   2026-08-15 发现 mds_stores 已 100% CPU 空转 21 天（累计 187 小时 CPU 时间），
#   活动监视器里「聚焦」能耗影响 4365.0。根因是索引库损坏导致状态机死锁：
#   /System/Volumes/Data 长期卡在 kMDConfigSearchLevelTransitioning，mdutil 任何
#   状态切换请求都被超时拒绝（15 次重试全挂）。而 macOS 自身**没有任何告警** ——
#   电池狂掉、风扇狂转，但除非手动翻活动监视器 + 看懂 mds_stores 是什么，否则
#   可以烧几个月都没人发现。本脚本就是补上这个缺失的告警。
#
# 用法：
#   bash spotlight_health_check.sh              # 人读报告
#   bash spotlight_health_check.sh --brief      # 只输出 VERDICT= 行（供 hook / launchd 消费）
#   bash spotlight_health_check.sh --notify     # 异常时弹 macOS 通知（launchd 定时任务用这个）
#   FAKE_STUCK=1 bash spotlight_health_check.sh --notify   # 注入假死锁，验证告警路径
#
# 输出契约：
#   第一行永远是 `VERDICT=<OK|STUCK|TRANSITIONING|DISABLED|UNKNOWN> conf=<high|low>`。
#   --brief 只打这一行。Exit：永远 0（advisory，绝不 block 调用方）。
#
# 检测原理（关键判据来自 2026-08-15 实战诊断）：
#   核心判据是 mdworker 有无，不是 mds_stores 的 CPU 高低：
#     死锁 21 天期间：mds_stores 独自 99.7% 空转，mdworker_shared **一个都没有**
#                     （它根本没在读文件，是在自己的索引库里绕圈）。
#     健康重建期间：  mds_stores CPU 反而不高（4.5%），但几十个 mdworker_shared
#                     在成批生灭（扫一段 → 退出 → launchd 起新的）。
#     所以「CPU 高」单独不能判死锁 —— 重建期 CPU 本来就该高。真正的判据是
#     「CPU 高 **且** 没有 worker 在干活」。多次采样避免撞上 worker 的空档。
#
#   次要判据：mdutil -as 报 Transitioning / unexpected indexing state → 状态机已卡。
#            这条是硬信号，单独出现即告警（正常状态切换只持续几秒）。
#
# 阈值（可用环境变量覆盖）：
#   CPU_THRESHOLD=50   mds_stores 超过此 %CPU 才可能被判死锁
#   SAMPLES=3          采样次数（全部命中才判定，防单次误判）
#   SAMPLE_INTERVAL=10 采样间隔秒数
#
# 平台：macOS（ps BSD 语法 / mdutil / osascript）。零 sudo —— mdutil -as 读状态不需要提权。
# 局限：见文件尾 "LIMITATIONS"。

set -u

CPU_THRESHOLD="${CPU_THRESHOLD:-50}"
SAMPLES="${SAMPLES:-3}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-10}"
FAKE_STUCK="${FAKE_STUCK:-0}"

BRIEF=0
NOTIFY=0
for arg in "$@"; do
  case "$arg" in
    --brief)  BRIEF=1 ;;
    --notify) NOTIFY=1 ;;
  esac
done

MD_SUPPORT="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/Metadata.framework/Versions/A/Support"
LOG_FILE="${HOME}/Library/Logs/spotlight_health_check.log"

# ---------- 采集 ----------

# mds_stores 的 pid / %CPU / 累计 CPU 时间。可能不存在（返回空）。
read_mds_stores() {
  ps -Ao pid,pcpu,time,comm | awk -v p="${MD_SUPPORT}/mds_stores" '$4 == p {print $1, $2, $3; exit}'
}

# 当前活着的 mdworker 数量（mdworker_shared / mdworker 都算）
count_workers() {
  ps -Ao comm | grep -cE "${MD_SUPPORT}/mdworker" || true
}

# mdutil 状态（不需要 sudo）
INDEX_STATUS="$(mdutil -as 2>&1)"

# ---------- 判定 ----------

VERDICT="UNKNOWN"
CONF="low"
DETAIL=""

if printf '%s' "$INDEX_STATUS" | grep -qE 'Transitioning|unexpected indexing state'; then
  VERDICT="TRANSITIONING"
  CONF="high"
  DETAIL="索引状态机卡在 Transitioning —— mdutil 已无法切换状态。这正是 2026-08-15 那次死锁的特征。"
elif printf '%s' "$INDEX_STATUS" | grep -q 'Indexing disabled'; then
  VERDICT="DISABLED"
  CONF="high"
  DETAIL="有卷的索引处于关闭状态（可能是上次修复中断留下的）。"
fi

# 即使状态正常，也要查死锁（死锁初期状态可能还没变成 Transitioning）
STORES_INFO="$(read_mds_stores)"
STORES_PID=""; STORES_CPU="0"; STORES_TIME="-"

if [ -n "$STORES_INFO" ]; then
  STORES_PID="$(printf '%s' "$STORES_INFO" | awk '{print $1}')"
  STORES_CPU="$(printf '%s' "$STORES_INFO" | awk '{print $2}')"
  STORES_TIME="$(printf '%s' "$STORES_INFO" | awk '{print $3}')"
fi

# FAKE_STUCK：注入假死锁数据，用于验证告警路径真能触发
if [ "$FAKE_STUCK" = "1" ]; then
  STORES_PID="99999"; STORES_CPU="99.9"; STORES_TIME="11206:34.09"
fi

# 多次采样：CPU 持续超阈值 且 全程无 worker → 死锁
if [ "$VERDICT" != "TRANSITIONING" ] && [ -n "$STORES_PID" ]; then
  hot_and_idle=0
  peak_cpu="$STORES_CPU"

  for i in $(seq 1 "$SAMPLES"); do
    if [ "$FAKE_STUCK" = "1" ]; then
      cpu="99.9"; workers=0
    else
      info="$(read_mds_stores)"
      [ -z "$info" ] && break
      cpu="$(printf '%s' "$info" | awk '{print $2}')"
      workers="$(count_workers)"
    fi

    # awk 做浮点比较（bash 只能整数）
    if awk -v c="$cpu" -v t="$CPU_THRESHOLD" 'BEGIN{exit !(c > t)}' && [ "$workers" -eq 0 ]; then
      hot_and_idle=$((hot_and_idle + 1))
    fi
    awk -v c="$cpu" -v p="$peak_cpu" 'BEGIN{exit !(c > p)}' && peak_cpu="$cpu"

    [ "$i" -lt "$SAMPLES" ] && [ "$FAKE_STUCK" != "1" ] && sleep "$SAMPLE_INTERVAL"
  done

  if [ "$hot_and_idle" -eq "$SAMPLES" ]; then
    VERDICT="STUCK"
    CONF="high"
    DETAIL="mds_stores (PID ${STORES_PID}) 持续 ${peak_cpu}% CPU 但 ${SAMPLES} 次采样全程没有任何 mdworker 在工作 —— 它没在读文件，是在空转。累计 CPU 时间 ${STORES_TIME}。"
  elif [ "$VERDICT" = "UNKNOWN" ]; then
    VERDICT="OK"
    CONF="high"
    DETAIL="mds_stores ${STORES_CPU}% CPU，有 worker 在正常生灭（或 CPU 已回落）。"
  fi
elif [ "$VERDICT" = "UNKNOWN" ] && [ -z "$STORES_PID" ]; then
  VERDICT="OK"
  CONF="high"
  DETAIL="mds_stores 未运行 —— 索引空闲，无异常。"
fi

# ---------- 输出 ----------

echo "VERDICT=${VERDICT} conf=${CONF}"
[ "$BRIEF" = "1" ] && exit 0

FIX_CMD='sudo killall -9 mds_stores; sleep 5; sudo mdutil -a -i off; sudo mdutil -X /System/Volumes/Data; sudo mdutil -a -i on'

if [ "$BRIEF" != "1" ]; then
  echo
  echo "$DETAIL"
  echo
  echo "--- mds_stores ---"
  if [ "$FAKE_STUCK" = "1" ]; then
    echo "  [FAKE_STUCK=1 测试模式] mds_stores 数据是注入的假值，下面的 worker 数是真实值，两者不一致属预期"
  fi
  if [ -n "$STORES_PID" ]; then
    echo "  PID ${STORES_PID}  CPU ${STORES_CPU}%  累计 CPU 时间 ${STORES_TIME}"
  else
    echo "  未运行"
  fi
  echo "  当前 mdworker 数量: $(count_workers)"
  echo
  echo "--- mdutil -as ---"
  printf '%s\n' "$INDEX_STATUS" | sed 's/^/  /'

  if [ "$VERDICT" = "STUCK" ] || [ "$VERDICT" = "TRANSITIONING" ] || [ "$VERDICT" = "DISABLED" ]; then
    echo
    echo "--- 修复（需要 sudo，自己跑）---"
    echo "  ${FIX_CMD}"
    echo
    echo "  注意：修复后新的 mds_stores 会高 CPU 重建索引 1-3 小时，那是正常的。"
    echo "  别用 rm 删 .Spotlight-V100 —— SIP 开启时会 Operation not permitted，用 mdutil -X。"
  fi
fi

# ---------- 通知 + 日志 ----------

if [ "$VERDICT" != "OK" ]; then
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  {
    echo "[${ts}] VERDICT=${VERDICT} conf=${CONF}"
    echo "  ${DETAIL}"
    echo "  fix: ${FIX_CMD}"
  } >> "$LOG_FILE" 2>/dev/null

  if [ "$NOTIFY" = "1" ]; then
    case "$VERDICT" in
      STUCK)         msg="mds_stores 在空转烧 CPU，并没有在建索引。修复命令见日志。" ;;
      TRANSITIONING) msg="索引状态机卡在 Transitioning，mdutil 已失效。需手动修复。" ;;
      DISABLED)      msg="索引处于关闭状态，可能是上次修复中断留下的。" ;;
      *)             msg="检测结果 ${VERDICT}，详见日志。" ;;
    esac
    osascript -e "display notification \"${msg}\" with title \"Spotlight 索引异常\" subtitle \"日志: ~/Library/Logs/spotlight_health_check.log\" sound name \"Basso\"" >/dev/null 2>&1
  fi
fi

exit 0

# LIMITATIONS
#   1. 只检测不修复 —— 修复需 sudo，刻意不做全自动（Colar 2026-08-15 拍板：不给 killall/mdutil
#      开 NOPASSWD，避免为了这个功能凿一个无密码提权口子；且重建会突然吃 1-3 小时 CPU，
#      不应该在人正干活时被后台任务擅自触发）。
#   2. worker 判据在「索引已完成、系统完全空闲」时也会是 0 worker，但那时 mds_stores CPU
#      也接近 0，被 CPU_THRESHOLD 挡掉，不会误报。
#   3. 单次运行耗时约 SAMPLES × SAMPLE_INTERVAL 秒（默认 20 秒），不适合放进同步 hook 路径。
#   4. 无法读取 .Spotlight-V100 内部（SIP + TCC 保护，即使 sudo 也 Operation not permitted），
#      所以无法用「索引库大小是否增长」作为佐证信号 —— 这也是为什么 worker 判据是主判据。
