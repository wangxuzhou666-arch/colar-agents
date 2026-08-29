#!/usr/bin/env python3
"""中文语音输入 daemon —— 按住热键说话，松开后本地转录并模拟打字到当前聚焦窗口。

链路：全局热键(pynput) → 麦克风采集(sounddevice) → 本地 ASR(mlx-whisper) → 模拟打字(pynput)

全程本地：音频只存在于本进程内存，**不写盘、不上传、不经任何 API**。
唯一的网络行为是 mlx-whisper 首次运行时从 Hugging Face 下载模型权重；
下载完成后可以设 HF_HUB_OFFLINE=1 彻底断网运行（见 SKILL.md）。

用法：
    python3 voice_daemon.py           # 前台启动
    python3 voice_daemon.py --probe   # 按键名探测模式（不录音，只打印你按了哪个键）

日常不直接调这个文件 —— 起停走 `~/.claude-voice-cn/start.sh`（start / stop / status /
autostart），后台化和 pidfile 都在那一层（voicectl.sh）。本文件永远只是个前台进程。

配置全部走环境变量，见下方 CONFIG 段。
"""

from __future__ import annotations

import os
import queue
import signal
import sys
import threading
import time

import numpy as np
import sounddevice as sd
from pynput import keyboard

# ---------------------------------------------------------------- CONFIG ----

# 热键：pynput 的 Key 名。默认 Right Option（macOS 上报为 alt_r）。
# 选它的理由：单独按不产生任何字符、不与系统中文输入法切换键冲突
# （系统默认切换是 Ctrl+Space / Caps Lock，都不能占）。
# 换成别的：VOICE_HOTKEY=f13 / cmd_r / ctrl_r ...；不确定键名就跑 --probe。
HOTKEY_NAME = os.environ.get("VOICE_HOTKEY", "alt_r")

# ASR 模型。默认 small：约 500MB，Apple Silicon 上一句话约 0.5-1.5s，
# 是"能听清普通话"的最低可用档，也是首次下载不至于劝退的尺寸。
# 中文识别质量想更好 → VOICE_MODEL=mlx-community/whisper-large-v3-turbo（约 1.6GB，
# 解码层少所以在 M 系芯片上依然快）。想更快更省 → whisper-base-mlx（约 150MB，中文会明显掉字）。
MODEL_REPO = os.environ.get("VOICE_MODEL", "mlx-community/whisper-small-mlx")

# 固定中文。这个 daemon 刻意不做多语言切换 —— 让 whisper 自动检测语言在短句上极易误判成日语/英语。
LANGUAGE = "zh"

# 引导 whisper：1) 输出简体中文而不是繁体（whisper 中文输出默认偏繁体，社区通行解法）
# 2) 句中夹杂的英文技术词保留英文原样，不要音译成谐音中文字——
#    这是小模型在中英混说场景最容易翻车的地方，给个例句让模型见过这种混说模式。
INITIAL_PROMPT = os.environ.get(
    "VOICE_PROMPT",
    "以下是普通话的句子，请用简体中文输出。句子里可能夹杂英文单词或技术术语，"
    "例如 API、session、hook、commit、debug，这些词请保留英文原文，不要音译成中文。",
)

TARGET_SR = 16000  # whisper 要求 16kHz
MIN_SECONDS = float(os.environ.get("VOICE_MIN_SECONDS", "0.4"))  # 短于此的按键当误触丢弃
MAX_SECONDS = float(os.environ.get("VOICE_MAX_SECONDS", "120"))  # 防止热键卡住无限录音

# 松开热键后等一小会儿再打字，让系统的修饰键状态落定，
# 否则偶发把字符打成带 Option 的特殊符号。
SETTLE_SECONDS = float(os.environ.get("VOICE_SETTLE_SECONDS", "0.2"))

# 逐字打字的间隔。0 会在 Electron 类应用（VSCode / Slack / Chrome）里掉字。
TYPE_DELAY = float(os.environ.get("VOICE_TYPE_DELAY", "0.008"))

# 就绪标记文件。由 voicectl.sh 传入；后台跑时看不到终端输出，
# 靠这个文件区分「进程活着但还在下/载模型」和「真的在听了」。留空则不写。
READY_FILE = os.environ.get("VOICE_READY_FILE", "")


def log(msg: str) -> None:
    # 带时间戳：后台模式下这些行是落在 daemon.log 里的，没有时间戳没法排障。
    print(f"[voice {time.strftime('%H:%M:%S')}] {msg}", flush=True)


def mark_ready() -> None:
    if not READY_FILE:
        return
    try:
        os.makedirs(os.path.dirname(READY_FILE), exist_ok=True)
        with open(READY_FILE, "w") as fh:
            fh.write(f"{os.getpid()}\n")
    except OSError as exc:
        log(f"就绪标记写入失败（不影响使用，只是 status 看不到就绪）：{exc}")


def clear_ready() -> None:
    if not READY_FILE:
        return
    try:
        os.unlink(READY_FILE)
    except OSError:
        pass


# ------------------------------------------------------------- 热键解析 ----


def resolve_hotkey(name: str) -> keyboard.Key:
    key = getattr(keyboard.Key, name, None)
    if key is None:
        raise SystemExit(
            f"未知热键名 {name!r}。跑 `python3 {os.path.basename(__file__)} --probe` "
            f"按一下你想用的键，把它打印出的名字填进 VOICE_HOTKEY。"
        )
    return key


def probe() -> int:
    """按键名探测：按任意键打印 pynput 认到的名字，Ctrl+C 退出。"""
    log("探测模式。按你想当热键的那个键，看打印出的名字。Ctrl+C 退出。")

    def on_press(key: object) -> None:
        name = getattr(key, "name", None)
        print(f"  按下 → {key!r}" + (f"   VOICE_HOTKEY={name}" if name else "   (普通字符键，不适合当热键)"))

    with keyboard.Listener(on_press=on_press) as listener:
        listener.join()
    return 0


# --------------------------------------------------------------- 录音 ----


def resample_to_16k(audio: np.ndarray, src_sr: int) -> np.ndarray:
    if src_sr == TARGET_SR:
        return audio
    duration = audio.shape[0] / float(src_sr)
    target_n = int(round(duration * TARGET_SR))
    if target_n <= 1 or audio.shape[0] <= 1:
        return np.zeros(0, dtype=np.float32)
    src_t = np.linspace(0.0, duration, num=audio.shape[0], endpoint=False)
    dst_t = np.linspace(0.0, duration, num=target_n, endpoint=False)
    return np.interp(dst_t, src_t, audio).astype(np.float32)


class Recorder:
    """按需开关麦克风。刻意不常驻打开 —— 常驻会让 macOS 的橙色麦克风指示灯一直亮着。"""

    def __init__(self) -> None:
        self.sample_rate = self._pick_sample_rate()
        self._stream: sd.InputStream | None = None
        self._frames: list[np.ndarray] = []
        self._lock = threading.Lock()

    @staticmethod
    def _pick_sample_rate() -> int:
        try:
            sd.check_input_settings(samplerate=TARGET_SR, channels=1, dtype="float32")
            return TARGET_SR
        except Exception:
            default_sr = int(sd.query_devices(kind="input")["default_samplerate"])
            log(f"麦克风不支持 16kHz，改用设备默认 {default_sr}Hz 采集后重采样。")
            return default_sr

    def _callback(self, indata: np.ndarray, frames: int, time_info: object, status: object) -> None:
        if status:
            log(f"音频流警告: {status}")
        with self._lock:
            self._frames.append(indata[:, 0].copy())

    def start(self) -> None:
        if self._stream is not None:
            return
        with self._lock:
            self._frames = []
        try:
            self._open_stream()
        except Exception as exc:
            # 睡眠/唤醒或耳机蓝牙热插拔之后，PortAudio 缓存的设备表会失效，
            # 表现为反复报 -9986 / Invalid Property Value 之类的错误（2026-08-28 实测）。
            # 只重开一个新 stream 不够——PortAudio 的主机 API 状态本身要刷新才行。
            # sd._terminate()/_initialize() 是 sounddevice 没有公开但社区通行的刷新法。
            log(f"打开音频流失败（{exc}），尝试刷新音频设备表后重试一次…")
            try:
                sd._terminate()
                sd._initialize()
                self.sample_rate = self._pick_sample_rate()
                self._open_stream()
            except Exception as retry_exc:
                raise RuntimeError(f"刷新设备表后仍失败：{retry_exc}") from retry_exc

    def _open_stream(self) -> None:
        self._stream = sd.InputStream(
            samplerate=self.sample_rate,
            channels=1,
            dtype="float32",
            callback=self._callback,
        )
        self._stream.start()

    def stop(self) -> np.ndarray:
        """停止并返回 16kHz mono float32。没有录到东西时返回空数组。

        真正关闭 PortAudio 流（stream.stop/close）丢到后台线程去做、不等它返回。
        这两个调用偶发会因为音频驱动问题卡死（2026-08-27 实测遇到过：松开热键后
        CoreAudio 没如期返回，把调用它的 pynput 监听线程整个冻住，
        之后所有按键都没反应，看门狗也救不了——因为它检查的是「按住没松开」，
        这里是「松开了但处理卡住」，是两回事）。音频帧已经在锁保护下拿到手，
        关流这个动作不影响已采集的数据，没必要为它阻塞调用方。"""
        stream, self._stream = self._stream, None
        with self._lock:
            frames, self._frames = self._frames, []
        if stream is not None:
            def _detach_stream() -> None:
                try:
                    stream.stop()
                    stream.close()
                except Exception as exc:
                    log(f"后台关闭音频流出错（不影响本次识别）：{exc}")

            threading.Thread(target=_detach_stream, daemon=True).start()
        if not frames:
            return np.zeros(0, dtype=np.float32)
        audio = np.concatenate(frames)
        max_samples = int(MAX_SECONDS * self.sample_rate)
        if audio.shape[0] > max_samples:
            log(f"录音超过 {MAX_SECONDS:.0f}s，只取前段。")
            audio = audio[:max_samples]
        return resample_to_16k(audio, self.sample_rate)


# ----------------------------------------------------------------- ASR ----


class Transcriber:
    def __init__(self, repo: str) -> None:
        self.repo = repo
        import mlx_whisper  # 延迟导入：import 本身约 2s，放模块顶会拖慢启动报错反馈

        self._mlx_whisper = mlx_whisper

    def warmup(self) -> None:
        """用 0.5s 静音跑一次，把模型权重下载 + 载入提前到启动阶段，
        免得第一句话说完要干等几分钟下模型。"""
        self._mlx_whisper.transcribe(
            np.zeros(TARGET_SR // 2, dtype=np.float32),
            path_or_hf_repo=self.repo,
            language=LANGUAGE,
            fp16=True,
        )

    def transcribe(self, audio: np.ndarray) -> str:
        result = self._mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=self.repo,
            language=LANGUAGE,
            initial_prompt=INITIAL_PROMPT,
            condition_on_previous_text=False,  # 每次按键是独立一句，不要让上一句污染这一句
            fp16=True,
        )
        return str(result.get("text", "")).strip()


# ---------------------------------------------------------------- 打字 ----

_controller = keyboard.Controller()


def type_text(text: str) -> None:
    """把文本直接以 Unicode 插入当前聚焦窗口。

    走的是 macOS 的 CGEventKeyboardSetUnicodeString —— 不经过系统输入法，
    所以中文能原样打出，也不受当前是英文还是拼音输入法影响。
    逐字 + 微延迟：一次性 type 整串在 Electron 应用里会掉字。
    """
    for ch in text:
        _controller.type(ch)
        if TYPE_DELAY > 0:
            time.sleep(TYPE_DELAY)


# ---------------------------------------------------------------- 主体 ----


class Daemon:
    def __init__(self) -> None:
        self.hotkey = resolve_hotkey(HOTKEY_NAME)
        self.recorder = Recorder()
        self.transcriber = Transcriber(MODEL_REPO)
        self.jobs: queue.Queue[np.ndarray | None] = queue.Queue()
        self.held = False  # 防 auto-repeat：按住不放时 on_press 会连续触发
        self.busy = False
        self.press_time: float | None = None  # 看门狗用：判断"按住"是否已经超时
        self._stop_watchdog = threading.Event()

    # -- 键盘回调（跑在 pynput 的监听线程上，必须快，重活丢给 worker） --

    def on_press(self, key: object) -> None:
        if key != self.hotkey or self.held:
            return
        self.held = True
        if self.busy:
            log("上一句还在转录，本次录音先排队…")
        try:
            self.recorder.start()
            self.press_time = time.monotonic()
            log("录音中… 松开热键结束")
        except Exception as exc:
            log(f"麦克风打开失败：{exc}（多半是没给麦克风权限，见 SKILL.md）")

    def on_release(self, key: object) -> None:
        if key != self.hotkey or not self.held:
            return
        self.held = False
        self.press_time = None
        # 丢给后台线程处理，绝不在 pynput 监听线程上做任何可能阻塞的事——
        # recorder.stop() 内部会拿锁、可能触碰 CoreAudio，一旦卡住会把这条
        # 监听线程整个冻住，之后所有按键都收不到（2026-08-27/29 两次实测遇到，
        # 看门狗防不了：它盯的是"按住太久不松开"，这里是"松开了但处理卡住"，两回事）。
        threading.Thread(target=self._finish_recording, daemon=True).start()

    def _finish_recording(self) -> None:
        """真正处理一次录音：停流 → 太短就丢 → 排进转录队列。
        on_release（经后台线程）和看门狗（松开信号丢失兜底）共用这一段。"""
        try:
            audio = self.recorder.stop()
        except Exception as exc:
            log(f"停止录音失败：{exc}")
            return
        seconds = audio.shape[0] / TARGET_SR
        if seconds < MIN_SECONDS:
            log(f"只录到 {seconds:.2f}s，当误触丢弃。")
            return
        self.busy = True
        self.jobs.put(audio)
        pending = self.jobs.qsize()
        if pending > 1:
            log(f"已排队 {pending} 句待转录。")

    def watchdog(self) -> None:
        """极少发生但真实存在：macOS 偶发丢失修饰键的松开事件（切窗口/系统手势时），
        导致 held 卡 True、麦克风永久开着录（本 daemon 2026-08-27 首次实测到过一次，卡了近 3 分钟）。
        每秒检查一次，按住超过 MAX_SECONDS 还没收到松开信号就当作信号丢失，强制结束这次录音。"""
        while not self._stop_watchdog.wait(1.0):
            press_time = self.press_time
            if self.held and press_time is not None and time.monotonic() - press_time > MAX_SECONDS:
                log(f"按住已超过 {MAX_SECONDS:.0f}s 仍未收到松开信号，判定信号丢失，强制结束本次录音。")
                self.held = False
                self.press_time = None
                self._finish_recording()

    # -- worker 线程：转录 + 打字 --

    def worker(self) -> None:
        while True:
            audio = self.jobs.get()
            if audio is None:
                return
            try:
                started = time.monotonic()
                text = self.transcriber.transcribe(audio)
                elapsed = time.monotonic() - started
                if not text:
                    log(f"没识别出内容（{elapsed:.1f}s）。")
                    continue
                log(f"识别（{elapsed:.1f}s）：{text}")
                time.sleep(SETTLE_SECONDS)
                type_text(text)
            except Exception as exc:
                log(f"转录/打字失败：{exc}")
            finally:
                self.busy = False

    def run(self) -> int:
        log(f"模型：{MODEL_REPO}")
        log("载入模型中…（首次运行要从 Hugging Face 下模型，几百 MB，请耐心等）")
        try:
            self.transcriber.warmup()
        except Exception as exc:
            log(f"模型载入失败：{exc}")
            return 1
        log("模型就绪。")

        threading.Thread(target=self.worker, daemon=True).start()
        threading.Thread(target=self.watchdog, daemon=True).start()

        listener = keyboard.Listener(on_press=self.on_press, on_release=self.on_release)
        listener.start()
        if not listener.running:
            log("键盘监听启动失败 —— 多半是没给「辅助功能」权限，见 SKILL.md。")
            return 1

        log(f"就绪。按住 [{HOTKEY_NAME}] 说话，松开转录并打字。")
        mark_ready()

        stop = threading.Event()
        signal.signal(signal.SIGINT, lambda *_: stop.set())
        signal.signal(signal.SIGTERM, lambda *_: stop.set())
        try:
            while not stop.is_set() and listener.running:
                stop.wait(0.2)
        finally:
            clear_ready()

        log("退出中…")
        listener.stop()
        self._stop_watchdog.set()
        self.jobs.put(None)
        return 0


def main() -> int:
    if "--probe" in sys.argv:
        return probe()
    try:
        return Daemon().run()
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
