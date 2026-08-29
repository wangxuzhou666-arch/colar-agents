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
- ⚠️ **残留同类风险，刻意没动**：`on_press` 里的 `self.recorder.start()` 仍是**同步调用**——
  如果开流本身卡住（比如设备表刷新那条 fallback 路径本身又卡住），listener 线程一样会冻，
  但表现会是"按下没反应"而不是这次报告的"松开卡死"，属于不同症状、暂无实测证据。
  没有顺手把它也挪线程，是因为：(a) 本次事故报告的症状明确是松开侧，不该借机扩大改动范围；
  (b) 08-28 已经在 `start()` 内部加了一次自愈重试，理论上覆盖了最常见的触发源（睡眠唤醒）。
  如果以后真的观测到"按下没反应"的新事故，这是第一个该看的地方。

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
