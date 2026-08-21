---
name: style3d-resource-sync
description: 从 Style3D Cloud（或任何官方导出不可用的 SaaS）把资源库数据同步进织锦平台的完整打法 —— 抓前端同款内部接口（Copy as cURL 取 Bearer）→ 列表+详情双拉合并 → 外部编码体系翻译 → 图片过平台守卫 → 灌 sqlite 带备份。治九类坑：端点名不可推导（猜 4 个变体全 404）· 详情 data.data 双层嵌套只剥一层会静默落空 · 列表与详情字段非包含关系（列表有图无价、详情有价无图）· 外部成分缩写与平台中文词表断链导致派生 tag 全 miss · imaging 守卫 max_side 有下界不能拧松 · CC0 判据方向易反 · stock_meters 映射会清零既有库存 · 图片降质到底该退尺寸档而非继续压 · 凭证 7 天过期让"全自动定时"成伪需求。Use when: pulling data out of a SaaS whose official export is unavailable or permission-locked (Style3D Cloud fabric/garment/order libraries in particular), and loading it into the fabric-agent-demo platform — or when debugging "字段拉下来了但全是空 / 派生 tag 一个没命中 / 导入后既有库存被清零".
version: 1.0.0
source: session-derived (2026-08-21)
---

# Style3D 资源库 → 织锦平台 同步

## When to Use

**触发**

- 需要把 Style3D Cloud 某个资源库（面料库 / 样衣库存 / 款式 / 订单）的数据搬进织锦平台
- 官方导出入口不可用：批量工具栏没有「导出」· 详情页 `...` 菜单只有分享类 · 或点了被权限拒
- 任何 SaaS 的"我在界面上看得见，但它不给我导出"场景（打法通用，端点特化）
- 排查同步后的数据异常：字段全空 / tag 派生零命中 / 库存被清零 / 图片被平台拒收

**不触发**

- 官方导出按钮可用 → 直接用，别绕。走接口只是因为没得选
- 给 3D 换料预览加素材（sfab / u3ma / glb / PBR 包）→ 那是 `3d-intake`，通道处理完全不同
- 一次性看几条数据 → 浏览器里看就行，别为 3 条数据搭管线

## Procedure

### Step 1 — 抓凭证（每个账号一次，token 过期后重抓）

浏览器打开目标资源库页面 → `F12` → Network → 筛选 `Fetch/XHR` → `Cmd+R` 刷新 →
找到 Response 里含业务编号的那条（面料库是 `fabric:queryList`）→ 右键 Copy → **Copy as cURL**。

落盘，**不经过对话**：

```bash
pbpaste > <repo>/.style3d_curl.txt && chmod 600 <repo>/.style3d_curl.txt
```

从 curl 里只提取这几项写成 `KEY=VALUE`（**实测只需 Bearer，不必搬整串会话 cookie** —— 少一份可泄漏的东西）：

```
AUTHORIZATION=Bearer eyJ...
WEB_CONTEXT=Regular eyJ...        # x-linctex-web-context
REFERER=https://cloud.style3d.com/home/resource/pool/fabric/grid?folderId=<id>
FOLDER_ID=<id>
SUPPLIER_ID=<id>
```

**先加 gitignore 再落盘**，凭证文件与导出目录都要挡：

```gitignore
.style3d_curl.txt
data/style3d_export/
```

> token 里 `exp` 是 Unix 秒，解出来就是有效期（实测约 7 天）。这决定了 Step 7 的定时方案只能是半自动。

### Step 2 — 探接口结构（不要跳过，直接写全流程必返工）

先只拉第一页，dump 原始 JSON，打印**骨架**（键名+类型+标量短值）而非全文。要确认三件事：

1. `total` 与网页上显示的条数**对不对得上**（实测网页显示 113 / 接口返回 93 —— 筛选口径不同，以接口为准并说明差异）
2. 记录里有哪些字段、图片直链在哪一层
3. 有没有**字段定义表**（Style3D 在 `data.list.folder_mode_setting`，51 个字段的 `name`↔`key` 对照）—— 这张表直接回答"这个库到底有什么可拿"

### Step 3 — 列表 + 详情双拉，按 id 合并

**两个接口的字段不是包含关系**，少拉任何一个都会缺必填项：

| 接口 | 独有的关键字段 |
|---|---|
| `fabric:queryList` | `thumbs[].path`（高清图直链 + size）、`internal_code`、`weight` |
| `fabric/{id}/show` | `usage`（→ category）、`customtxt4`（门幅）、`customnum1`（**真实价格**） |

列表里的 `content_price` / `sample_price` **恒为 0**，真价在详情的 `customnum1`。合并方向是「列表打底、详情盖上」（thumbs 只有列表有）。

逐条详情要打近百次，**加 0.3s 间隔** —— 那不是我们的服务。

### Step 4 — 拉图并压进平台上限

`thumbs[0].path` 是原图直链（实测中位 4.5MB，93 张共 380MB）。平台 `fabric_image` 的
base64 上限是 900,000 字符 ≈ 675KB 二进制，取 600KB 留余量。

压缩顺序：**先降质到 q=70 为止，还超就退尺寸档**（1600 → 1200 → 900），不要继续降质 ——
织纹是这批图唯一的信息量，JPEG 块效应会直接啃掉它，而缩小只是等比丢像素。

### Step 5 — 字段映射（本步必须人工校对一次）

三类必须停下来看的：

- **多值 → 单值**：Style3D 的 `usage` 是 `衬衫/连衣裙` 这种多值，平台 `category` 只能单值。
  拍板口径（2026-08-21）：**取首值当 category，其余值映射后进 tags** —— 平台推荐既走 category
  也走 tag 精确匹配，这样两边都能召回，不会因为选了「衬衫」就丢掉「连衣裙」那半场景。
- **外部编码体系翻译**：见 Pitfalls 表第 4 行，这是最隐蔽的一条。
- **缺字段兜底**：品名缺失用面料分类的中文描述充数、起订量给常量 —— 都是机器编的，报告里逐条列出让人扫一眼。

**缺数据不要编**：克重 0 / 价格 0 是对方库里就没填，原样导入并在 `description` 里打
`[克重待补]` / `[价格待补]`。假数字混进库比空着更难发现。

### Step 6 — 灌库（先备份）

```bash
python scripts/style3d_to_platform.py          # 出 CSV + 校对报告，不写库
python scripts/style3d_to_platform.py --load   # 校对完再灌，自动先备份 demo.db
```

图片走 `imaging.normalize_for_provider`（studio 所有外发图的唯一入口），
`import_fabrics` 的 `actor` 必传（keyword-only，防写回无主 `import` 行）。

### Step 7 — 验证落库（不能只信"没报错"）

```sql
SELECT COUNT(*) FROM fabrics;                                    -- 总数 = 原有 + 新灌
SELECT COUNT(*) FROM fabric_image WHERE updated_by='<你的标记>'; -- 图数对得上
SELECT COUNT(*) FROM fabric_image WHERE thumb IS NULL;           -- 缩略图全生成
SELECT COUNT(*) FROM fabrics WHERE fabric_id LIKE '<旧前缀>%';   -- 旧数据没被覆盖
```

**灌库前后各查一次备份库**，确认总数差 = 新灌数。别假设"没报错就没覆盖"。

## Pitfalls

| 坑 | 表现 | 解 |
|---|---|---|
| 端点名不可推导 | 按 `fabric:queryList` 模式猜 `garmentsample:queryList` 等 4 个变体**全 404** | 每个新模块必须另抓一次 XHR。凭证可复用，路径不可推 |
| 详情 `data.data` 双层嵌套 | 只剥一层会合进一个只有 `data`+`image_mode_setting` 两个键的**空壳**，必填字段全落空**且不报错** | 合并前先打印 `list(d["data"].keys())` 确认层数；用覆盖率统计（不是抽查）验证合并生效 |
| 列表/详情字段非包含关系 | 只拉列表 → 价格恒 0、无类目；只拉详情 → 没有图片直链 | 两个都拉，按 id 合并，列表打底详情盖上 |
| **外部编码体系断链** | Style3D 成分是纺织缩写 `100%P` / `60%C/25%P/15%N`，平台 `enrich_fabric_tags` 词表是中文（涤纶/棉）→ **成分派生 0 命中**，tags 只剩类目派生那 2-3 个词 | 加一层代码→中文翻译表再喂 enrich。**这种断链只在统计覆盖率时才看得见**，抽查单条看不出来 —— tags 有值，只是少 |
| 未知编码硬猜 | 同一套编码里 `R` 已是粘胶，`V` 再猜 Viscose 说不通 | 拿不准的**不译**，登记到 `UNKNOWN_CODES` 由报告列出。宁可少几个 tag，不要错误派生 |
| `normalize_for_provider` 的 max_side 有下界 | 下界 = `min_side × max_aspect` = 960，直接传 768 抛 `ValueError` | 要更小的图：**先自己缩再整个过守卫**，不要拧松守卫参数（那正是守卫存在的理由） |
| CC0 判据方向易反 | `CC0_SEED_UPDATED_BY` 是「占位图」判据（当前未武装）。真实布样图的 `updated_by` 若加进那个元组，重新武装那天会把真图一起挡在展厅外 | 真图的标记**刻意避开**该元组，并加 `assert` 锁住方向 |
| `stock_meters` 映射禁区 | 外部库的「大货米数」实测 93 条全 0，映射过去会走 `_set_stock_via_adjustment` 把既有库存**记账清零**（平台代码把这定性为数据事故） | 该列一路留 `None` 到落库层，由那里判「没给值就不动库存」 |
| 凭证 7 天过期 | 让"全自动定期同步"成伪需求 —— 定时任务会在第 8 天开始静默失败 | 只做半自动：定时跑增量（列表有 `update_timestamp`），**token 失效要发通知而不是静默失败**。静默失败的定时任务比没有更糟，你会以为数据是新的 |

## Verification

- 覆盖率统计（不是抽查）跑一遍每个平台必填字段，`0.0%` 的那行就是断链信号
- 图片：`最大体积 < 平台上限` 且 `thumb IS NULL 计数 = 0`
- 灌库前后对比备份库总数，确认没覆盖旧批次
- `UNKNOWN_CODES` 非空时报告必须显式列出，不能静默放过

## Why This Skill Exists

2026-08-21 session：Colar 要把 Style3D Cloud「三润科技/2025」面料库的 93 款面料搬进
fabric-agent-demo。网页端没有导出入口（批量工具栏 4 个按钮 + 详情页 `...` 菜单全是分享类），
Moda OpenAPI 是 AI 创作接口（文生款/面料生成）读不到自有资源库，能读的 PLM API 只在 NDA 下。

期间有两个基于截图的判断被数据推翻，都值得记：

1. 「大部分面料没有布样图」——错。列表里的蓝色 `file` 图标是**缺 sfab 3D 材质包**
   （`download_err_msg` 明写），2D 布样图 93 张一张不缺，且各不相同。
2. 「价格全是 0」——错。列表接口的 `content_price` 恒 0，但详情的 `customnum1` 有真值
   （区间 9.2~55，中位 15，65/93 非零）。

**教训**：界面截图能定位问题，但不能用来下数据结论。覆盖率统计跑一遍再说。

## Related

- [3d-intake](../3d-intake/SKILL.md) — 同样是织锦素材入库，但走 3D 换料预览通道（glb 槽位体检 / PBR 四通道 / 染色）。Style3D 的 `sfab`/`u3ma` 材质包若要用于 3D 预览，走那条路，不走本 skill
- 产物脚本：`fabric-agent-demo/scripts/style3d_pull.py`（probe/list/detail/images/all）· `scripts/style3d_to_platform.py`（映射 + `--load` 灌库带备份）
