# 事件报告：松开热键后卡死（2026-08-27 ~ 2026-08-29）

面向：下一个接手这个 daemon 的 agent / session。目的是让你不用重新看一遍 git blame
就知道「为什么代码长这样」，避免走回头路把已经拆掉的同步调用重新缝回去。

## 症状

用户按住右 Option 说话、松开后：终端仍显示"录音中…"，daemon 不转录也不响应任何后续按键，
必须 `stop` 杀掉进程才能恢复。**是"松开了但处理卡住"，不是"按住太久没送松开信号"**——
两者表现相似但根因和修法完全不同，watchdog 只防得住后者。

## 根因：三次独立事故，同一个病灶

pynput 的键盘监听跑在**一条专用线程**上（不是主线程）。这条线程上发生的任何阻塞，
后果都是"进程活着、按键彻底没反应"——没有异常、没有日志，跟真死机在体感上没区别。
三次事故各自炸在这条线程上不同的阻塞点，本质都是"listener 线程上跑了不该跑的同步调用"：

| 日期 | 阻塞点 | 触发条件 | 修法 |
|---|---|---|---|
| 08-27 | `sd.InputStream.stop()/close()`（PortAudio 关流） | 松开热键后 CoreAudio 没如期返回 | 把关流动作丢进独立后台线程，不等它返回（`voice_daemon.py` `Recorder.stop()` 里的 `_detach_stream`） |
| 08-28 | 设备表失效导致开流反复报 `-9986` | 睡眠/唤醒或蓝牙耳机热插拔后 PortAudio 缓存的设备表过期 | `Recorder.start()` 捕获异常后 `sd._terminate()`/`sd._initialize()` 刷新设备表重试一次 |
| **08-29（今天，本次事故）** | **`recorder.stop()` 里 `with self._lock:`** | 08-27 只把"关流"这一步挪走了，`recorder.stop()` 本身（含拿锁读取已采集帧）**仍然在 `on_release` 里同步调用**。这把锁跟 PortAudio 音频回调线程共用——回调线程如果因为驱动层异常卡在持锁状态，`on_release` 去抢同一把锁就会跟着冻住，跟 08-27 是同一现象但阻塞点更靠前，08-27 的修法没盖住它 | 把**整个 `_finish_recording()`**（`recorder.stop()` + 判断太短丢弃 + 入队）从 `on_release` 里搬进独立线程，`on_release` 本身只做 `held=False` 和 `Thread(...).start()`，不再碰任何可能触碰 CoreAudio 的东西 |

**当前不变式（改代码前必须维持）**：`on_press` / `on_release` 这两个 pynput 回调里，
除了读写几个纯 Python 变量（`self.held` / `self.press_time`）和启动一个新线程之外，
**不允许出现任何可能触及音频子系统的调用**——包括看起来"应该很快"的那些。
08-29 这次就是被"拿一把锁应该很快"这个直觉坑的。

## 验证过 / 未验证过的边界

- ✅ 已验证：`on_release` → 起新线程 → `_finish_recording` → `recorder.stop()` 阻塞，
  listener 线程不受影响，下一次按键正常触发（本次修复后跑通，daemon 当前存活 pid 已确认是修复后重启的实例）。
- ✅ **残留风险已命中并修复（2026-08-29 稍晚，同日第二次修复）**：`on_press` 里的
  `self.recorder.start()` 当时仍是同步调用，果然如预判炸了——开流卡住，listener 线程冻死，
  连"录音中"都打不出来，表现正是"按下彻底没反应"。修法同款：把它也挪进 `_start_recording`
  后台线程；`_finish_recording`（on_release 那侧）加一个 `threading.Event`
  （`_recording_started`）在调用 `recorder.stop()` 前等 `_start_recording` 完成，
  避免两个后台线程抢 `self._stream`——正常按键时开流是毫秒级，这个等待感知不到；
  只有开流本身卡住时才会体现为"等的是后台线程，不是监听线程"，不影响下一次按键。

## 第四道防线：healthcheck.sh 定时重启（**本次事故顺带发现它没生效**）

08-28 事故后加了 `healthcheck.sh` + `com.colar.voice-cn-healthcheck.plist`：daemon 存活超过
2 小时（可配 `VOICE_MAX_UPTIME_HOURS`）且当前没在录音/转录，就主动重启一次，作为"见招拆招见不完，
不如定期重开"的兜底，不指望堵住所有阻塞点。

**本次排查发现**：这个 plist 已经 `install` 到 `~/Library/LaunchAgents/`，但从未被
`launchctl bootstrap` 过——`launchctl print` 查不到这个 job，`healthcheck.out.log` /
`healthcheck.err.log` 都不存在，说明它从 08-28 装上到 08-29 事故发生的整段时间里
**一次都没跑过**。也就是说 08-29 这次卡死发生时，本该兜底的第四道防线实际上是关着的。

已现场修复（本次会话内已执行，非本报告待办）：

```bash
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.colar.voice-cn-healthcheck.plist
```

**如果以后重装或换机器**，`install.sh` 目前**不会**自动做这一步（它只生成 `start.sh`/`config.sh`，
不碰 launchd）——这是一个供以后 session 补的洞：`install.sh` 或 SKILL.md 里应该有一步显式提醒
`launchctl bootstrap` 这个 plist，否则这道防线会安静地失效而没有任何报错提示你。

## 给下一个 agent 的排查线索

如果又出现"松开热键卡死"：
1. 先看 `~/.claude-voice-cn/daemon.log` 最后一行停在哪个阶段（有没有打出"录音中…"之后就没了）。
2. `bash ~/.claude-voice-cn/start.sh status` 确认进程还活着（僵住不等于进程死了）。
3. `ps -M <pid>`（macOS 查线程）看 pynput 监听线程的调用栈卡在哪——这是唯一能直接定位到
   "又是哪个同步调用漏网"的办法，别猜。
4. 确认 `launchctl print gui/$(id -u)/com.colar.voice-cn-healthcheck` 里 `active count`
   有没有在动——如果这道防线又失效了，至少 2 小时内会有一次自动重启兜底，不会无限卡死。

## 第二个独立事故（同一次会话内发现并已修复）：前台+后台并存导致转录重复

同一次会话里还观察到一个现象：同一句话被转录出两个几乎相同的版本
（"这里可以commit了" / "这里可以去commit"，`daemon.log.prev` 05:34:09~05:34:14）。
**排查后确认这不是"用户重按了热键"，而是两个 daemon.py 进程同时活着**，各自独立
录到同一句话、各自转录、各自打字，才会出现"内容近似但不完全相同"的重复——如果是
同一个进程重复处理同一段音频，两次转录结果应该完全一致；实际观察到的是两个措辞不同的
版本，说明是两次独立的录音+ASR，指向两个独立进程。

**根因**：`voicectl.sh` 的单实例保护只有一个方向。`run_foreground()` 在启动前会检查
`running_pid()`（读 `daemon.pid`）防止跟已有的后台实例抢麦克风——但 `run_foreground()`
自己从来不写 `daemon.pid`。所以反过来，当用户已经在**前台**跑着一个实例时，
`start_background()` 的单实例检查完全看不到这个前台进程，会照常再拉起一个**后台**实例，
两个进程各自注册了同一个全局热键 `alt_r` 的 pynput 监听，用户按一次热键，两边都会响应。

本次事故里，时间线上能对上：用户 05:30:53 前台启动（旧代码，无 pidfile），期间修完
hang bug 后又在 05:33:42 左右起了一个后台实例（新代码，有 pidfile）验证修复——这两个
进程共存的窗口（05:33:42 ~ 05:35:39 前台退出）正好覆盖观察到重复的时间段（05:34:09~05:35:08）。

**已修复**（`voicectl.sh` `run_foreground()`）：前台模式现在也会在 `exec` 前把 `$$`
写进 `daemon.pid`——`exec` 只换进程镜像不换 pid，所以写的就是最终 python 进程的 pid。
这样无论谁先起（前台先、后台先），另一侧的单实例检查都能看见对方，不会再出现两个
daemon 同时抢同一个热键的情况。**用完前台记得 `stop` 或 Ctrl+C**——退出后 pidfile
会变成指向死进程，下次 `status`/`start`/`stop` 时按现有逻辑自动清掉，不用手动处理。

## 第四次事故（2026-09-01，两轮：先打了个不够的补丁，复现后拿到真实线程栈，确认根因）

### 第一轮：假设性修复（已证明不够）

Colar 报告：短按（<1s）热键后 daemon 彻底冻结，必须 `stop` 才能恢复。当时没能在冻结现场
留下线程栈，只能读代码推出一个假设——`Recorder.start()` 没有互斥锁，两次快速连按可能
并发调用 `sd.InputStream()` 撞车——据此给 `start()` 加了一把 `_start_lock`。**这个修复
只包住了 `start()`，完全没碰 `Recorder.stop()` 里 `_detach_stream()` 的 `stream.stop()/close()`**，
补丁上线后同一会话内很快又复现了同样的冻结，证明假设不完整。

### 第二轮：复现时用 `sample` 抓到真实线程栈，确认根因

冻结复现时执行 `/usr/bin/sample <pid> 3 -file <out>`（注意：`sample` 这个命令名被
mlx-whisper 依赖链里某个同名 Python 包的 entry point 脚本shadow 了，`which sample` 会
先命中 `.../Python.framework/.../bin/sample` 报 `ModuleNotFoundError`，必须显式用
`/usr/bin/sample` 全路径调用系统自带的那个）。3 秒采样清楚拍到三个线程同时卡死：

- **Thread（Python，`_detach_stream` 里跑上一次录音的 `stream.stop()`）**：调用链
  `FinishStoppingStream → AudioOutputUnitStop → AudioDeviceStop_mac_imp →
  HALC_ShellDevice::StopIOProc → HALC_ProxyIOContext::StopIOProc → HALB_Mutex::Lock()`，
  卡在 `__psynch_mutexwait` 上等一把设备级互斥锁。
- **Thread（Python，`start()` 里跑这一次新按键的 `sd.InputStream(...)` 开流）**：调用链
  `Pa_OpenStream → OpenStream → OpenAndSetupOneAudioUnit → AudioUnitSetProperty →
  AudioDeviceCreateIOProcID_mac_imp → HALC_ShellDevice::CreateIOProcID →
  HALB_Mutex::Lock()`——**卡在同一把 `HALB_Mutex`**。
- **`com.apple.audio.IOThread.client`（CoreAudio 自己的 IO 线程，不是我们的代码）**：
  同时卡在 `AudioUnitGetProperty` 内部的 `std::recursive_mutex::lock()`，被上面两个
  线程的锁争用连带卡住。

**确认根因**：不是"两次开流并发"，是**"上一次录音的关流（异步 `_detach_stream`）跟
这一次的开流（`start()`）并发撞在了 CoreAudio 同一把设备级互斥锁上"**。08-27 的修复
把关流这个动作丢进了完全不设防的后台线程（理由是"不影响已采集数据，没必要阻塞调用方"），
这个理由本身没错，但代价是它跟同样跑在后台线程的 `start()` 之间毫无互斥——两者独立
异步、各自去碰同一个 PortAudio `Recorder` 实例背后的同一个物理设备，PortAudio/CoreAudio
不保证这种跨调用的并发安全。`start()` 那把新加的 `_start_lock` 完全帮不上，因为
`_detach_stream` 根本不认这把锁。

复现时 `SIGTERM` 5 秒没能让进程退出，最后是 `SIGKILL` 杀掉的——侧面印证这是内核态
mutex 等待级别的真死锁，不是 Python 层面能被信号打断的阻塞。

**已修复**（`voice_daemon.py` `Recorder`）：把锁改名为 `_audio_op_lock`（不再只是
"start 锁"），`start()` 和 `stop()` 里的 `_detach_stream()` 现在共用同一把锁，
两边都 `acquire(timeout=MAX_SECONDS)` 兜底——任何时候只允许一个方向（开或关）在跟
CoreAudio 打交道，另一个必须排队等它先完成（正常情况下开/关流都是毫秒级，排队感知
不到）；万一真卡死，等满 2 分钟后放弃而不是无限叠加等待。**这次是有真实线程栈证据
坐实的修复，不是纯代码推理**——但仍然建议留意：如果以后再冻，机制同上，先
`/usr/bin/sample <pid> 3 -file <out>` 留证据再 `stop`。

### 第三轮：专家团审核 + 同一会话内真实复现，补齐 4 处 mustFix

补丁上线后同一会话内很快真实复现了一次（这次不再需要 `stop`，daemon 自己在
120s 超时后恢复，日志留了 `音频操作锁等待超时` 这行）——证明底层 CoreAudio 死锁
本身还会发生，锁只是把"必须 stop 才能救"降级成"最长 2 分钟自动放弃"，没有消灭
根因。同时叫了 4 位专家（并发/CoreAudio底层/系统可靠性/代码质量安全）做对抗审核，
17 条 claim 里 3 条被硬证据驳倒，剩下的收敛出 4 个 mustFix，均已修复：

1. **`healthcheck.sh`（第四道防线）实测从 8-31 起持续失败，`Operation not permitted`**——
   根因是 launchd 拉起的 `/bin/bash` 没有 Terminal.app 那种 macOS TCC「文件和文件夹」
   授权，读不了 `~/Desktop` 下的脚本。修法：`install.sh` 新增第 6 步，把
   `healthcheck.sh` 拷贝到运行时目录 `~/.claude-voice-cn/healthcheck.sh`（跟
   `start.sh`/`config.sh` 同样的"skill 目录放源码、`~/.claude-voice-cn` 放运行时入口"
   拆法），并自动 `launchctl bootout` + `bootstrap` 让 plist 指向新路径。已现场验证：
   `launchctl kickstart` 触发一次，`healthcheck.err.log` 不再新增报错。
2. **`sd._terminate()/_initialize()` 刷新调用没有独立超时**，且现在被包进了
   `_audio_op_lock` 里——一旦它卡死，整把锁会被永久占住，之后每次按键都要
   干等满 `MAX_SECONDS` 才放弃。**审查后发现这个风险面比专家团指出的更广**：
   `_open_stream()`（真正的 `sd.InputStream(...)` 开流调用）和 `stream.stop()/close()`
   本身也是没有独立超时的原生调用，任何一个卡死都是同样的"锁永久泄漏"后果——
   这正是本轮真实复现时很可能命中的那个点（复现时日志里没有"打开音频流失败"这行，
   说明卡的不是刷新重试分支，是主路径本身）。修法：新增 `call_with_timeout()`
   （独立线程跑原生调用 + `join(timeout=NATIVE_CALL_TIMEOUT=10s)`，超时就不再等），
   包住 `_open_stream()`（含重试路径）和 `_detach_stream()` 里的 `stop()/close()`。
   超时后底层线程会变成一个永远不返回的孤儿 daemon 线程（泄漏但无害），换来的是
   `_audio_op_lock` 保证在 ~10s 内释放，不会再被单个卡死的原生调用拖到 2 分钟。
3. **`voicectl.sh` 的 mkdir 启动锁没有陈旧检测**——一次异常强杀（比如这次复现用的
   `SIGKILL`）会让 `EXIT trap` 没机会跑，`.start.lock` 目录永久残留，之后 autostart
   静默判定"已有启动流程在跑"直接放弃、零提示。修法：`start_background()` 抢锁失败时
   先看 `.start.lock` 的 mtime，超过 `STALE_LOCK_SECONDS=30`（正常启动流程 1 秒内
   完事）就判定陈旧，强制 `rmdir` 后重新抢一次。
4. **新锁把冻结变成了完全不可观测的静默空等**——`status`/`healthcheck` 都读不到
   "现在卡在开/关流里多久了"。修法：`voice_daemon.py` 在持有 `_audio_op_lock` 期间
   `touch` `~/.claude-voice-cn/audio_op.busy`（写入时间戳），释放锁时删掉；
   `voicectl.sh status` 读这个文件的年龄，超过 3 秒就打印一行明确提示
   （"音频操作已持续 Ns 未完成……不需要手动 stop"），不再是纯粹的黑箱。

**仍未解决、专家团标记为 contested、不阻塞本次 commit**：四层防线（listener 线程
隔离 / stop 异步化 / watchdog / 本次锁）是否该用子进程隔离这类更根本方案统一取代。
代码自身注释已经反驳"四层同源可被一次重构统一取代"——watchdog 防的是 macOS 偶发
丢失键盘松开事件，跟线程卡在原生调用是完全不同的失败模式，重构后大概率还得留着。
值得排期单独评估，但不是这次的阻塞项。
