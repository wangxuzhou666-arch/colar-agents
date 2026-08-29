#!/usr/bin/env bash
# chinese-voice-input 依赖安装。
# 只装东西，不跑 daemon、不碰系统权限设置 —— 那两件必须 Colar 手动做。
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="${HOME}"
VENV_DIR="${HOME_DIR}/.claude-voice-cn/venv"
PYTHON_BIN="${PYTHON_BIN:-/Library/Frameworks/Python.framework/Versions/3.12/bin/python3}"

echo "==> chinese-voice-input 安装"
echo "    skill 目录 : ${SKILL_DIR}"
echo "    venv 目标  : ${VENV_DIR}"
echo

# --- 1. 环境前置检查 -------------------------------------------------------
echo "[1/5] 检查环境"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "  FAIL 这个 skill 只支持 macOS。" >&2
  exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "  FAIL mlx-whisper 需要 Apple Silicon（当前 $(uname -m)）。" >&2
  exit 1
fi
if [[ ! -x "${PYTHON_BIN}" ]]; then
  echo "  FAIL 找不到 Python：${PYTHON_BIN}" >&2
  echo "    用 PYTHON_BIN=/path/to/python3 bash install.sh 指定。" >&2
  exit 1
fi
echo "  ok   macOS / arm64 / $(${PYTHON_BIN} --version)"
echo

# --- 2. ffmpeg -------------------------------------------------------------
# daemon 本身把音频以 numpy 数组直接喂给 whisper，不走 ffmpeg；
# 但 whisper 的音频加载路径在处理文件时会调它，装上省得以后踩。
echo "[2/5] 检查 ffmpeg"
if command -v ffmpeg >/dev/null 2>&1; then
  echo "  ok   已安装：$(command -v ffmpeg)"
else
  if ! command -v brew >/dev/null 2>&1; then
    echo "  FAIL ffmpeg 和 Homebrew 都没有。先装 Homebrew 再重跑。" >&2
    exit 1
  fi
  echo "  ...  未安装，现在执行 brew install ffmpeg（几分钟，会下载依赖）"
  brew install ffmpeg
  echo "  ok   ffmpeg 安装完成"
fi
echo

# --- 3. venv ---------------------------------------------------------------
echo "[3/5] 创建 venv"
if [[ -d "${VENV_DIR}" ]]; then
  echo "  ok   已存在，复用：${VENV_DIR}"
else
  mkdir -p "$(dirname "${VENV_DIR}")"
  "${PYTHON_BIN}" -m venv "${VENV_DIR}"
  echo "  ok   已创建：${VENV_DIR}"
fi
"${VENV_DIR}/bin/python" -m pip install --quiet --upgrade pip
echo

# --- 4. 依赖 ---------------------------------------------------------------
echo "[4/5] 安装 Python 依赖：mlx-whisper / pynput / sounddevice / numpy"
echo "      （首次会拉 mlx 及其依赖，约 1-3 分钟；这一步只下代码，不下模型权重）"
"${VENV_DIR}/bin/python" -m pip install mlx-whisper pynput sounddevice numpy
echo "  ok   依赖装好"
echo

# --- 5. 启动脚本 -----------------------------------------------------------
# start.sh 是**每次重装都重新生成**的薄壳，真正的起停逻辑在 skill 目录的 voicectl.sh；
# 用户改热键/模型写在 config.sh 里，那个文件**只在不存在时创建**，重装不会冲掉。
echo "[5/5] 生成启动脚本"
LAUNCHER="${HOME_DIR}/.claude-voice-cn/start.sh"
CONFIG="${HOME_DIR}/.claude-voice-cn/config.sh"

if [[ -f "${CONFIG}" ]]; then
  echo "  ok   配置已存在，保留不动：${CONFIG}"
else
  cat > "${CONFIG}" <<'EOF'
#!/usr/bin/env bash
# chinese-voice-input 用户配置。这个文件重装 install.sh 不会被覆盖，放心改。
# 取消注释并改值即可，改完 `bash ~/.claude-voice-cn/start.sh restart` 生效。

# 热键（pynput 键名；不知道叫啥就 `bash ~/.claude-voice-cn/start.sh --probe` 探测）
# export VOICE_HOTKEY=f13

# 模型（默认 whisper-small-mlx；想更准换 turbo）
# export VOICE_MODEL=mlx-community/whisper-large-v3-turbo

# 打字掉字就调大间隔；打出带 Option 的怪符号就调大落定延迟
# export VOICE_TYPE_DELAY=0.02
# export VOICE_SETTLE_SECONDS=0.4

# 模型下完之后想硬性断网（之后任何联网都会报错而不是静默外联）
# export HF_HUB_OFFLINE=1

# 设成 0 可以关掉 Claude Code session 的自动拉起（等价于 touch autostart.disabled）
# export VOICE_AUTOSTART=0
EOF
  echo "  ok   ${CONFIG}（改热键/模型在这里）"
fi

# 老版本的 start.sh 是直接 exec python 的前台脚本，没有 start/stop/status；
# 里面如果有用户手写的 export，备份一份再覆盖，别默默吞了。
if [[ -f "${LAUNCHER}" ]] && ! grep -q "voicectl.sh" "${LAUNCHER}"; then
  cp "${LAUNCHER}" "${LAUNCHER}.bak"
  echo "  ..   检测到旧版 start.sh，已备份到 ${LAUNCHER}.bak"
  if grep -q "^export " "${LAUNCHER}.bak"; then
    echo "  !!   旧 start.sh 里有你手写的 export，请搬到 ${CONFIG}" >&2
  fi
fi

cat > "${LAUNCHER}" <<EOF
#!/usr/bin/env bash
# 由 install.sh 生成 —— **每次重装都会被覆盖，别在这里写配置**。
# 改热键/模型请编辑 ${CONFIG}
# 起停逻辑在 ${SKILL_DIR}/voicectl.sh（跟 skill 一起进 git）
#
#   start.sh            前台跑，Ctrl+C 退出（排障用）
#   start.sh start      后台启动
#   start.sh status     看状态
#   start.sh stop       停掉
#   start.sh restart    重启
#   start.sh autostart  安静后台启动（给 Claude Code SessionStart hook 用）
set -uo pipefail

[[ -f "${CONFIG}" ]] && source "${CONFIG}"

export VOICE_PYTHON="${VENV_DIR}/bin/python"
export VOICE_DAEMON_PY="${SKILL_DIR}/voice_daemon.py"

exec bash "${SKILL_DIR}/voicectl.sh" "\$@"
EOF
chmod +x "${LAUNCHER}"
chmod +x "${SKILL_DIR}/voicectl.sh" 2>/dev/null || true
echo "  ok   ${LAUNCHER}"
echo

cat <<EOF
==> 装完了。接下来是 install.sh 不能替你做的两件事：

  A. 授权（系统设置 → 隐私与安全性）
     把「你用来跑这个 daemon 的终端 App」加到这两处并打勾：
       · 麦克风
       · 辅助功能
     授权对象是终端 App 本身（Terminal / iTerm2 / Ghostty / VSCode），不是 python。
     辅助功能那一项加完通常要**完全退出并重开终端**才生效。

  B. 首次启动会下载模型（约 500MB，几分钟），建议**第一次手动前台跑**，
     这样下载进度和权限报错都直接看得见：
       bash ${LAUNCHER}

     看到 "就绪。按住 [alt_r] 说话" 就可以按住右 Option 讲话了。验完 Ctrl+C 退出。

  之后的日常用法（不用再开终端窗口守着）：

     · 后台启停 / 查状态
         bash ${LAUNCHER} start
         bash ${LAUNCHER} status
         bash ${LAUNCHER} stop

     · 开 Claude Code session 自动拉起 —— 在 settings.json 的 SessionStart hook 里配：
         bash "\$HOME/.claude-voice-cn/start.sh" autostart

       已经在跑就什么都不做，正常情况下零输出。临时不想被自动拉起：
         touch ${HOME_DIR}/.claude-voice-cn/autostart.disabled

  日志：${HOME_DIR}/.claude-voice-cn/daemon.log
EOF
