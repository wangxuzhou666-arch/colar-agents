---
name: spike-to-production
description: "把 spike / playground / 调参台里调通的成果搬进产品仓并上线的完整流程，带一道**人工审核 gate**（Colar 肉眼验 playground → 不通过就地打回，通过才进移植 loop）。治四类翻车：① 以为早就搬过了，其实产品里一行没落地 ② spike 与产品的库版本不同却假设像素等价 ③ 资产另起 lane 导致既不入 git 也不上服务器 ④ 拿 headless dump / build 绿当\"亲验通过\"。Use when: porting tuned render params, shaders, algorithms or pipeline logic from a spike/playground/scratch repo into the product repo and shipping it — or when the ask sounds like \"把 playground/调参台的东西上传到线上\", \"搬渲染核心\", \"spike 成果进产品\"."
version: 1.1.0
source: session-derived (2026-08-10)；v1.1.0 (2026-08-17：补第四类资产「环境贴图/HDRI 降宽度」判据 + 机械门自身的可测性与 mutation 验证 + 烘焙管线的 HMR 陈旧模块反查 + 「拿历史产物当对照组」的归因错误 + 「指标量错会得出反结论」；并在 When to Use 划清边界——产品仓内 A/B 定参没有 spike 侧，workflow.js 缺 spikeDir 会抛错，该按需读局部而非跑编排)
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
- **直接在产品仓里做 A/B 定参**（改渲染常量 → 用产品自己的烘焙管线出图 → 肉眼选档）
  → 也不触发。它长得很像本 skill 覆盖的事，但**没有 spike 那一侧**：没有版本差要对齐、
  没有资产要换 lane、Step 1 的"反向核对落地状态"无对象。`workflow.js` 硬要求
  `spikeDir/productRepo/targetFile`，缺一个直接抛错——**别为了满足 schema 编一个
  `spikeDir` 出来**，那是在骗过自己的门。
  这类工作真正该复用的是本 skill 的**局部**：Step 3 的体积压缩判据与机械门、Step 4c 的
  重烘与 HMR 反查、Step 5 的人工 gate。按需读那几段，不必跑编排。

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

**体积控制**（务必在搬之前做，别把 spike 的原始体积原样搬进产品）。

下面四类资产**各有各的做法，不能互相代替**——它们的消费路径不同，所以压法也不同。
（这不是全集：面料主图、字体、图稿等还没定压缩口径，遇到新类别按同样的思路先问
"它怎么被消费" 再定压法，别硬套最像的那一类。）

**① 平铺贴图（albedo / normal / rough / ao）→ 降分辨率**

```bash
# 法线/粗糙/AO 是细节通道，平铺 4-8 次后每次只占屏幕一小块，1K 完全够
sips -Z 1024 -s format jpeg -s formatOptions 85 <src>_NormalGL.jpg --out <dst>/normal.jpg
# albedo 保 2K：它是视觉主体，还要走染色管线
sips -s format jpeg -s formatOptions 88 <src>_Color.jpg --out <dst>/color.jpg
```
> 实测：2K 法线图即使 q85 仍 6.2MB，降 1K 只要 0.8MB，肉眼无差。四套面料 79MB → 19MB。

**② 列表缩略图 → 转 WebP**（不是降分辨率的问题，是**格式选错**的问题）

素材库列表**一进页面就把全部缩略图拉一遍**，而 PNG 存布料/材质这种照片类内容效率极低。
关键不只是字节数，还有**请求数**：浏览器单域名并发 6 个，几十张要排好几轮，跨境每轮
RTT 200-300ms，慢在往返次数上而不是带宽上。症状是「图片加载不出来」（其实一张张慢慢冒）。

> 织锦实测：47 张 242×256 的 RGBA PNG，单张 43-138KB，合计 4.16MB；转 WebP q85 后 0.54MB
> （7.7×），alpha 逐像素无损（最大差 0）。q90 只多 4KB 却看不出差别，所以 q85 是甜点。

**最好的做法是让导入路径直接落 WebP**，而不是事后批处理——事后批处理要人记得跑，
漏一次就把体积悄悄加回去且不报错。织锦的形态：`scripts/assets/fetch_fabrics.py` 下载完
官方 PNG 就地转 WebP 只留 WebP，批处理版 `frontend/scripts/compress-thumbs.mjs` 退居存量补救。

**③ GLB 模型 → KTX2 纹理 + meshopt 几何**（体积大头几乎总在贴图，不在网格）

CLO / Blender 导出的 GLB 会把 4K PNG 原样嵌进去，而 **gzip 对已压缩的 PNG 完全无效**——
以为开了压缩其实等于没开。先量清楚贴图占比再动手：

```bash
# 一件 48.6MB 的裙子：贴图 35.6MB（73%），几何只有 12.9MB
node <产品仓>/frontend/scripts/compress-blocks.mjs <in.glb> <out.glb> --normal=uastc2k
```

工具链：纹理走 `basisu`（`brew install basis_universal`），几何走 `gltfpack -c`。
注意 **npm 版 gltfpack 不带 BasisU**（node 构建阉割了），所以纹理必须另外用 basisu 编，
不能指望 `gltfpack -tc`。分档：baseColor 用 ETC1S q255，normal 用 UASTC 2K，
metalRough 内容通常极平坦可直接降到 1K。

> 织锦实测：48.6MB → 7.8MB（6.3×），**渲染成品** PSNR 45.8dB（>40 即肉眼不可辨）。
> 注意贴图层 PSNR 只有 36dB 而成品有 45.8dB——光照、UV 采样、mipmap 会把纹理层的
> 压缩噪声大幅平均掉，所以**别拿贴图层的 PSNR 判画质，要拿渲染成品判**。

⚠️ **两个扩展会进 `extensionsRequired`**：产品侧的 loader 不接 `KTX2Loader` +
`MeshoptDecoder` 的话，是**整件载入失败**而不是画质降级。transcoder 的 wasm 要从
`three/examples/jsm/libs/basis/` 拷进 `public/basis/`，漏了就是 404 → 模型全黑。
封面/截图这类 headless 流水线若复用产品渲染核心，会自动继承，不用另外改。

**⚠️ 材质名是契约**：若产品侧按材质名做槽位映射（换料、隐藏配件），压缩链里任何会重命名
或合并材质的步骤都会静默断掉映射。`gltfpack` 必须带 `-km -kn`（保材质名/节点名），
且压缩脚本应当**逐字比对压缩前后的材质名，不一致就抛错**。

**④ 环境贴图 / HDRI → 降宽度**（判据不是体积，是**它喂给 PMREM 的 cube 边长**）

影棚 HDRI 几 MB 起步，而且是**每次进 3D 面板必拉**的那种。容易被跳过，因为「反正
PMREM 会把它预过滤成模糊光照探针」听起来像是分辨率无所谓——**不成立**。three 的
`PMREMGenerator._fromTexture` 对等距柱状图走 `_setSize(width / 4)`，于是
`cube = 2^floor(log2(宽/4))`：2048→512、1024→256、512→128。**降宽度就是在降反射
mip 链的基底分辨率**，直接决定低粗糙度表面的高光锐度。

```bash
python3 <产品仓>/scripts/assets/downsample_hdri.py <src.hdr> --out /tmp/x.hdr && mv /tmp/x.hdr <dst>
```

- 缩放**必须用盒式平均**（`cv2.INTER_AREA`）：能量守恒，整场曝光才不漂。双线性/双三次
  在大比例缩小时会漏采样，可能把小而亮的光源直接采丢。
- 校验读**回来**的那份而不是内存里的：写盘要过一遍 RGBE 量化。看两个数——平均亮度漂移
  （曝光会不会变）和峰值（动态范围有没有被截断）。
- 定档判据是**烘封面并排比高光**，不是省了多少 MB。织锦实测 2048→1024：体积 5.21MB→1.35MB，
  平均亮度漂移 0.000%，峰值 109→102.9；差异只出现在低粗糙度处（漆皮的高光带、金属铆钉的
  闪点），亚麻垂坠与印花几乎零变化。再降到 512 时高光带明显变宽变亮，所以停在 1024。
- ⚠️ **别把 GLB 那条 45.8dB 验收线套过来**：那是块状压缩伪影，这是平滑的高光位移——
  同样 PSNR 下后者对眼睛宽容得多。跨资产类型搬判据会误杀。

**别只靠人记得跑**：四类压缩都该有机械门兜底。织锦的分法——缩略图进 git，拦在 pre-commit；
GLB 与 HDRI 不进 git（唯一上线路径是部署 rsync），拦在 `update.sh` 预检
（`scripts/check_assets_compressed.py`，两处共用同一份逻辑）。

**新加的门，自己也要能变红**——否则你只是把「没人检查」换成「有个东西声称检查过」：

- **静默放行是这类门最毒的失效**，不是误报。解析器返回 `None`、路径拼错、目录不存在，
  表现全都是「零条错误、退出码 0」，和「资产确实都合规」一模一样。所以判不出来时要
  **出声（warning）而不是放过**。
- 补测试后**跑 mutation 验证它真能红**：把解析器改成恒返回 `None`、把阈值常量改掉、
  把硬拦降级成只警告——三种破坏各自要有测试精准变红。写完就绿不是证据。
- ⚠️ **门常常压根没法测，原因是结构性的**：驱动代码写在模块级的话，`import` 它就会把
  整道门跑一遍并 `sys.exit`。**先把驱动收进 `main()` 再谈补测试**，顺序反了会卡住。
- 阈值常量若在两个文件里各写一遍（门的上限 / 压缩脚本的默认值），**加一条测试锁住它们相等**。
  注释里互相声称"同一个数"正是最会漂的那种，漂了的症状还很隐蔽：按脚本默认值压完，门依然报红。

**压缩脚本的中间产物不能落进被 rsync 的资产目录**（含 `.orig` 备份）。`rsync` 不读
`.gitignore`——留在那儿的原件会跟着部署上生产机，正好把省下的体积原样还回去，而且
后缀变了以后连压缩门都扫不到它。照 GLB 那条的形态写「输出到 `/tmp` 再 `mv` 回去」，
并在脚本里加一条守卫**拒绝 `--out` 落进该目录**。

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

### Step 4b — 资产专用规则搬了，规则针对的资产也得搬

移植清单里凡是**针对某个具体资产**的常量、覆盖表、白名单（"这件的明线材质叫 `0.1_2998`"、
"这件的衣架挂钩要隐藏"），都要回答一句：

> **它针对的那件资产，在目标仓里吗？**

不在 = 这条规则匹配不到任何东西，等于没搬；更糟的是它看起来像搬过了。本次就栽在这儿：
针对某条裙子的两条槽位覆盖进了产品代码，裙子本身还留在 spike，直到 Colar 问
"为什么没把裙子也部署上去"才发现。

```bash
# 逐条自查：覆盖表里的 key 是资产名/材质名时，去目标仓找那件资产
grep -oE '"[^"]+"\s*:\s*"(keep|off|alt)"' <目标文件>     # 列出所有资产专用 key
ls <产品仓>/frontend/public/blocks/                       # 对照库里有什么
```

搬资产时**顺带跑一遍这些规则的验证**——本次把裙子搬进去后，挂钩确实消失了、麂皮腰带确实
保留了原材质，这才算证明覆盖表真的在工作，而不是"写了但从没被触发过"。

### Step 4c — 封面 / 缩略图：跟着渲染核心一起重烘

渲染核心一换，库列表里的旧封面就成了历史遗留——它们是**上一套光**烘的，与用户点进去看到的
不是一回事。重烘要点：

- **用产品自己的渲染器出图**（驱动真实组件 + 截 canvas），不要另建一套烘焙管线，否则封面
  与实物又会分叉
- **构图对齐一套规则**：方画幅、按内容包围盒居中、留白比例固定（本次 `max(w,h)*1.22`），
  整个库看起来才是一套
- ⚠️ **"歪"的根因通常不是机位代码，是资产的建模朝向**。外来资产被导出时朝哪边纯属偶然，
  所以"正面机位"不能假设 yaw=0 就对着正面 → 给 manifest 加一个逐件标定的朝向修正字段：

```jsonc
{ "id": "…", "file": "….glb", "yaw": -35 }   // 缺省 0 = 老行为不变
```

  **标定方法：穷举实测，别从拖拽角度反推。** 本次在这上面赔了两轮——先用 playwright 拖拽
  转一圈截图，看出"累计转到 60° 时是正面"，就把 `yaw: 60` 写进 manifest，结果是侧面；
  改 `-60`，结果是背面。**拖拽累计的 azimuth 和 `manifest.yaw` 不是同一个量**（基准不同、
  符号可能相反、旋转量还受 `rotateSpeed` 与容器宽度影响），中间隔着的假设太多。

  让被测的量就是最终生效的那个量：

```js
// 逐个写 manifest.yaw → reload → 点进版型 → 截图；探测完必须还原 manifest
for (const yaw of [0,45,90,135,180,225,270,315]) {
  const d = JSON.parse(orig);
  for (const b of d.blocks) if (b.id === BLOCK_ID) b.yaw = yaw;
  fs.writeFileSync(MANIFEST, JSON.stringify(d, null, 2) + "\n");
  await page.goto(TMP_ROUTE, { waitUntil: "networkidle" });
  // …点进去、等载入、藏 UI、截图
}
fs.writeFileSync(MANIFEST, orig);   // 不还原的话，最后一个探测值会被当成标定值留在仓里
```

  拼成网格图，肉眼选出正面那一格，再把那个角度单独写进 manifest。

- 颜色**必须由人在真 GPU 上定**（headless 的 swiftshader 有色差），构图和"跑不跑得起来"
  才可以 headless 自判

⚠️ **烘焙管线跑在 dev server 上时，改了参数不等于烘出来的图用了新参数。** 烘图脚本驱动的是
`localhost:3000`，吃的是 HMR 后的模块——HMR 没把改动应用上（或应用了一半），脚本会拿着
**旧参数**出图并照常打印 `✓ 完成`。这比构建失败危险得多：你拿到一张看起来没问题的图，
并据此做了画质判断。

**做法：烘完反查参数确实生效，别信脚本的成功退出码。** 挑一个改动会单调影响的量直接测——
改曝光就量衣服像素均值，改底色就量角落像素值：

```python
# exposure 0.65 → 0.45，预期 sRGB 亮度比 ≈ (0.45/0.65)^(1/2.2) = 0.845
# 实测 0.885（neutral tone mapping 不是纯 gamma 2.2 + 高光压缩），关键是**明显不等于 1.0**
```

比对要用 **finalize 之前的源图**：成品图已经被换底色、裁切、缩放动过，这些会把信号淹掉。
判据是"有没有朝预期方向动"，不是"是否精确等于理论值"——理论值本来就依赖 tone mapping 曲线。

⚠️ **另一个方向的误判**：拿"新烘的封面 vs 仓里那张旧封面"的差异去归因某个参数，会把
**旧封面烘制之后所有渲染向 commit 的影响**一起算进去。织锦实测：同源两档对比 49.4dB，
而新旧对比只有 36.3dB——差额全来自旧封面烘完之后那 6 个渲染 commit，跟当前改的参数无关。
**要归因单个参数，就用同一张源图跑两遍**，别拿历史产物当对照组。

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
> Colar 显式拍板后再跑就不会被拦，所以顺序是：先给命令+依据，拿到授权，再执行。

**部署脚本自己的 fail-closed 门可能拦下你**（本次是"工作树干净门"：有未提交文件就拒绝部署）。
处理原则是**先量清楚这道门在防什么、你的脏文件是不是它防的那类**，再决定走哪条：

```bash
git status --short                              # 到底脏在哪
grep -n "exclude '<脏文件所在目录>/'" scripts/deploy/sync.sh   # 它会被同步上去吗
```

本次唯一的脏文件在 `docs/`，而 `sync.sh` 明确 `--exclude 'docs/'` —— 它物理上不可能上线，
门的判据（"工作树脏"）比实际风险面宽。这种情况下 `ALLOW_DIRTY=1` 的实际风险为零。

⛔ 但**这仍是绕过一道 fail-closed 门，属判断类 → 必须让 Colar 拍板**，附上你的证据
（脏在哪 + exclude 在第几行）。不要自己决定绕，也不要因为"门拦了"就放弃部署。

⚠️ 部署快照会把未提交文件一并封进去（本次日志：`dirty_files_snapshotted=1`）。这只影响
回滚锚点的内容记录，不影响线上——但汇报时要说清楚，别让人以为那些改动上线了。

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
| **规则搬了、规则针对的资产没搬** | 代码里有专治某件资产的 override，产品库里却没有那件资产——规则匹配不到任何东西，等于没搬 | 移植清单里凡是**资产专用**的常量/覆盖表，都要回答一句"它针对的资产在目标仓吗"。见 Step 4b |
| **pre-commit 跑全量测试被超时打断** | commit 在测试跑到一半时 SIGTERM，`git log` 看不到新 commit | Bash 超时给足 10 分钟；实测本仓 pytest 2260 项约 200-300 秒 |
| **`nohup … &` + 后台执行的 exit 0** | 外层 shell 立刻返回、报"完成"，真进程还在跑；照着这个结论往下走会把"部署完成"说错 | 用 `while pgrep -f "<真命令>"; do sleep 10; done` 等真进程，别信外层退出码 |
| **软渲染的颜色当成最终色** | headless 用 swiftshader，出的色和用户真 GPU 上看到的不一致，颜色决策就此跑偏 | 任何**颜色**决策都要人在真 GPU 上看；headless 只用来验"跑不跑得起来"和构图 |
| **拿 headless 拖拽扫一圈角度** | 每个角度一次拖拽+等待，12 个角度轻松超 6 分钟被超时砍掉 | 减少采样（45° 步长 8 张）并后台跑；或把参数做成 URL/props 入口，别用鼠标模拟 |
| **临时验证路由忘了删** | 它会随下一次 commit 进仓，还可能被部署上线 | 每次用完立刻 `rm -rf` 并 `git status` 确认；本 skill 全程建了三次、删了三次 |
| **从中间量反推标定值** | 拖拽转出来的角度 ≠ 写进配置的角度，试了 +60/−60 两轮全错 | 穷举**最终生效的那个量**，别推算。见 Step 4c |
| **探测时改了配置忘了还原** | 最后一个探测值留在仓里被当成标定结果 | 探测脚本开头存 `orig`，结尾无条件写回 |
| **指标量的不是你要的那件事** | 数字得出的结论和眼睛完全相反，而数字看起来很权威 | 本次原形：判封面底色好坏用了「衣服与底色的 **L\*** 差」，于是「暖米白最好、越换越糟」；可奶白裙子的问题本来就是**色相**接近而非明暗接近，改量 **ΔE** 后立刻反转（融进背景的像素 3.3%→0.6%）。**先问这个指标能不能区分你正在纠结的那两种情况**，再去看它的数值 |
| **门只加不测** | 门声称在把关，实际可能对所有输入静默放行，且表现与"全都合规"完全一致 | 补测试后跑 mutation（解析器恒返回 `None` / 改阈值 / 硬拦降级成警告）验证各自精准变红。前提是驱动已收进 `main()`，模块级驱动 `import` 即执行、根本没法测 |
| **烘焙脚本报成功 ≠ 用了新参数** | 改完常量直接烘图，HMR 没吃进去就拿旧参数出图，还打印 `✓` | 烘完反查一个单调量（改曝光就量亮度均值），比 finalize **之前**的源图。见 Step 4c |
| **拿历史产物当对照组** | 把新旧封面的全部差异都归因到刚改的那个参数上 | 旧产物烘完之后的每个渲染 commit 都混在里面。要归因单参数就用同一张源图跑两遍 |

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
