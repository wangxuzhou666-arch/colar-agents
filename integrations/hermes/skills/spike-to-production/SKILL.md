---
name: spike-to-production
description: 把 spike / playground / 调参台里调通的成果搬进产品仓并上线的完整流程，带一道**人工审核 gate**（Colar 肉眼验 playground → 不通过就地打回，通过才进移植 loop）。治四类翻车：① 以为早就搬过了，其实产品里一行没落地 ② spike 与产品的库版本不同却假设像素等价 ③ 资产另起 lane 导致既不入 git 也不上服务器 ④ 拿 headless dump / build 绿当"亲验通过"。Use when: porting tuned render params, shaders, algorithms or pipeline logic from a spike/playground/scratch repo into the product repo and shipping it — or when the ask sounds like "把 playground/调参台的东西上传到线上", "搬渲染核心", "spike 成果进产品".
version: 1.0.0
source: session-derived (2026-08-10)
---

# Spike → Production：调参台成果的移植上线流程

Spike 的价值在"快"——没有类型、没有测试、没有登录、参数直接写死改了就看。
产品的约束在"稳"——SSR、StrictMode、显存、鉴权、构建门、客户可见。

**这两套约束不重叠的部分，就是移植时全部翻车点的来源。** 本 skill 是把 spike 的成果
搬过这条断层的流程，不是"复制粘贴代码"的说明书。

## When to Use

**触发**（命中任一）：
- spike / playground / 调参台里调通了参数或算法，要进产品
- 口语形态："把 playground 上传到线上" · "搬渲染核心" · "spike 那套接进产品"
- handoff 块里的 `DEFAULT_ACTION` 是 `ship_*` / `port_*_to_*`

**不触发**：
- 往 spike 里加新素材、新面料、新版型 → 走 `3d-intake`
- 产品页面打开只剩静态壳、零报错 → 走 `silent-page-debug`
- 纯产品内的功能开发（没有 spike 这一侧）→ 普通开发流程

## 编排形态：一个脚本，两个 phase，人工 gate 卡在中间

`workflow.js`（本目录）把下面的 Procedure 接成了可执行编排。**它刻意不是一条跑到底的
workflow**——Step 5 是人工审核，workflow 停不下来等人看画面，硬塞进去只会得到一个
"假装审过了"的流程。所以切成两段，gate 是两段之间的那道缝：

```js
// ① gate 前：只读勘察 → 产出移植方案（不改任何文件）
Workflow({
  scriptPath: "~/Desktop/colar-agents/integrations/hermes/skills/spike-to-production/workflow.js",
  args: {
    spikeDir:    "/abs/path/to/spike",
    productRepo: "/abs/path/to/product",
    targetFile:  "frontend/src/.../target.tsx",
    phase:       "survey",
    capabilities: [
      { name: "影棚 HDRI", spikeMarker: "RGBELoader|HDRLoader", productMarker: "RoomEnvironment" },
      { name: "四通道 PBR", spikeMarker: "roughnessMap",        productMarker: "roughnessMap" },
    ],
  },
})

// ② 【人工 gate】把 playground 弹给 Colar 肉眼审 —— 不通过就回 spike 改，不往下走

// ③ gate 后：移植 → 并发验证 → 部署前置（仍不执行部署）
Workflow({ scriptPath: "<同上>", args: { ...同上, phase: "port", plan: <survey 产出的方案> } })
```

- `phase="survey"` 并发四路只读勘察（落地状态 / 版本差 / 资产 lane / 目标文件结构）→ 合成方案
- `phase="port"` 单写者移植（同一文件并发改必冲突）→ 并发三路验证（类型构建 / 老资产回归 / 真浏览器亲验）→ 部署前置
- `phase="port"` **不传 `plan` 会直接抛错**——绕过 survey 与人工 gate 正是本 skill 要防的事
- 两个 phase 都**不执行部署**：它输出交给 Colar 的完整命令，人来拍板执行

下面的 Procedure 是这套编排的展开说明，也是不跑 workflow 时手工照做的版本。

## Procedure

### Step 0 — 先问清"从哪搬到哪"，别自己假设

⛔ **这是本 skill 的第一道闸，因为它最容易被跳过。**

"把最新的两个仓库的 playground 上传到线上版本"——这句话里的**每一个名词都可能有二义**：
哪两个仓？playground 指调参台页面本身还是它的渲染成果？"上传到线上"是部署产品还是把
playground 当独立页面挂上去？

猜错的代价是整个 session 的工作量走错方向。**一句话问清，再动手**：

> "我的理解是：把 spike 的 <具体能力清单> 搬进 <目标仓的具体文件>，然后部署。对吗？"

同时确认**目标仓的冻结状态**——目标文件可能正被并发 session 改造。

### Step 1 — 反向核对：产品里到底落地了没有

**不要相信任何人（包括上一个 session 的自己）说"那个已经搬过了"。** 直接 grep 产品仓：

```bash
# 以 three.js 渲染核心为例：把 spike 侧的关键 API 逐个到产品仓里找
cd <产品仓>
grep -nE "RoomEnvironment|HDRLoader|RGBELoader" <目标文件>   # 环境是真 HDRI 还是程序化假房间
grep -nE "roughnessMap|aoMap|normalMap" <目标文件>            # 通道接了几个
grep -nE "sheenRoughness|toneMapping|Exposure" <目标文件>     # 是常量还是分档
grep -nE "getMaxAnisotropy|anisotropy" <目标文件>             # 硬编码还是取硬件上限
```

**本次实测结论：产品里一行都没落地。** 亲验过的四通道 / 影棚 HDRI / 两步染色全在 spike，
产品仍是 `RoomEnvironment` + 程序化法线 + 无 roughnessMap/aoMap + `sheen` 常量。

> **教训**：在一个"还没接上核心"的场景里调参，是在空场景上调——所以**移植必须排在
> 任何新画质特性之前**。先确认落地状态，再决定这个 session 干什么。

### Step 2 — 版本对齐：不能假设像素等价

Spike 和产品的库版本几乎一定不同（spike 是某天 npm 装的，产品有 lockfile）。

```bash
grep -E '"three"|"<你的库>"' <产品仓>/frontend/package.json
# 逐个查 spike 用到的 API 在产品版本里是否还在 / 是否已废弃
ls node_modules/three/examples/jsm/loaders/ | grep -iE 'rgbe|hdr'
head -5 node_modules/three/examples/jsm/loaders/RGBELoader.js   # 是真身还是废弃转发壳?
grep -n "NeutralToneMapping" node_modules/three/src/constants.js
```

本次实例（three r180 spike → r185 产品）：
- `RGBELoader` 已是 `@deprecated r180` 的转发壳，真身是 `HDRLoader` → **移植时直接用真身**
- `PCFSoftShadowMap` 在 r185 会刷废弃警告并静默降级 → **保留产品侧已改好的 `PCFShadowMap`，别把 spike 的抄回来**
- `environmentRotation` / `NeutralToneMapping` 两个都在 → 可以直接用

> ⚠️ `node -e "require('three/package.json')"` 会因 exports 限制报 `ERR_PACKAGE_PATH_NOT_EXPORTED`。
> 查版本读 `package.json` 的依赖声明，查 API 直接看 `node_modules/` 的源码。

### Step 3 — 资产 lane：对齐仓内既定 convention，别造新的

Spike 的资产（贴图 / HDRI / 模型）通常是散在本地的孤本。搬进产品前先看**仓里已有的同类资产
走的哪条 lane**，对齐它——这是 convention 问题，不是需要新拍板的决策。

```bash
grep -nE "public/(blocks|fabrics|artworks)" <产品仓>/.gitignore   # 本体入不入 git
grep -nE "exclude.*public" <产品仓>/scripts/deploy/sync.sh        # 部署同不同步
```

本次 lane（可直接抄的形态）：**本体不进 git（整目录挡）+ 清单与缩略图进 git（白名单放行）+ 随 rsync 上服务器**。

新建同类目录时**记得补一条 .gitignore**——白名单式的挡法只挡了已知的三个目录，
新加的 `public/hdri/` 不补规则的话 5MB 的 `.hdr` 会直接进 git 历史，`clone` 体积永久回不去。

**体积控制**（务必在搬之前做，别把 spike 的原始体积原样搬进产品）：

```bash
# 法线/粗糙/AO 是细节通道，平铺 4-8 次后每次只占屏幕一小块，1K 完全够
sips -Z 1024 -s format jpeg -s formatOptions 85 <src>_NormalGL.jpg --out <dst>/normal.jpg
# albedo 保 2K：它是视觉主体，还要走染色管线
sips -s format jpeg -s formatOptions 88 <src>_Color.jpg --out <dst>/color.jpg
```
> 实测：2K 法线图即使 q85 仍 6.2MB，降 1K 只要 0.8MB，肉眼无差。四套面料 79MB → 19MB。

**命名去溯源**：图库资产的原始编号（`Fabric036` 这类）直接搜就能溯源。搬进**产品线上清单**
时一律改中性名（`linen-plain` / `denim-twill`）——这不是额外工作，是命名选择，
省掉以后回来 scrub 线上资产的一整轮。

### Step 4 — 移植成"纯加法"，不破坏老资产的现状

Spike 里所有资产都是新形态（如全是四通道白坯），产品里却有一大批老资产（如几十张单通道
成品照片）。**直接把 spike 的管线无条件套上去必然破坏老资产**——本次的具体形态是：
两步染色是给白坯用的，套到已染色的成品面料照片上会把它们全部乘暗。

正确做法是**让新能力由资产自己声明**，缺省即老行为：

```jsonc
// manifest 里新增三个可选字段，老条目一律缺省 → 走原路径，行为逐字节不变
{
  "id": "linen-plain",
  "file": "linen-plain/color.jpg",
  "maps":    { "normal": "…", "rough": "…", "ao": "…" },  // 有 maps 才接四通道
  "dyeable": true,                                         // 白坯才走染色
  "look":    { "rough": 0.85, "sheen": 0.35, "sheenRough": 0.90 }  // 每种料的表面性格
}
```

同时把 spike 里**写死的常量升级成分档**：一套 sheen 参数走遍全库（按丝绸配的）会让亚麻和
牛仔都带着化纤反光。

### Step 5 — 🚧 人工审核 gate（Colar 肉眼验，不通过就地打回）

⛔ **本 skill 的核心闸门。审核未通过，不进后续 loop、不 commit、不部署。**

顺序是**先在 spike playground 上验、后移植**——playground 改一个数就能看，产品里改一次
要过构建。别把调参放进产品仓做。

```bash
# spike 侧：起本地服务，把 playground 弹给 Colar
open "http://localhost:8765/playground-3layer.html?block=blocks/<某件>.glb"
```

弹给 Colar 时**必须明说三件事**，否则他没法审：
1. 这次改了什么（一句话，不是 diff）
2. 该看哪里（"看裙子主料的织纹有没有透过印花"，不是"你看看"）
3. 哪些是我自测过的、哪些**没验过**（如 `?shot=` 出图、URL 参数覆盖 —— 我改完自测但他没逐一过目）

**判定**：
- ❌ 不通过 → **回 Step 4 在 spike 里改**，改完重新弹。不要带着"回头产品里再调"的想法往下走
- ✅ 通过 → 记下"他确认通过的是哪个 URL / 哪组参数"，那就是移植的验收基准

> 为什么必须是人工：画质、观感、"零件像浮着"这类判断没有自动化判据。本次 Cycles 离线渲染
> 那条线就是被 Colar 一句"两者没什么区别、时间成本不划算"直接判死的——机器给不出这个结论。

### Step 6 — 产品侧亲验：必须是真浏览器跑完整路径

**build 绿 ≠ 跑得起来。** 移植后必须在真浏览器里走一遍完整交互路径。

```bash
# 产品有登录墙、目标板块进不去时：临时路由挂载目标组件（验完即删，别进 commit）
# 前提：该板块是零后端的纯前端组件，脱开登录态也能完整跑
cat > src/app/verify-tmp/page.tsx <<'EOF'
"use client";
import { TargetTab } from "../<真实路径>/target-tab";
export default function T() { return <div className="flex h-screen flex-col"><TargetTab /></div>; }
EOF
```

用 playwright（产品仓通常已有）驱动真实点击 + 截图 + 抓 console：

```js
const browser = await chromium.launch({
  args: ["--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader"],  // WebGL 必需
});
page.on("pageerror", e => errors.push(e.message));
page.on("requestfailed", r => errors.push(r.url()));
// …点开目标 → 选素材 → 改参数 → 每步 screenshot
// 画布还活着吗：gl.isContextLost() 必须是 false
```

**验完删临时路由并确认**：`git status --short` 里不能有它。

⚠️ **scratchpad 里的脚本 import 不到产品仓的 node_modules**，用 `createRequire("<产品仓>/frontend/")`。

### Step 7 — 四道门 + commit

```bash
git add <明确列出你的文件>     # 别 git add -A：并发 session 的 dirty 文件会被你带走
git commit -F - <<'EOF'
…
EOF
```

⚠️ **pre-commit hook 可能跑全量测试（本次 pytest 2260 项 / 302 秒）**。
Bash 超时给足 **10 分钟**，否则 commit 会在测试跑到一半时被 SIGTERM 掉。

### Step 8 — 部署 + 汇报部署状态

部署前先量清楚**这次实际推上线的增量**——线上可能已经跑在同一条分支上：

```bash
ssh <server> "cat /opt/<app>.DEPLOYED_VERSION"        # 线上当前 head_commit
git log --oneline <线上commit>..HEAD                   # 真正的增量
ssh <server> "df -h /opt | tail -1"                    # 新资产放得下吗
bash scripts/deploy/update.sh --host <档名>
```

> **生产部署可能被安全策略拦下**（本次即被 auto-mode classifier 拒）。**不要绕**——
> 把完整命令交回 Colar 跑，并附上"前置条件已验完"的清单（四道门 / commit / 磁盘 / 增量范围）。

收尾必附一行**部署状态**：`本地未commit / 已commit未push / 已push待build / 线上已生效`，
并说清哪个 URL 对应哪个环境。

## Pitfalls

本次实际踩到、下次还会踩的：

| 坑 | 表现 | 解 |
|---|---|---|
| **包围盒含隐藏件** | 单品明显偏在画面一侧、还被推远 | `Box3.setFromObject` **不看 visible**。只 `expandByObject` 判为可见的 mesh，全隐藏时退回全量盒 |
| **资源缓存只 set 不 dispose** | 翻十几块素材后显存吃满（每套约 67MiB） | LRU 上限 + **驱逐即 dispose**；当前使用的永远是最后 set 的，不会被驱逐 |
| **StrictMode 双挂载 + 陈旧回调** | 晚到的异步回调往已 cleanup 的对象上写 | 每个异步链加 `cancelled` 闸；用 `ref` 存"当前选中的是谁"，回调里比对（读 state 拿到的是发起那刻的旧值） |
| **anisotropy 硬编码** | 斜视角织纹糊 | `renderer.capabilities.getMaxAnisotropy()` |
| **cleanup 里读 `ref.current`** | lint 报错，且那时它可能已指向别处 | effect 体内先锁一份局部变量 |
| **render 期间写 ref** | `Cannot access refs during render` | 挪进 `useEffect` |
| **headless dump 当证据** | grep 命中的是 `<script>` **源码**不是渲染态 | 只信截图 / `isContextLost()` / 真实点击路径 |
| **读用户表找测试账号** | 被安全策略拦 | 不绕。改用临时路由验（零后端板块）或交回 Colar |
| **`timeout` 命令不存在** | macOS 无 GNU timeout | 用 `ssh -o ConnectTimeout=10` 或 `gtimeout` |
| **`git add -A`** | 把并发 session 的 dirty 文件一起 commit | 显式列文件 |

## Verification

移植完成的判据（缺一不可）：
- [ ] Step 1 的反向 grep 现在全部命中新实现
- [ ] `tsc --noEmit` + `eslint <改动文件>` + 仓库四道门全绿
- [ ] 真浏览器走完整路径，`isContextLost() === false`，无 pageerror
- [ ] 新旧资产各验一件：**老资产行为逐字节不变**，新资产走新管线
- [ ] `git status` 干净（临时路由已删、大资产被 ignore、只有清单与缩略图入库）
- [ ] Colar 在 Step 5 认可的观感，在产品里复现

## Why This Skill Exists

2026-08-10 的 session：织锦 3D 换料要把 spike 调参台的渲染核心搬进产品并上线。

一个 179-agent 的 expert panel 跑出的最重发现**不在议题内**——产品的 `view3d-canvas.tsx`
至今仍是 `RoomEnvironment` + 程序化法线 + 无 `roughnessMap`/`aoMap` + `sheen` 常量 0.6，
即 Colar 亲自验收过的四通道 / 影棚 HDRI / 两步染色，**在产品里一行都没落地**。

也就是说：亲验通过 ≠ 已上线。中间这段"移植"没有流程，就会静默地一直不发生，
而所有人（包括 AI 自己）都以为它早就做完了。本 skill 就是把这段补上，
并在中间钉死一道人工审核 gate——因为画质这类判断，机器给不出结论。

## Related

- [3d-intake](../3d-intake/SKILL.md) — 上游：素材怎么进 spike（本 skill 是它的下游"进产品"那半段）
- [silent-page-debug](../silent-page-debug/SKILL.md) — 移植后页面只剩静态壳、零报错时走它
- [nextjs-hmr-proactive-restart](../nextjs-hmr-proactive-restart/SKILL.md) — 移植期批量改文件后 dev server 不刷新
