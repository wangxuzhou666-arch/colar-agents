---
name: 3d-intake
description: "织锦 3D 换料预览的外部素材入库流程，两条分支。A 服装 Block：CLO-SET 导出的 .glb / .gltf 散包 → UV 与材质槽体检（有无 UV / 是裁片展开还是 atlas / 几个槽）→ blocks/ 归位 → 按材质名（不是 mesh 名）做槽位映射 → 换件时 dispose 显存。B 面料 PBR：ambientCG CC0 整包 zip → 保留 Color + NormalGL + Roughness + AO 四通道（织锦已有的 fetch_ambientcg.py 只留 Color，3D 用途会缺质感）→ 白坯亮度归一化 → 去饱和 + multiply 染色 → 接进 map / normalMap / roughnessMap / aoMap。Use when: adding a new garment block or a new fabric to 织锦's 3D try-on preview, wiring PBR texture channels into a three.js MeshPhysicalMaterial, or debugging \"the fabric looks like plastic / the dyed color comes out gray / GPU memory grows every time I switch garments\"."
version: 1.0.0
source: session-derived (2026-08-10)
project: fabric-agent-demo (织锦) — /Users/colar/Desktop/创业/fabric-agent-demo
---

# 3d-intake — 外部 3D 素材入库织锦

织锦的 3D 换料预览吃两类外部素材：**服装 Block**（衣服的三维网格）和**面料**（贴到衣服上的布）。
两类的来源、体检项、失败模式完全不同，但都走同一个骨架：**下载 → 体检 → 归位 → 接线 → 验证**。

**一句话心智模型**：Block 的坑在 UV 和材质槽（拿到手先体检，别直接接），面料的坑在通道不全和染色链路（只有 Color 图接不出质感）。

---

## When to Use

**触发**
- 要往织锦加一件新服装 Block（Colar 给的 CLO-SET 导出文件）
- 要往 3D 预览加一种新面料
- 3D 预览里布料"像塑料 / 像纸片"、没有质感
- 染色后底色发灰、深色底染不下去
- 连续换几件衣服后显存暴涨 / 页面卡死

**不触发**
- console 面料库那种 **2D 布样缩略图**需求 —— 走织锦已有的 `experiments/studio-bakeoff/fetch_ambientcg.py`，它就是为那个场景写的（只留 Color 是对的）
- 调渲染的光照参数（那是布光，不是素材）
- CLO 里建模 / 改版型（不在这条链路）

---

## Procedure — 分支 A：服装 Block

> **先看这一条：织锦仓里已有端到端管线**（2026-08-18 起）。下面 A1-A5 是它内部做的事，
> 手工照做只在管线不适用（新格式、要调参数）时才需要：
>
> ```bash
> node scripts/assets/block_intake.mjs <input.zip|dir>... [--name <中文名>] [--skip-cover]
> ```
>
> 一条命令吃 N 个包：解压 → 认主文件与贴图 → 转 GLB（FBX 走 Blender 重接材质）→
> 压 KTX2/meshopt → 跑 `block_probe.py` 槽位体检 → 落库 + 写 manifest → 烘封面，
> 最后出一张 HTML 报告把所有件的封面与体检结论铺开，供**一次过目、一次拍板**。
> 它刻意不碰 git、不部署 —— 那两步各有各的坑，见报告页脚与 `scripts/assets/README.md`。

### A1. 拿到文件

**Colar 提供 CLO-SET 导出文件**（本 skill 不写网站操作步骤 —— 2026-08-10 拍板，那段由 Colar 给文件）。
到手可能是两种形态，处理路径不同：

> **交付姿态（2026-08-10 Colar 拍板）**：Colar 只出素材和眼睛。解包 / 体检 / 打包 / 接线全部由 AI 在终端完成，
> 浏览器打开时必须**已经是载入好的 3D 画面**（`?block=` 自动载入）。拖拽框 / 选文件是兜底 UI，
> 正常流程里 Colar 永远不该看到它。

| 形态 | 特征 | 处理 |
|---|---|---|
| 单文件 | 一个 `.glb` | 直接入库（体检后 cp 进 blocks/） |
| **散包** | `.gltf` + `.bin` + 若干贴图 png | `npx -y @gltf-transform/cli copy in.gltf out.glb` 打包成单文件再入库（未引用的 displacement 会自动丢弃） |

散包是 CLO-SET / Marvelous Designer 的**常见默认导出**。不打包直接给浏览器的话，loader 解析外部引用一律 404
——所以散包在终端就地打包，不走浏览器拖多文件那条兜底路。

**中文版 CLO 导出的 zip 是 GBK 文件名，`unzip` 解不出来**（2026-08-10 实测）：

```
error: cannot create jacket/??????_...gltf
       Illegal byte sequence
```

`unzip` 退出码 50，一个文件都没落地。zip 的 flag_bits 没置 0x800（UTF-8 位），文件名按 cp437 存的实为 GBK。
用 python 转码解，顺手把 slug 改成 ASCII：

```python
import zipfile, os
z = zipfile.ZipFile(src)
for i in z.infolist():
    name = i.filename
    if not (i.flag_bits & 0x800):                      # 没标 UTF-8 → 大概率 GBK
        try: name = i.filename.encode('cp437').decode('gbk')
        except Exception: pass
    dest = os.path.join(out, name)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if not name.endswith('/'):
        with z.open(i) as f, open(dest, 'wb') as w: w.write(f.read())
```

Colar 的资产都出自中文 CLO，所以这条**每次都会撞上**，别当偶发。

### A2. 体检（接线前必做，AI 静态解析，不需要浏览器）

python 直接解析 `.gltf` JSON + `.bin`（散包）或 GLB chunk，当场回答三件事：

1. **有没有 UV** —— 每个 primitive 查 `attributes.TEXCOORD_0`；没有 = 换料不可能，这件废掉
2. **UV 是按裁片展开还是算法生成的 atlas** —— 逐裁片算 **3D 边长 / UV 边长** 的中位数：
   各裁片一致（±10% 级）= 真裁片展开，平铺面料不拉伸；相差数倍 = 算法 atlas，必拉伸
3. **有几个材质槽** —— `materials[]` 数量 + 每材质的 prim/三角数分布；只有 1 个 = 衣身 / 领子 / 袖子无法分开换

任一项不过就别往下走，回去要新的导出。`glb-check.html`（spike 体检台）只作肉眼兜底，不是正步骤。

**体检别再手搓了 —— 织锦仓里已经有工具**（2026-08-18 起）：

```bash
python3 scripts/assets/block_probe.py <file.glb>      # 人读；--json 供管线消费
```

它从 GLB 的 JSON chunk 直接算（零解码，压缩前后都能跑），一次给出三样：每材质的三角
占比与世界包围盒、**离群部件**（包围盒连通分量分离 → 建议判 `off`）、**疑似配件**
（面数与尺寸双小 → 建议判 `keep`）。抓不到的两类它会在报告里明写：贴合衣身的道具
（衣架挂钩与衣身重叠，连通分量并进主体）和高模明线（面数比主料还大）。**「没检出」
不等于「没问题」**，那两类仍要靠材质名正则 + 看封面。

⚠️ **「占比最大的那个材质就是衣身」这条旧判据已被证伪，别再用。** sports-skirt01
占比最大的是**配套袜子**（50.9%，131k tris），衣身各片加起来才 45.6% —— 配套小件用
高模是常事，CLO 对针织罗纹尤其舍得给面。`block_probe.py` 第一版就是照这条写的，
当场把袜子判成主体、衣身报成离群。**主体要按主轴跨度定**（衣身 0.805m vs 袜子 0.236m，
差 3.4 倍，不受建模精度影响）。

占比表仍然要看，只是读法变了：它用来发现**异常大的非主料**（明线、里衬），
而不是用来认衣身。实例（leather-jacket01，这件的最大占比确实是衣身）：

```
mat[0]  'V2_Animal_Alternatives_VeganLeather_1_2801'  tris=139151 (79.4%)   ← 衣身
mat[29] '默认明线_2828'                                tris=  5096 ( 2.9%)   ← 明线
mat[30] '默认明线 复制 1_2852'                          tris=  4004 ( 2.3%)   ← 明线
mat[1..28] 'Zipper N_...'                              各 <2%                ← 拉链
```

### A3. 归位 + 验收

放 `blocks/<slug>.glb`。CLO 导出的 16MB 级别很正常；4K 贴图散包打包后 50MB 级别，本地预览没问题，上线前再压。
验收入口一律 `playground-3layer.html?block=blocks/<slug>.glb` 自动载入后 `verify_and_open.sh` 弹给 Colar——**不要让他手动拖**。

### A4. 材质槽映射（最容易踩的一条）

**换料的单位是「材质」不是「mesh」。**
CLO 导出的布片**全部叫 `Cloth_mesh`**（几十个同名），按面料类型区分的信息只存在**材质名**里
（`Cotton_Heavy_Denim` / `Default Button` / `Topstitch`…）。用 mesh 名当 key 会让同名 mesh 互相覆盖槽位。

槽位分三类，用材质名正则猜：

```js
// 逐件显式槽位表：正则救不了的乱码材质名优先查这里（精确匹配 > 正则猜测）。
// 实例（ethnic-print-dress01）：明线材质叫 "0.1_2998"、按扣叫 "snap_2954"——
// 前者任何正则都落空，落进 main 会给 176k tris 的明线贴平铺面料，比不换更糟。
const SLOT_OVERRIDES = { "0.1_2998": "keep", "output_2975": "keep" };

function guessSlot(matName) {
  if (matName in SLOT_OVERRIDES) return SLOT_OVERRIDES[matName];
  const n = (matName || "").toLowerCase();
  // 人台/替身：直接隐藏
  if (/ghost|mannequin|avatar|dummy|skin/.test(n)) return "off";
  // 配件保留原始材质：它们的 UV 是 atlas 里的一小块（实测纽扣/明线只占 5%），
  // 换上平铺面料只会显示被拉伸的一角，比不换更糟
  if (/button|topstitch|stitch|zip|snap|trim|leather|suede|ribbon|bow|tulle|lace|label|eyelet/.test(n))
    return "keep";
  return "main";   // 剩下的才是可换料的衣身
}
```

正则会往**两个方向**同时出错，两种都静默——没有报错，只有观感不对，所以只能靠 A2 那张占比表当场核：

| 误判方向 | 实例 | 症状 | 判据 |
|---|---|---|---|
| **衣身被误判成配件** | `V2_Animal_Alternatives_VeganLeather_1_2801` —— 名字里的 `leather` 是**面料品名**（人造革衣身），不是配件材质，却命中配件正则 | 79.4% 的三角形拒绝换料，整件衣服换不了布 | 占比最大的材质被判 `keep`/`off` → 必错 |
| **配件被误判成衣身** | `默认明线_2828`、`默认明线 复制 1_2852` —— 中文版 CLO 的默认命名，`topstitch\|stitch` 正则全落空 | 9.1k tris 的明线被贴上平铺面料 | 中文 / 乱码材质名一律**先假定正则没覆盖**，逐个判 |

`leather` / `suede` 留在配件正则里仍是对的（真皮标、麂皮拼条确实这么命名），**不要为了这一件去删它**——
删了下次就轮到真配件被贴布。正解是逐件登记 `SLOT_OVERRIDES`，让精确名压过正则。

中文材质名会持续出现（Colar 的 CLO 是中文版），所以「正则是拉丁文假设」这条要一直记着。

新 block 入库时逐材质核对槽位判定：正则漏掉的（乱码名 / 身份不明层）登记进 `SLOT_OVERRIDES`，
身份不明的层默认 keep，等 Colar 在槽位表里切「隐藏」肉眼定夺后再改。

同时把原材质留底 `o.userData.origMat = o.material` —— 切回「原样」槽位要还原成 CLO 自带的 PBR 外观。

### A5. 换件时 dispose（不做就吃满显存）

`scene.remove(model)` **只断引用，不还显存**。GPU 侧的 buffer 和 texture 必须显式 dispose，
否则连拖三四个 16MB GLB 就能吃满。

两个必须堵的漏：

1. **共享材质不能碰** —— `mainMat` / `altMat` 和面料贴图是全局共享的，dispose 了就全黑
2. **`userData.origMat` 会漏网** —— mesh 切到面料槽后 `o.material` 已经是共享的 mainMat，
   原材质挪到了 `userData.origMat`，只 traverse `o.material` 就漏掉整件衣服的原始贴图（CLO 那套动辄四张 2K）

```js
function disposeModel(root) {
  const seen = new Set();
  root.traverse((o) => {
    if (!o.isMesh) return;
    if (o.geometry) o.geometry.dispose();
    const mats = Array.isArray(o.material) ? [...o.material] : [o.material];
    if (o.userData.origMat) mats.push(o.userData.origMat);   // 漏网那条
    for (const mat of mats) {
      if (!mat || mat === mainMat || mat === altMat || seen.has(mat)) continue;  // 共享的别碰
      seen.add(mat);
      for (const v of Object.values(mat)) if (v && v.isTexture) v.dispose();
      mat.dispose();
    }
  });
}
```

---

## Procedure — 分支 B：面料 PBR 贴图

### B1. 源与通道

ambientCG（CC0，商用免授权）。**必须下整包 zip，不能用资产页的预览图** —— 预览是布料垂坠在球体上的
渲染，带球体轮廓；平铺 albedo 只在包里的 `*_Color.jpg`。

```bash
# 列候选
curl -sS "https://ambientcg.com/api/v2/full_json?type=Material&q=fabric&limit=30&include=downloadData"
# 下整包（2K-JPG，单包 20-35MB）
curl -sSL "https://ambientcg.com/get?file=Fabric036_2K-JPG.zip" -o Fabric036.zip
```

⚠️ **织锦仓已有的 `experiments/studio-bakeoff/fetch_ambientcg.py` 不能直接复用。**
它的 `extract_color()` **只抽 `_Color.jpg`，把 Normal / Roughness / AO 全丢了**
（对它自己的用途 —— 给 console 面料库配 2D 布样图 —— 是对的）。3D 用途必须留四通道，
否则整包 zip 已经下过了，三个通道白丢。

3D 要留的四张（其余的 `.blend` / `.usdc` / `.mtlx` / `_NormalDX` 删掉省磁盘）：

| 文件 | 用途 | 注意 |
|---|---|---|
| `_Color.jpg` | albedo | 走 canvas 染色链路，不直接当 map |
| `_NormalGL.jpg` | 织纹起伏 | **必须 GL 不是 DX** —— three.js 用 OpenGL 约定，拿错 DX 法线会翻转 |
| `_Roughness.jpg` | 粗糙度空间变化 | **质感的大头**，缺它布料必像塑料 |
| `_AmbientOcclusion.jpg` | 纱线间暗角 | 不是每个资产都有，要判存在 |

**`_Displacement.jpg` 不接** —— 需要细分网格，服装 GLB 是低模，接了会撕裂。

### B2. 接线

```js
mainMat.map          = albedo;              // canvas 合成后的（染色 + artwork）
mainMat.normalMap    = pbrMaps.normal;
mainMat.roughnessMap = pbrMaps.rough;       // 缺这张 = 质感差的头号原因
mainMat.aoMap        = pbrMaps.ao;
mainMat.needsUpdate  = true;                // 增删 map 会改 shader，必须重编译
```

四条硬约束：

1. **三通道的 repeat 必须与 albedo 同步**（都用 `state.rep`）—— 它们来自同一块布，尺度不一致织纹和明暗就对不齐
2. **anisotropy 全部设 `renderer.capabilities.getMaxAnisotropy()`** —— 不设的话斜视角下织纹直接糊没
3. **AO 强制 `aoTex.channel = 0`** —— three 的 aoMap 默认吃第二套 UV（`uv1`），服装 GLB 未必有
4. **normalScale 分模式给默认**：真实扫描织纹给 0.5~0.7（它有结构，撑得住）；程序化白噪声只能给 0.08 以下（再高就是脏噪点）

### B3. 染色链路（保住"任意底色 + 花色"能力）

真实面料图自带颜色，要能被染成任意底色，走三步：

```js
// 1) 提亮到白坯基准 —— 不做的话暗料（牛仔）染完每个底色都发黑
ctx.filter = `brightness(${gain})`;
ctx.drawImage(fabricColorImg, 0, 0, W, W);
ctx.filter = "none";
// 2) 抽掉原图自带的颜色（牛仔是蓝的，不抽会串色）
ctx.globalCompositeOperation = "saturation";
ctx.fillStyle = "#808080";  ctx.fillRect(0, 0, W, W);
// 3) 压上底色
ctx.globalCompositeOperation = "multiply";
ctx.fillStyle = baseColor;  ctx.fillRect(0, 0, W, W);
ctx.globalCompositeOperation = "source-over";
```

**为什么 multiply 而不是 `"color"` 混合**：染色在物理上就是乘法（入射光穿过染料层衰减），
只有乘法能同时带走色相和明度。`"color"` 混合**不动亮度**，近黑底色（`#1A1A1E`）根本染不下去。

**为什么要 gain 归一化**：不同面料原图明暗差很多（实测某亚麻灰坯平均亮度只有 186/255），
直接 multiply 会让米色 `#E8DCC8` 染成 `#A9A091` —— 就是"布料本色发灰"的成因。
每块料自己算系数，目标灰坯亮度 235，上限 2.2 倍（再高会把纱线高光压平）：

```js
const WHITE_GOODS = 235;
function gainFor(img) {  // 64×64 采样算平均亮度即可
  // ... drawImage 到 64×64 离屏 canvas，取 getImageData
  const lum = /* 0.2126R + 0.7152G + 0.0722B 的均值 */;
  return Math.min(2.2, Math.max(1, WHITE_GOODS / Math.max(1, lum)));
}
```

用户上传的面料图要**单独算自己的 gain**，不能借用当前 PBR 那张的系数。

染色后再叠 artwork 图案层。**真实面料不要再撒程序化噪点** —— 它自带纱线颗粒，再撒只会脏。

---

## Verification

三道静态检查（改完 playground 类单文件 HTML 后跑，秒级）：

```bash
# 1. module 脚本语法
python3 -c "
import re; src=open('playground-3layer.html',encoding='utf-8').read()
m=re.search(r'<script type=\"module\">(.*?)</script>', src, re.S)
open('/tmp/pg.mjs','w',encoding='utf-8').write(m.group(1))"
node --check /tmp/pg.mjs

# 2. 滑杆 / seg 的 DOM id 有没有悬空引用（漏一个就是静默失效）
#    比对 slider("<id>","<outId>") 与 segRow(getElementById("<id>")) 对应的 id="..." 是否存在

# 3. 贴图 HTTP 可达（file:// 下 fetch 本地资源被 CORS 挡，必须经 localhost）
curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:8765/textures/<Asset>/<Asset>_2K-JPG_Roughness.jpg"
```

**最终验收永远是 Colar 的眼睛**，不是任何指标。参考基准（电商单品图那种影棚白底挂拍）：
布料本色不发灰、白/米不过曝、正常视距看不见织纹、地面几乎无硬投影、暗部只在袖窿/口袋/翻领下方。

---

## Pitfalls

| 坑 | 症状 | 解 |
|---|---|---|
| 只接了 Color 图 | 布料像塑料 / 橡皮，怎么调光都不对 | 补 roughnessMap —— 质感八成来自粗糙度的空间变化 |
| 拿了 `_NormalDX` | 织纹凹凸方向反了，光打上去别扭 | three.js 用 `_NormalGL` |
| 程序化法线用 `Math.random()` 逐像素 | 放大是脏噪点不是布；缩小后正负法线互相抵消糊成均匀灰 | 真实织纹有空间相干性，用扫描图 |
| 法线图不设 anisotropy | 斜视角织纹糊没（albedo 设了、normal 没设最隐蔽） | 三通道都设 `getMaxAnisotropy()` |
| aoMap 不显示 | GLB 没有第二套 UV，three 默认吃 `uv1` | `aoTex.channel = 0` |
| 用 `"color"` 混合染色 | 深色底染不下去，近黑出来是灰 | 改 multiply（见 B3） |
| 不做 gain 归一化 | 底色整体发灰、暗料染啥都发黑 | 按图算提亮系数 |
| `scene.remove` 当成释放 | 连拖三四件后显存满、页面卡死 | `disposeModel()`，且带上 `userData.origMat` |
| dispose 时误伤共享材质 | 换件后模型全黑 | 跳过 mainMat / altMat |
| `file://` 直接打开 html | fetch 本地 GLB / 贴图被 CORS 挡 | 起 `python3 -m http.server` 走 localhost |
| three.js 走 CDN importmap | CDN 一抖 module 死在第一行 import，页面只剩原始拖拽框、`?block=` 自动载入失效、零报错 | three 本体 + addons vendor 进本地目录（注意 r180 `RGBELoader.js` 只是转发壳，真身 `HDRLoader.js` 要一起带）；再加 window `error`/`unhandledrejection` 兜底把报错写上屏 |
| `node -p "require('three/package.json')"` 查版本 | 被 three 的 exports 字段挡住 | 用 python 直接读文件，或看 importmap 里的 CDN 版本号 |
| 中文版 CLO 的 zip 用 `unzip` 解 | `Illegal byte sequence`，退出码 50，一个文件都没落地 | python `zipfile` + cp437→gbk 转码（见 A1） |
| 衣身材质名里带 `leather` / `suede` | 命中配件正则被判 `keep`，整件拒绝换料（实测 79.4% tris） | 看 A2 占比表，占比最大的被判 keep 就登记 `SLOT_OVERRIDES` |
| 中文材质名（`默认明线`） | 配件正则全落空，落进 main 被贴平铺面料 | 中文名默认假定正则没覆盖，逐个判 |
| **展示图把资产自带材质换成了平铺面料** | 展示图看着质感平淡，怎么调光都改善不了 | 见下节 —— 问题在内容不在渲染器 |

### 「展示图质感平淡」的第一诊断：先看你换没换掉它自己的材质

展示图（封面 / 缩略图）质感平淡时，第一反应会去查布光、曝光、色调映射——**通常不是根因**。
常见的真凶是封面流水线在出图前把衣服的材质换成了库里的平铺面料：一件皮夹克自带 4K PBR
（diffuse + normal + metallicRoughness），却被贴上只有 Color 通道的亚麻，出来是一件平淡的
米色外套。展示图该呈现的是**衣服本来的样子**——皮革的高光、真丝的垂坠、针织的绒毛，那些质感
全在资产自带的贴图里，不在渲染器里。

判据：**展示图（封面 / 缩略图 / 首帧）默认用资产自带 PBR，换料是用户的主动动作。**
副作用还是正的——进场第一眼与封面一致，且"换料"这件事从此有了前后对比，价值反而看得见。

`--fabric` 这类换料参数保留为显式开关，别做成默认。

---

## Why This Skill Exists

2026-08-10 的织锦 3D 渲染调参 session 蒸馏。起因是 Colar 看完调完布光的预览说"面料质感还是差很多"，
往下挖发现根因不在布光而在材质通道：整个材质只有 albedo + 一张 256px 白噪声法线，
**roughnessMap 压根没接** —— 而粗糙度的空间变化正是布料质感的大头，缺它眼睛立刻读成塑料。

同一轮还查出织锦仓的 `fetch_ambientcg.py` 早就下过整包 PBR zip，却只留了 Color 通道
（对它服务的 2D 布样场景没问题，但 3D 用途白丢三个通道）。这条"同一份 zip、不同用途、
留不同通道"的分工如果不写下来，下次一定重复踩。

染色链路那三步（gain → 去饱和 → multiply）是当轮试错试出来的：先用 `"color"` 混合，
发现近黑底色染不下去；改 multiply 后又发现整体发灰，才补上按图归一化。

## Related

- [fabric-loop](../../../../创业/fabric-agent-demo/.claude/skills/fabric-loop/SKILL.md) — 织锦开发 → 审核 → 交接循环（本 skill 是它的素材侧前置，两者正交）
- 织锦仓 `experiments/studio-bakeoff/fetch_ambientcg.py` — 2D 布样图采集（只留 Color，勿直接复用于 3D）
- 织锦仓 `experiments/studio-bakeoff/inputs/acg/CREDITS.md` — CC0 素材署名归档
