---
name: silent-page-debug
description: "浏览器页面打开后只剩静态壳（JS 功能全无）、又零报错时的诊断阶梯。专治 <script type=\"module\"> 的静默死：module 的 import 失败（依赖 404 / CDN 断 / importmap 被拒 / 依赖不闭包）只在 script 元素上发 error 事件——无 src、无 message，常规 window.onerror 抓不到，页面表现就是「原始兜底 UI 完好，什么都不发生」。诊断顺序：装三件诊断装备（报错上屏 + 启动脚印 + 标题信标）→ 自建日志服务器看请求序列（最硬证据）→ AppleScript 读标题信标（不靠用户截图）→ 干净 profile 对照分流 → vendor 依赖闭包检查。Use when: a static HTML page loads but its JS silently never runs — pristine fallback UI, zero errors, query-param auto-load does nothing — especially pages using ES modules, importmaps, or vendored libraries; or when debugging any \"works in headless but not in the user's browser\" split."
version: 1.0.0
source: session-derived (2026-08-10)
---

# silent-page-debug — 页面 JS 静默死的诊断阶梯

**一句话心智模型**：classic 内联脚本活着、module 没跑 = 死在 **import 层**；import 失败的 error 事件落在
script **元素**上（inline 的话无 src 无 message），`window.onerror` 常规写法抓不到——所以「零报错」本身就是关键线索，
而破案最快的路不是猜，是**让页面自己报进度 + 看服务器日志里谁没被请求 / 谁 404**。

## When to Use

**触发**
- 页面打开只剩静态兜底 UI（拖拽框 / 空壳），JS 交互全无、console 又看不到或没人看
- `?param=` 自动加载类功能「没反应」，刷新 / 换缓存 / 换端口都一样
- 「headless / 别人机器上好好的，用户浏览器里不行」的分裂现场
- vendor 化 / 换 CDN / 改 importmap 之后页面突然全哑

**不触发**
- console 里明晃晃有报错（直接修即可，用不上阶梯）
- Next.js dev server 的 HMR / chunks 404 类症状（走 `nextjs-hmr-proactive-restart`）
- 页面能跑但渲染结果不对（那是业务 bug，不是启动死）

## Procedure

### 1. 装三件诊断装备（一次性投入，长期收益；修完留在页面里）

**a. 报错上屏兜底** —— classic script，放在 `<body>` 兜底 UI 之后、任何 module 之前：

```html
<script>
(function () {
  document.title = "PG:js-alive";   // 信标起点：证明"页面 JS 到底跑没跑"
  function show(msg) {
    var el = document.querySelector("#drop .box");   // 换成本页兜底容器
    if (el) el.innerHTML = "<h2>页面初始化失败</h2><p style='word-break:break-all;color:#b33'>"
      + String(msg).replace(/[<>]/g, " ") + "</p><p>截图给 Claude。</p>";
  }
  addEventListener("error", function (e) {
    // ⚠️ inline module 的 import 失败 = 元素级 error、无 src 无 message —— 这个分支绝不能丢
    if (e.target && e.target !== window)
      return show("元素级: <" + e.target.tagName + "> " + (e.target.src || e.target.href || "inline"));
    if (e.message) show(e.message + " @ " + (e.filename || "?") + ":" + (e.lineno || "?"));
  }, true);
  addEventListener("unhandledrejection", function (e) {
    show("Promise 未捕获: " + (e.reason && (e.reason.message || e.reason)));
  });
})();
</script>
```

**b. 启动脚印 + c. 标题信标** —— module 里每过一站打一行（页面角落可见 + 写进 `document.title` 供无截图读取）：

```js
const bootEl = document.createElement("div");
bootEl.style.cssText = "position:fixed;left:8px;bottom:8px;z-index:99;font:11px monospace;color:#98a;white-space:pre";
document.body.appendChild(bootEl);
const boot = (m) => { bootEl.textContent += m + "\n"; document.title = "PG:" + m; };
boot("1 imports ok");            // module 第一行（import 之后）
// …renderer / 场景 / UI 各站后： boot("2 renderer ok") … boot("7 model on stage")
// 成功终点： setTimeout(() => bootEl.remove(), 5000)
```

读法：标题停在 `PG:js-alive` = classic 活、module 没启动（import 层）；停在 N = 死在 N→N+1 之间。

### 2. 服务器侧取证（最硬证据，优先于一切浏览器侧猜测）

自建一个**自己读得到日志**的静态服务器（别动共享的那个），从它加载页面：

```bash
cd <page-dir> && nohup python3 -m http.server 8766 > /tmp/srv8766.log 2>&1 &
# 浏览器开 http://localhost:8766/<page>?cb=$(date +%s) 后：
cat /tmp/srv8766.log
```

判读：**某文件 404** = 依赖缺失（本 skill 诞生 session 的真凶就是一条 `GET /vendor/three.core.js 404`）；
**HTML 之后 js 压根没被请求** = import 图更早处断（importmap 被拒 / 更上游 404）；
**全 200 仍死** = 执行层问题（TDZ / 运行时炸），回信标看停在几号。

### 3. AppleScript 读标题信标（用户浏览器内实测，不消耗用户截图往返）

```bash
CB=$(date +%s); osascript -e "
tell application \"Google Chrome\"
  tell front window
    make new tab at end of tabs with properties {URL:\"http://localhost:8766/<page>?cb=$CB\"}
  end tell
  delay 15
  set out to \"\"
  repeat with w in windows
    repeat with t in tabs of w
      if (URL of t) contains \"<page>\" then set out to out & (title of t) & linefeed
    end repeat
  end repeat
  return out
end tell"
```

注意：另一个 `--user-data-dir` 的 Chrome 实例在跑时 AppleScript 会指错实例（报「无效的索引」）——先 `pkill -f "user-data-dir=.*<临时目录>"` 再试。无痕窗口创建后常读不回句柄，别依赖。

### 4. 干净环境对照（分流「页面自身 vs 用户 profile」）

```bash
# 可见窗口 + 全新空白 profile（无扩展、无站点设置），开在用户屏幕上
open -na "Google Chrome" --args --user-data-dir=/tmp/fresh-profile --no-first-run "<url>"
```

干净环境活、主 profile 死 → 才轮到查扩展 / 站点设置；两边都死 → 页面自身问题，别浪费时间怀疑环境。

### 5. vendor 依赖闭包检查（vendor 化时必做，防自埋雷）

```bash
# 递归看 vendor 文件还 import 什么，直到闭包
grep -rh "from '" vendor/ | grep -v "from 'three'" | sort -u
```

已知的转发壳（漏了必 404）：three r167+ 的 `three.module.js` → `./three.core.js`；`RGBELoader.js`（268 字节）→ `./HDRLoader.js`。
jsdelivr 对 npm 包的 .js 默认返回 minified 版，体积对不上别慌，`node --check` 过即可。

## Verification

修复后信标应走到终点站（如 `PG:7 model on stage`），Step 3 的 osascript 可无人值守确认——不需要用户再截一张图。

## Pitfalls（假证据清单——本 skill 一半的价值在这）

| 假证据 | 真相 | 解 |
|---|---|---|
| headless `--dump-dom` 输出里 grep 到了目标字符串 | dump 会把 `<script>` **源码**原样序列化进输出，命中的可能是源码文本不是渲染态 | 判据只用**运行时才存在**的字符串（如拼接结果 `three 180`，而非源码 `"three " + THREE.REVISION`） |
| `--virtual-time-budget` 下 dump 无脚印 | 虚拟时间与真实网络的时序互动，dump 可能早于 module 执行 | headless 结论只作参考，元凶必须有服务器日志或信标级证据 |
| dump 里有 `<canvas>` / 某 `<h2>` 就当"已渲染" | 静态 HTML 里可能本来就有同名元素 | 先 grep 源文件确认该元素是不是静态自带 |
| 报错兜底零输出 = 没有错误 | inline module 的 import 失败是元素级 error（无 src 无 message），常规分支会静默丢弃 | 兜底必须带元素级分支（见 Procedure 1a） |
| `node --check` 过了 = 代码没问题 | TDZ（声明被挪到使用之后）是合法语法、运行时才炸 | 信标 + 兜底抓运行时；review 时盯 const 声明顺序 |
| 修了一个 bug 症状不变 = 没修对 | 可能**两层雷叠着**（本 skill 诞生 session：TDZ + three.core.js 404 前后叠层） | 每修一层重跑 Step 2/3 取证，别靠症状反推 |
| curl CDN 通 = 浏览器侧 CDN 通 | 终端与浏览器的 DNS/代理路径可以不同 | 干脆 vendor 本地化，消灭该变量（记得 Step 5 闭包检查） |

## Why This Skill Exists

2026-08-10 织锦 3D playground「每次打开都是拖拽框」连环现场：先后怀疑并排除了浏览器缓存、jsdelivr CDN、
扩展注入 importmap 被拒、站点 JS 设置——期间 headless 假证据两次把结论带偏（源码文本当渲染态、静态元素当运行时产物）。
真相是两层雷叠着：上个 session 的 TDZ（`weaveCanvas` 用在声明前）+ 本 session vendor 化漏了 `three.core.js`。
最终破案靠的不是浏览器侧任何猜测，而是自建日志服务器里一条 404 + 标题信标读出 `PG:js-alive` 停站。
教训固化为本阶梯：**先装信标、再看服务器日志，猜测放最后。**

## Related

- [3d-intake](../3d-intake/SKILL.md) — 本 skill 的诞生现场；其 Pitfalls 表的「three.js 走 CDN importmap」行是本阶梯的一个特例
- [nextjs-hmr-proactive-restart](../nextjs-hmr-proactive-restart/SKILL.md) — dev server 侧的假 200 / 卡加载症状（不同层，别混用）
