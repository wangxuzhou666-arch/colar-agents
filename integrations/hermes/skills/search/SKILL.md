---
name: search
description: "结合 Colar 当前需求，去 GitHub / HuggingFace / arXiv 找到能用的项目、模型、论文，并给出选型判断（不是写综述）。打官方 API 拿硬元数据——star / 最后一次 push / license / downloads / gated——按可用性淘汰排序，产出 HTML Artifact 候选卡交 Colar 点选。治六类实证坑：python.org 版 Python 无证书致 stdlib HTTPS 全挂而 curl 照常通（最易误判成网络问题）· arXiv 必须 https 否则连接直接 000 · 判活跃度只能信 pushed_at，updated_at 会被改描述刷新 · license 大面积 NOASSERTION 需人工看不能当开源 · gh auth token 吐得出 token 不代表 token 有效，401 须降级重试否则整轮静默归零 · HF search 连字符与空格是两个几乎不重叠的命中集。Use when: 要找现成的项目/模型/论文/轮子，做技术选型或 prior-art 调研，问「有没有人做过 / GitHub 上有什么方案 / HF 上有没有模型 / 找几篇论文」——而不是要一篇领域综述（那是 /deep-research）。"
version: 1.0.0
source: session-derived (2026-09-10)
---

# /search：找到能用的项目/论文，并判断能不能用

## When to Use

**触发**

- 「结合我的需求，去 GitHub / HF / 论文站帮我找对应的项目或论文」——本 skill 的原始动机
- 找现成轮子：「这个有没有人做过」「有没有开源实现」「有没有能直接跑的模型」
- 技术选型：几个方案摆一起，要按**能不能用在我的场景**排序，不是按名气
- prior-art 检查：动手造之前先看别人造过没有

**不触发**

- **要的是领域综述**（「这个方向现在什么水平」「XX 和 YY 路线之争怎么回事」）→ 那是 `/deep-research`，
  见下节分工。别用本 skill 硬凑综述，它不验证 claim。
- 已经锁定了具体某个 repo，只是要读代码 / 装起来 → 直接干，不用检索
- 找的是 Colar 自己仓里的东西 → Explore agent / grep

## 与 `/deep-research` 的分工（本 skill 存在的理由）

Claude Code 内置 `/deep-research`：广度 web 搜索 → Fetch phase 并发抓页 → claim 抽取 → verifier 逐条验证。
**只能手动触发**（changelog 明确改过：Claude 不再自行启动）。它优化的是「回答一个开放问题，产出带引用的可信报告」。

本 skill 优化的是另一件事——**发现 + 选型 triage**：

| | `/deep-research` | `/search` |
|---|---|---|
| 源 | 通用网页，靠搜索引擎 | GitHub / HF / arXiv 官方 API，结构化字段 |
| 判据 | 这个说法成不成立、有无引用支撑 | 这东西我今晚能不能跑起来 |
| 产出 | 综述 | 排序过的候选表 + 每个留/汰的理由 |
| 上下文 | 每次从零，不知道你在做什么 | 锚定 Colar 当前项目栈与硬约束 |

**机制差异（不是风格差异）**：deep-research 走网页抓取，拿不到「最后一次 commit 是 850 天前」「license 是
NOASSERTION」这类字段——而这恰恰是唯一决定去留的东西。实测印证：某个热门领域 star 最高的两个仓库
分别停更 850 天、552 天，两者 license 都是 NOASSERTION。
任何基于网页的调研都会把它们报成"主流方案"。

**嵌套关系，不是竞争关系**：陌生领域连关键词都不知道怎么写时，先手动跑 `/deep-research` 拿术语和 landscape，
再回来进 Step 1。`/search` 不自动调它（也调不了，它只能手动触发）。

## Procedure

### Step 0 — 推断需求约束，并把假设摆上台面

Colar 拍板过：**不做强制四问**，从上下文自动推断，不打断他。代价是推错整轮检索白做，所以配一道护栏——
**推完必须先声明假设，且假设要一句话就能纠偏**。

从 cwd / 当前项目代码 / 他话里的信息推这四项，然后在开检索前用这个格式亮出来：

```
按这些约束搜（不对就一句话改，我重跑）：
· 要解决：<具体问题，不是领域名>
· 落到：<项目 + 栈，如 个人博客 / Astro + Cloudflare Workers>
· 硬约束：<license 能否商用 · 显存 · 是否必须离线 · 是否要中文支持>
· 时间预算：<今晚跑通 / 一周集成 / 只是看看可行性>
```

推不出来的项**标 `?` 摆出来，不要编**。`?` 项就是他最可能纠正的地方。

**为什么不省这一步**：约束决定的是淘汰规则而非排序权重。不知道"必须商用"就没法砍掉 NOASSERTION，
不知道"必须离线"就没法砍掉纯 API 方案——那样出来的候选表只是按 star 排的名气榜，跟直接搜没区别。

### Step 1 — 构造查询词变体（2-4 个，不要只给一个）

三个源的检索都是**子串/词项匹配，不是语义检索**。一个词打不全：

- 学名 + 俗名 + 缩写：`document layout analysis` / `DLA` / `page segmentation`
- HF 额外要连字符变体（脚本已自动加，见 Pitfalls）
- arXiv 用学术术语，GitHub 用工程术语——两边常常不是同一个词

### Step 2 — 三源并发检索

```bash
python3 ~/Desktop/colar-agents/integrations/hermes/skills/search/scout.py \
  --q "document layout analysis" --q "DLA detection" --q "page segmentation" \
  --limit 15 --out /tmp/scout.json
```

- `--sources gh,hf,arxiv`（默认全开，可裁）
- 三源在独立线程里跑，**单源失败不拖垮其他源**，错误进 `result.errors`
- HTTP 层双通道：urllib 连接失败自动退 curl（受限环境里常常只有一条通得了）
- 脚本自带限速：GitHub query 间隔 7s（匿名 search 限 10/min）、arXiv 间隔 3s（官方要求）
- stdout 只给够判断"检索本身成不成立"的摘要；**详细评估读 JSON**，不要只看 stdout 就下结论

**跑完先看 `errors` 段**。有错误就是这一源的结果不完整，不能当成"这个源没东西"。

### Step 3 — 硬事实体检（先淘汰，不带感情）

这一步只用 JSON 里的客观字段，**先砍再评**。砍完再进 Step 4，能省掉大半评估成本。

| 字段 | 砍的条件 | 为什么 |
|---|---|---|
| `archived` | true | 官方宣告死亡 |
| `days_since_push` | > 540 且无 fork 接盘 | 依赖早已锁死，装不起来的概率极高 |
| `license_needs_review` | true 且 Step 0 要求商用 | NOASSERTION 不等于可商用，**必须人工打开 LICENSE 看** |
| `gated`(HF) | true 且要脚本化流程 | 要点同意条款才能下权重，无人值守会卡死 |
| `stars` / `downloads` | 极低且无论文背书 | 无人验证过 |

**不能砍的**：star 低但论文刚出（arXiv `published` 三个月内）——那是新东西，另立一档"前沿但未验证"。

### Step 4 — 适配评估（对齐 Step 0 的约束，逐条对）

活下来的候选，逐个回答：

1. **栈合不合**——`language` / `tags` 跟 Step 0 的栈冲不冲突（Python 训练脚本要接进 Next.js 是另一份工作量）
2. **权重/数据可不可得**——HF 有没有对应 weights，还是只有训练代码
3. **复现成本**——README 有没有 demo/colab；要不要重训；显存要求
4. **风险**——license 真实条款、依赖是否锁死、有没有 known-broken issue

拿不准的字段**去 WebFetch 那个 repo/model 的页面补**（API 优先，够不着退 Web——这是拍过板的策略）。
补来的信息标明来源，别跟 API 硬事实混在一起。

### Step 5 — 出 Artifact 候选卡，交 Colar 点选

拍板过的产出形态。**每个候选一张卡**，必须含：

- 标题 + 一句话它是什么
- **硬事实区**（直接来自 API，标 source）：★ / 最后 push（天数，不是日期字符串）/ license / 语言 / downloads
- **适配判断区**（我的评估，明确标是判断不是事实）：栈匹配度 / 复现成本 / 风险
- **留 / 汰 点选**
- 顶部放 Step 0 的约束摘要，让他一眼能看出我是按什么在筛

底部一键复制结构化 JSON（`{"keep": [...], "drop": [...], "note": "..."}`），他粘回来我接着做。

**不产出**「待你填」的 markdown 表格——SOUL 铁律，手填摩擦会卡死整条链。

发布前按需要加载 `artifact-design`。

### Step 6 — 回执

他点选完，回执三件：留下的候选、下一步动作（装哪个 / 读哪篇）、以及**这轮检索没覆盖到的角落**
（哪个源报了 error、哪些词没试、哪些判断是二手信息）——诚实标注盲区，别让候选表看起来比实际可信。

## Pitfalls

| 坑 | 表现 | 解 |
|---|---|---|
| **python.org 版 Python 没装证书** | stdlib 请求全报 `CERTIFICATE_VERIFY_FAILED`，但 **curl 同一 URL 照常 200** → 极易误判成"网络没问题，是脚本 bug" | scout.py 已用 `certifi` 建 SSLContext 兜住。想全局修：跑 `/Applications/Python 3.12/Install Certificates.command` |
| **arXiv 用 http 直接连不上** | `http://export.arxiv.org/...` 返回 HTTP 000（连接失败，不是 4xx） | 必须 `https://`。脚本已写死 |
| **`updated_at` 判活跃度会骗人** | 改个描述、加个 topic 就会刷新 `updated_at`，死仓看着像活的 | 只信 `pushed_at`（最后一次代码推送）。脚本只取这个 |
| **license 大面积 NOASSERTION** | 实测 top8 里 5 个是 NOASSERTION——有 LICENSE 文件但 SPDX 认不出（多为研究限定/自定义协议） | 标 `license_needs_review`。要商用**必须人工打开 LICENSE 原文**，既不能当"开源"也不能当"没协议" |
| **`gh auth token` 吐出的 token 可能是坏的** | `gh auth status` 报 `token in keyring is invalid`，但 `gh auth token` 照样返回一个字符串；带它请求 → 401 → 整轮检索静默归零，比没 token 更糟 | 脚本 401/403 时脱掉 Authorization 头**匿名重试一次**，并在 `_auth` 里标明已降级 |
| **HF search 连字符 ≠ 空格** | 含空格的多词 query 和它的连字符版（`a b` vs `a-b`）命中集合几乎不重叠 | 脚本对含空格的 query 自动补连字符变体，两种都打 |
| **star 高 ≠ 能用** | 实测某领域 star 第一的仓库停更 850 天 | Step 3 先砍再评。名气排序是检索副产品，不是选型结论 |
| **受限沙箱里解释器出站被拒** | Python 报 `Errno 61 Connection refused`，curl 同一 URL 却 200；有时反过来，有时两个一起挂（`curl rc=7`，19ms 内即拒 = 立即拒绝，不是超时） | 脚本 HTTP 层已做双通道：urllib 失败自动退 curl（`_fetch`）。**HTTPError 原样抛不退 curl**——401/403/429 是业务信息，被重试吞掉会让降级逻辑失效。两条都不通就是环境间歇放行，隔几分钟重跑，`--sources` 分源跑提高命中 |
| **macOS 没有 `timeout` 命令** | `command not found: timeout` | 用 Bash 工具自己的 `timeout` 参数，别在命令里写 |

## Verification

一轮检索算完成，要同时满足：

1. `errors` 段为空，或每条 error 都已在 Step 6 回执里显式标为盲区
2. 每个进入候选卡的条目，`license` 与 `days_since_push` 都有实际值（不是 `null`）——
   null 意味着 API 没返回，**不能默认它没问题**
3. Step 0 的约束逐条能在筛选理由里找到对应（约束没被用上 = 白问）
4. 候选卡里"硬事实"与"我的判断"视觉上分得开，Colar 能看出哪些是 API 拿的、哪些是我推的

## Why This Skill Exists

Colar 反复发出「结合我的需求去 GitHub / HF / 论文站找对应项目或论文」这类指令，但平台内置的
`/deep-research` 接不住它——deep-research 优化的是"回答开放问题、验证 claim"，走网页抓取，
既拿不到决定去留的结构化字段，也不知道 Colar 在做什么项目。「结合我的需求」这半句它执行不了。

这不是 deep-research 做得不好，是**两件不同的事**：一个是 research（信息综合），一个是 discovery + triage
（资源发现与适配筛选）。前者的成功标准是"结论可信"，后者是"选中的东西真能用起来"。

2026-09-10 拍板四项：边界只做发现+选型（综述外包给 `/deep-research`）· 检索 API 优先够不着退 Web ·
需求从上下文自动推断但必须声明假设 · 产出走 HTML Artifact 候选卡。

## Related

- `/deep-research`（Claude Code 内置，手动触发）—— 领域综述与 claim 验证，本 skill 的上游可选步骤
- `spike-to-production` —— 选中的东西验证可行之后，怎么搬进产品并真的上线
- `feedback_vc_structural_thinking` —— 找到的东西要不要做，走 VC 五问，不在本 skill 范围
