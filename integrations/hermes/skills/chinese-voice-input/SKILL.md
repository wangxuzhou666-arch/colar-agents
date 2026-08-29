---
name: chinese-voice-input
description: "macOS 上的中文语音输入 —— 一个常驻 Python daemon，按住右 Option 说话、松开后本地 mlx-whisper 转录、用 Accessibility API 把中文模拟打字进当前聚焦的任意输入框（Claude Code 终端 / VSCode / 浏览器都行）。补 Claude Code 内置 `/voice` 听写不支持中文的缺口；语音数据全程不出本机（唯一网络行为是首次下模型权重）。Use when: 想用中文语音而不是打字给 Claude Code 下指令、要安装或启动这个 daemon、要改热键或换 whisper 模型，或排查「按了热键没反应 / 识别出来是繁体或英文 / 字打不进某个 App / 热键和输入法切换打架 / 首次启动卡在载入模型」。"
version: 1.1.0
source: 照抄 jvosloo/claude-voice (https://github.com/jvosloo/claude-voice) 的「语音→文字→模拟打字」核心链路；Colar 拍板只做这一条，不做 TTS / 双向语音。ASR 定为本地 mlx-whisper，不用云端 API。与 Claude Code 的耦合仅限一条 SessionStart hook 负责「把 daemon 拉起来」，不做语音结果回灌之类的深度集成。
---

# chinese-voice-input — macOS 中文语音输入 daemon

Claude Code 内置的 `/voice` 听写不支持中文。这个 skill 用一个自己的常驻进程补上：

```
按住热键 → 麦克风采集(sounddevice) → 本地 ASR(mlx-whisper, language=zh) → 模拟打字(pynput)
```

**一句话心智模型**：它不是「Claude Code 的语音功能」，而是**一个系统级的中文听写键**。
它把文字打进**当前聚焦的窗口**，所以在终端、VSCode、Chrome 地址栏里都一样能用 —— Claude Code 只是它最常见的落点。

**边界**（拍板过，别往回加）：不做 TTS 朗读、不做双向语音、不做多语言切换。保持精简好维护。

与 Claude Code 的唯一耦合是**一条 SessionStart hook 负责把 daemon 拉起来**——只管进程生死，
不往 Claude Code 里回灌任何东西。daemon 依然是个跟 Claude Code 无关的系统级听写键。

---

## When to Use

**触发**
- 想用中文语音代替打字给 Claude Code 下指令
- 要装 / 启动这个 daemon
- 要换热键、换 whisper 模型尺寸
- 排障：按了没反应 / 识别成繁体或英文 / 字打不进某个 App / 首次启动卡住

**不触发**
- 英文听写 → 直接用 Claude Code 内置 `/voice`，别起这个进程
- 要 Claude 把回复读出来（TTS）→ 不在本 skill 范围
- 非 Apple Silicon 的 Mac → mlx 跑不了，本方案不适用

---

## 文件与落点

| 东西 | 路径 |
|---|---|
| daemon（录音/识别/打字） | `~/Desktop/colar-agents/integrations/hermes/skills/chinese-voice-input/voice_daemon.py` |
| 起停逻辑（后台/status/stop） | `~/Desktop/colar-agents/integrations/hermes/skills/chinese-voice-input/voicectl.sh` |
| 安装脚本 | `~/Desktop/colar-agents/integrations/hermes/skills/chinese-voice-input/install.sh` |
| venv | `~/.claude-voice-cn/venv` |
| **入口**（install.sh 生成，重装会覆盖） | `~/.claude-voice-cn/start.sh` |
| **用户配置**（改热键/模型，重装不覆盖） | `~/.claude-voice-cn/config.sh` |
| 后台日志 | `~/.claude-voice-cn/daemon.log`（上一轮留在 `daemon.log.prev`） |
| pidfile / 就绪标记 | `~/.claude-voice-cn/daemon.pid` · `daemon.ready` |
| 关掉自动拉起的开关文件 | `~/.claude-voice-cn/autostart.disabled` |
| 模型权重缓存 | `~/.cache/huggingface/hub/`（mlx-whisper 自动管理） |
| 定期重启兜底脚本 | `~/Desktop/colar-agents/integrations/hermes/skills/chinese-voice-input/healthcheck.sh` |
| 定期重启的 launchd 任务定义 | `~/Library/LaunchAgents/com.colar.voice-cn-healthcheck.plist` |

代码住 skill 目录（跟 colar-agents 一起进 git），运行时环境住 `~/.claude-voice-cn/`（不进 git）。

**第四道防线：定期重启**。daemon 存活超过 `VOICE_MAX_UPTIME_HOURS`（默认 2 小时）且当前没在
录音/转录，`healthcheck.sh` 就会主动 `restart` 一次——不指望堵住所有可能的阻塞点，见招拆招见不完，
定期重开换稳定性。由 `com.colar.voice-cn-healthcheck.plist`（每 30 分钟触发一次检查）驱动。

⚠️ **`install.sh` 不会自动装这个 launchd 任务**——plist 文件存在不等于它在跑，必须手动
`launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.colar.voice-cn-healthcheck.plist`
才会真正生效。`launchctl print "gui/$(id -u)/com.colar.voice-cn-healthcheck"` 能查到就是装上了。
（2026-08-29 实测过一次：plist 装了整整一天从未被 bootstrap，这道防线全程没生效，见
`INCIDENT-2026-08-hang-on-release.md`。）

**为什么起停逻辑单独一个 `voicectl.sh` 而不是塞进 start.sh**：start.sh 每次重装都会被 install.sh 重新生成。
把逻辑放 skill 目录、start.sh 只当薄壳，改逻辑就不用重跑 install.sh；
再把用户配置拆到 `config.sh`（只在缺失时创建），重装也不会把你改的热键冲掉。

---

## 前置条件：两个权限必须手动给

**这一步没有任何脚本能替你做**，macOS 的权限弹窗只认人。

授权对象是**你用来跑 daemon 的那个终端 App**，不是 `python`。
因为 daemon 是终端的子进程，macOS 按发起进程的父 App 归属权限：

| 从哪儿跑 | 要授权谁 |
|---|---|
| Terminal.app | Terminal |
| iTerm2 | iTerm2 |
| Ghostty / Warp / Kitty | 那个 App 本身 |
| VSCode 内置终端 | Visual Studio Code |

**系统设置 → 隐私与安全性**，两处都要加并打勾：

1. **麦克风** —— 不给：daemon 启动没事，一按热键报「麦克风打开失败」。
2. **辅助功能（Accessibility）** —— 不给：**热键监听和模拟打字两件事全废**，而且 pynput 常常是静默失效（进程活着、按键毫无反应）。

> ⚠️ 「辅助功能」加完**必须完全退出终端 App 再重开**（Cmd+Q，不是关窗口）才生效。
> 这是最高频的「明明打勾了还是没反应」原因。
>
> ⚠️ 换终端 App 跑（比如从 iTerm2 换到 VSCode）要**重新给一遍**，权限不跨 App 继承。

**自动拉起后这条规则更要命**：daemon 由 SessionStart hook 拉起，等于**权限归属跟着「你在哪个 App 里开的 Claude Code」走**。
而 daemon 是单例（pidfile 挡重复启动），所以**谁先开 session 谁占坑**：
如果第一个 session 开在没授权的 App 里，拉起来的 daemon 是个哑巴（进程活着、按键没反应），
之后在已授权的终端里再开 session 也不会再拉一个——它看到「已在运行」就跳过了。
排查见 Pitfalls 表倒数第二行。

---

## 安装

```bash
bash ~/Desktop/colar-agents/integrations/hermes/skills/chinese-voice-input/install.sh
```

它做五件事，每步都有 echo：检查 macOS/arm64/Python → 缺 ffmpeg 就 `brew install ffmpeg` →
建 venv 于 `~/.claude-voice-cn/venv` → 装 `mlx-whisper pynput sounddevice numpy` →
生成入口 `~/.claude-voice-cn/start.sh`（每次重装都覆盖）+ 配置 `~/.claude-voice-cn/config.sh`（只在缺失时创建）。

**它不做**：不下载模型权重、不启动 daemon、不碰系统权限。模型在第一次启动 daemon 时才下。

---

## 启动与使用

**日常不用管它**：开一个新的 Claude Code session 时，SessionStart hook 会在后台把 daemon 静默拉起来；
已经在跑就什么都不做（pidfile 挡着，不会拉起第二个去抢麦克风）。

**用法**：光标点进想输入的地方 → **按住右 Option** → 说话 → **松开** → 一两秒后中文出现在光标处。

### 首次：先手动前台跑一次

第一次别指望 hook——模型要下 500MB，权限也还没验，**前台跑能直接看见进度和报错**：

```bash
bash ~/.claude-voice-cn/start.sh
```

看到 `[voice HH:MM:SS] 就绪。按住 [alt_r] 说话，松开转录并打字。` 就是通了，`Ctrl+C` 退出，之后交给 hook。

### 查状态 / 停止

后台跑没有终端窗口可看，**可见性全靠这两个**：

```bash
bash ~/.claude-voice-cn/start.sh status   # 运行中 pid=… 已就绪 / 尚未就绪（在载模型）/ 未运行
bash ~/.claude-voice-cn/start.sh stop     # SIGTERM，5s 不退再 SIGKILL，然后清 pidfile
bash ~/.claude-voice-cn/start.sh restart  # 改完 config.sh 用这个生效
tail -f ~/.claude-voice-cn/daemon.log     # 每句识别结果都在里面
```

`status` 区分「进程活着」和「真的在听了」：daemon 就绪时会写 `daemon.ready`，
所以**「运行中但尚未就绪」= 还在下/载模型，不是坏了**，等就行。

日志每次启动截断一次，上一轮留在 `daemon.log.prev`——所以崩了之后仍有一轮现场可看。

### 临时不想被自动拉起

```bash
touch ~/.claude-voice-cn/autostart.disabled    # 之后开 session 不再自动拉起
rm ~/.claude-voice-cn/autostart.disabled       # 恢复
```

开关文件只挡**自动**拉起，手动 `start` / 前台跑不受影响。
（等价做法：在 `config.sh` 里 `export VOICE_AUTOSTART=0`。）

注意开关只是「不再拉新的」——**已经在跑的不会被它停掉**，要停得显式 `stop`。

### 手动后台启停（不经 hook）

```bash
bash ~/.claude-voice-cn/start.sh start      # 后台起，有输出
bash ~/.claude-voice-cn/start.sh autostart  # 后台起，安静版（hook 用的就是这条）
```

前台跑时如果后台已经有一个在跑，会直接拒绝并提示先 `stop`——避免两个实例抢麦克风。

### daemon 的生命周期不跟 session 结束

hook 只负责**开** session 时拉起。daemon 是 `nohup` detach 的，
**关掉那个 session、甚至关掉终端，它都还活着**——这正是「不用守着一个终端窗口」想要的效果。
要它停只有两条路：`stop`，或者注销/重启。

---

## 改热键

默认 **右 Option**（pynput 名 `alt_r`）。选它是因为它单独按不产生任何字符，
且**不与系统中文输入法切换键冲突** —— macOS 的输入法切换默认占用 Ctrl+Space 或 Caps Lock，这两个都不能用。

改：编辑 **`~/.claude-voice-cn/config.sh`**（不是 start.sh——那个重装会被覆盖），取消注释改值，然后 `restart`。

```bash
export VOICE_HOTKEY=f13     # 或 cmd_r / ctrl_r / alt_l ...
```

```bash
bash ~/.claude-voice-cn/start.sh restart
```

不知道某个键的 pynput 名字，用探测模式（只打印键名，不录音）：

```bash
bash ~/.claude-voice-cn/start.sh --probe
```

按一下目标键，把它打印出的 `VOICE_HOTKEY=xxx` 抄进 `config.sh`。
（探测模式不开麦克风，后台 daemon 在跑也能直接用，不用先 `stop`。）

---

## 换模型

默认 `mlx-community/whisper-small-mlx`。

**为什么是 small**：约 500MB、一句话转录 0.5-1.5s，是「能听清普通话」的最低可用档，
首次下载也不至于劝退。再小（base/tiny）中文会明显掉字和串词 —— 中文本来就比英文吃模型容量。

| 想要 | 设成 | 大小 | 感受 |
|---|---|---|---|
| 更准（推荐升级档） | `mlx-community/whisper-large-v3-turbo` | ~1.6GB | 中文明显更准；解码层少，M 系芯片上依然快 |
| 最准 | `mlx-community/whisper-large-v3-mlx` | ~3GB | 慢，日常听写不划算 |
| 更快更省 | `mlx-community/whisper-base-mlx` | ~150MB | 中文会掉字，只适合极短指令 |

改法同热键，在 `~/.claude-voice-cn/config.sh` 里加，然后 `restart`：

```bash
export VOICE_MODEL=mlx-community/whisper-large-v3-turbo
```

换完第一次启动会重新下载新权重（旧的不会自动删，要清就删 `~/.cache/huggingface/hub/` 下对应目录）。

---

## 隐私

- 音频只存在于进程内存的 numpy 数组里，**不写盘、不上传**。松开热键转录完即丢。
- daemon 代码里没有任何 HTTP / API key / upload 路径。
- 后台模式下 `daemon.log` 里**会留下每句话的识别文本**（这是排障需要的代价）。它只在本机、不进 git；
  介意就定期删，或者 `stop` 后清掉——注意别把它 cat 进任何会外发的地方。
- 唯一的网络行为是 **mlx-whisper 首次拉模型权重**（Hugging Face）。下完之后想硬性断网，在 `config.sh` 加：

  ```bash
  export HF_HUB_OFFLINE=1
  ```

  之后任何网络访问都会直接报错而不是静默外联。

---

## Pitfalls

| 坑 | 表现 | 解 |
|---|---|---|
| **辅助功能权限没给 / 给了没重启终端** | 进程活着，按热键**毫无反应、也不报错**（pynput 静默失效）。最高频。 | 系统设置 → 隐私与安全性 → 辅助功能，加**终端 App**并打勾，然后 **Cmd+Q 完全退出终端**再重开 |
| 麦克风权限没给 | 按下热键打印「麦克风打开失败」 | 同上面板的「麦克风」项加终端 App |
| 换了终端 App 跑 | 之前好好的，换个终端就哑了 | 权限按 App 授予，不继承。新 App 重新授权 |
| **热键撞输入法切换** | 按住热键时输入法自己在切 / 录不到音 | 别用 Ctrl+Space 和 Caps Lock（macOS 输入法切换默认占用）。默认的右 Option 无冲突 |
| 首次启动像卡死 | 停在「载入模型中…」好几分钟 | 正常，在下 500MB 权重。只发生一次，别 Ctrl+C 打断（打断会留半截缓存，重来更慢） |
| **说话开头被吃掉** | 第一两个字缺失 | 每次按下才开麦（为了不让橙色麦克风灯常亮），开流有 ~100ms 延迟。**按下停半拍再开口** |
| 识别出繁体字 | 输出「這個」而不是「这个」 | 已用 `INITIAL_PROMPT` 引导简体。仍偶发的话，把 `VOICE_PROMPT` 写得更强调简体 |
| 识别成日语/英语 | 短句尤其容易 | 已硬编码 `language="zh"`，不做自动检测。若仍出现是模型太小 → 换 large-v3-turbo |
| **字打不进某些 App** | 终端里好用，VSCode/Chrome 里掉字或一个字都不出 | 已逐字打字 + 8ms 间隔。还掉字就调大：`export VOICE_TYPE_DELAY=0.02`。**完全打不进**通常是那个 App 需要单独的辅助功能授权（部分沙盒 App 会拦模拟事件），换个落点验证一下是不是 App 特例 |
| 打出带 Option 的怪符号 | 出来 `˙´ƒ` 之类 | 松键后修饰键状态没落定。调大 `export VOICE_SETTLE_SECONDS=0.4` |
| 连按两次热键（上一句还没转录完） | 提示「上一句还在转录，本次录音先排队…」，两句都会分别转录打字 | 设计如此，不是丢弃而是排队——两句都会出现，等一下就好 |
| **松开热键后卡死**（终端停在「录音中…」不再有任何反应） | 进程活着但完全没反应，必须 `stop` 才能恢复 | 三次独立事故的病灶都是"pynput 监听线程上跑了一段可能阻塞的同步调用"，已修复；根因链路、每次的具体阻塞点、验证方法见 `INCIDENT-2026-08-hang-on-release.md` |
| **转录结果重复**（同一句话被打两遍，措辞还略有不同） | 明明只按了一次热键 | 多半是前台和后台各起了一个实例，两个都在响应同一个全局热键——已修复单实例检测的盲区，细节同上见 `INCIDENT-2026-08-hang-on-release.md` |
| **session 开着但按热键没反应**（自动拉起时代最高频） | 没有终端窗口可看，完全不知道它是没起来、还在下模型、还是哑了 | 三步定位：① `start.sh status` → 「未运行」= 自动拉起失败，看 `daemon.log.prev`；「尚未就绪」= 还在载模型，等；② 「已就绪」还没反应 → 是权限问题，下一行 |
| **第一个 session 开在没授权的 App 里** | `status` 说「已就绪」，但按键毫无反应；在已授权终端里重开 session 也没用 | daemon 是单例，谁先开谁占坑，且它继承的是**拉起它的那个 App** 的权限。解：`start.sh stop`，然后在**已授权的**终端里 `start.sh start`（或从那儿开 session） |
| 自动拉起「失败」了却没看到任何提示 | hook 只在**进程起来就立刻死**时往 stderr 打一行；权限类是静默失效、模型下载是慢，这两种它探不到 | 按设计如此（不能让 hook 阻塞 session 等模型下完）。用 `status` + `daemon.log` 判断 |
| 停了它又自己回来了 | `stop` 之后开个新 session，daemon 又起来了 | 自动拉起就是这个语义。真要它别回来：`touch ~/.claude-voice-cn/autostart.disabled` |

---

## Verification

装完 + 授权完，按顺序验四条，每条都过才算通了：

1. `bash ~/.claude-voice-cn/start.sh` → 看到 **「就绪。按住 [alt_r] 说话」** = 模型和键盘监听都活了。
   卡在载入 = 还在下模型；报「键盘监听启动失败」= 辅助功能权限没给。
2. **按住右 Option** → 终端打印 **「录音中…」** = 热键监听 + 麦克风权限都通了。
3. 说一句「你好，这是一个测试」松开 → 终端打印 **「识别（0.8s）：你好，这是一个测试」** = ASR 通了。
4. 光标点进另一个窗口（比如 Claude Code 输入框）重复一次 → **中文出现在光标处** = 模拟打字通了。

第 3 步有输出但第 4 步没打进去 → 是打字环节的问题（看 Pitfalls 表里打字那几行），不是识别的问题。这两段分开排查。

**再验自动拉起这一段**（前四条过了之后）：

5. `bash ~/.claude-voice-cn/start.sh stop` → 「已停止」；再 `status` → 「未运行」。
6. 开一个新的 Claude Code session，**session 里不该出现任何语音相关的输出**（有输出说明 hook 配错成了非 autostart 的子命令）。
7. `bash ~/.claude-voice-cn/start.sh status` → 「运行中 pid=… 已就绪」= 自动拉起通了。
8. 再开第二个 session，`status` 里 **pid 不变** = 防重复启动生效（没起第二个抢麦克风的实例）。

---

## Why

- **为什么本地 whisper 而不是云 API**：语音是高敏感数据，Colar 的默认是不出本机（SOUL「数据默认私有」）。
  mlx-whisper 在 Apple Silicon 上跑 small 已经是亚秒级，本地方案没有明显的体验代价。
- **为什么固定 `language="zh"` 而不做自动检测**：whisper 在短句上语言检测极不稳，
  「打开文件」这种三四个字的指令经常被判成日语。这个 daemon 的定位就是中文听写键，写死更可靠。
- **为什么模拟打字而不是往剪贴板塞**：剪贴板方案会覆盖用户正在用的剪贴板内容，而且还要再模拟一次 Cmd+V。
  `pynput` 的 `type()` 在 macOS 上走 `CGEventKeyboardSetUnicodeString`，**直接插 Unicode、不经系统输入法**，
  所以当前是英文还是拼音输入法都不影响中文输出。
- **为什么按需开麦而不是常驻音频流**：常驻会让 macOS 的橙色麦克风指示灯一直亮着 ——
  「它到底什么时候在听」应该一眼可见。代价是开头 ~100ms 延迟，写进 Pitfalls 让人按下停半拍。
- **为什么改成 session 自动后台拉起**（推翻了最初的「前台跑，可见性优先」）：
  最初赌的是「一个前台终端窗口 = 最诚实的状态指示」，但代价是**每次想用语音都得先想起来去开个窗口跑它**，
  而且那个窗口从此不能关、不能拿来干别的。这个摩擦足够大到让人干脆不用了——可见性再好，工具没被启动就等于零。
  所以改成挂 SessionStart hook：**开 Claude Code 就有，不用管终端窗口**。
  拿到方便，付出的代价是**失去「一眼看到它在不在听」**——这是真代价，不是零成本。补偿手段有三个：
  `status` 命令（还能区分「在跑」和「真的就绪了」，靠 `daemon.ready` 标记）、`daemon.log`（每句识别结果都在）、
  以及 macOS 那盏橙色麦克风指示灯（按住热键时才亮，它本身就是「此刻在录」的硬指示）。
  这是一次经过 Colar 明确拍板的权衡，不是无意间漂过去的。
- **为什么是 SessionStart hook 而不是 launchd**：这两件事**不一样**——要的是「跟着 Claude Code session 走」，
  不是「开机常驻」。launchd 会让它在压根不用 Claude Code 的时候也占着麦克风权限和内存，
  而且 launchd 拉起的进程权限归属更难排查（没有一个「父 App」可以去授权）。
  代价是 hook 只管**开**不管**关**：daemon 会活得比 session 久，要停得显式 `stop`。
- **为什么后台化用 shell 的 nohup 而不是 Python 的 daemonize**：`voice_daemon.py` 保持成一个纯前台进程，
  「怎么起、怎么停、在不在跑」整个下沉到 `voicectl.sh`。好处是这两层能各自单独排障——
  前台直接跑 daemon 就能看全部输出，不用先拆掉一层 double-fork。pidfile + `kill -0` + 校验命令行三件套已经够用，
  上真正的 daemonize 库属于为这个规模的东西付不必要的复杂度。

---

## Related

- 上游参考：[jvosloo/claude-voice](https://github.com/jvosloo/claude-voice) —— 只照抄了「语音→文字→模拟打字」这一条链路
- Claude Code 内置 `/voice`：英文听写用它，本 skill 不重复造
