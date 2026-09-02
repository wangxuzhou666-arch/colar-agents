export const meta = {
  name: 'expert-panel',
  description: '多专家并发 fan-out + 证据门控 + 对抗验证 + 保留异见的合成（替代手动串行召唤+假装辩论）。支持 budget 驱动的多轮深挖（max 模式）。',
  whenToUse: `需要多个专项视角共同审一个决策/方案/idea 时触发。口语触发词（命中任一即应考虑调用本 workflow）："多专家讨论" / "找几个专家审一下" / "几个角度对抗一下" / "让专家们辩一辩" / "open a panel" / "panel review" / "多视角审"。机制：独立专家并发跑（非串行），每条 claim 证据门控，关键 claim 对抗验证，最后合成时强制保留张力、禁止附和用户既有立场。

【args 契约 —— 调用方唯一读得到的就是这段，别去翻脚本注释】
必填 {question}；选人必须显式传 experts 或 generic:true，否则抛错。
**强烈建议同时传 decision**（"这次要拍的板是什么"，一句话）—— 它是全流程的漂移锚点：
  焊进每个专家/skeptic/critic/synth 的 prompt，并驱动每条 claim 的 decisionImpact 分级，
  而分级正是验证预算的排序键。不传则退化成"拿 question 整句当锚点"，分级质量会掉、
  专家更容易滑进各自领域的细枝末节（2026-09-02 诊断出的漂移根因）。
experts: [{role?, agentType?, lens}] —— 每个元素必须有 lens，且 role/agentType 至少有一个。
  · 推荐 {role, lens}：role 是自由命名的角色（如 "成本结构分析师"），走通用 subagent 靠 prompt 扮演，
    **无注册表依赖**，agent 退役也不会打崩，是 drift-free 的默认姿势。
  · {agentType, lens} 只在确实要那个 agent 的专属 system prompt 时用，且必须逐字取自
    **系统注入的 available agent types**（运行时真相源），不是 agents/INDEX.md（那是库存目录，大多没部署）。
  · 两种可以混在同一个数组里。
其他选填：context（视为事实喂给每个专家）· evalMode（强制 Floor/Base/Optimal 三档）·
  verifyVotes（每条 claim 起手派几个 skeptic，默认 1；**收到硬反证的 claim 会自动追派到 3 票**
    再判杀，所以默认档不需要手动提档 —— 提档只是给"无人反对的 claim"也多花钱）· verifyLow（连 LOW 也验）·
  maxClaims（每个专家最多交几条 claim，默认 5，传 0 = 不限）——**进料闸**：
    每条 claim 派一个 skeptic，所以首轮 agent 数 ≈ 专家数 × maxClaims，不是专家数。
    2026-09-02 实测：无上限时 6 专家跑出 75 agent / 45.8 分钟，其中 69 个是 skeptic。
    要更快就调小它，别去砍专家数或关证据门控（那会砍掉这个 workflow 的全部价值）·
  maxVerifyAgents（skeptic 总数上限，默认 60，传 0 = 不限）——**出口闸，防跑飞**：
    maxClaims 管不住 escalation（收到硬反证的 claim 自动追派到 3 票，发生在入口之后）。
    2026-09-02 实测：一次 resume 从 155 个 agent 涨到 210 且仍在涨。触闸后不再派新 skeptic，
    未验 claim 停在 NOTCHECKED 并计入 runRecord.gatedClaims —— **非零即表示结论有未验部分**，
    收尾会显式播报，不静默。⚠️ 墙钟上限做不了：脚本里 Date.now() 会抛错 ·
  verifyTopK（每个专家最多验几条 claim，默认 3，传 0 = 不限）——**分级闸**：
    按 decisionImpact（DECISIVE > SUPPORTING）× confidence 排序后只验前 K 条，
    decisionImpact=CONTEXT 的一律不验。它与 maxClaims 正交：maxClaims 砍**数量**，
    verifyTopK 砍**优先级错配**（此前唯一的验证门是 confidence，而 confidence 跟
    "这条能不能改变决策"完全正交 ⟹ 一条边角事实和一条致命风险吃掉一样的预算）·
  ⚠️ 未知参数会**直接抛错**（不是忽略）。收到"不认识的参数"报错通常意味着你在跑一份
    **缓存的旧脚本** —— Workflow 按名字解析的定义是 session 级缓存的，已加载过它的 session
    不会重新读盘（2026-09-02 实证：一次 run 白烧 46 分钟 / 5.23M token 才发现四个参数全被吞）。
    开场 log 会打 \`expert-panel v<版本>\`；**看不到这一行就是在跑旧版**。
  cheapVerify（默认 true）——首轮 skeptic 走 sonnet + effort:'low' 只做**分诊**；
    例外：decisionImpact=DECISIVE 的 claim 不走分诊、首票直接上满配（分诊防得住假阳性、
    防不住假阴性，而 2026-09-02 实测 claim 判杀率 24% / 自评 HIGH 占 96%，口子不小）。
    它举手判 REFUTED 才追派 ESCALATE_QUORUM 张满配票复核，且**最终裁决只看满配票**
    （分诊票不参与判杀，所以低配的误判权重为零，只影响"要不要花钱复核"）。
    传 false 回到全满配。·
  leanPrompts（默认 true）——超长的 question / context / evidence / 反证理由在下游
    prompt 里按字数截断并显式标注；≤ 阈值的原样不动。传 false 关掉。·
  depth / maxRounds（多轮深挖）· confidential（禁 web 通道）· budgetFloor · generic。

【返回值与收尾 —— 跑完必做，别把结果留在 chat 里】
返回对象顶层带 star：一份 STAR 结构的呈现层（situation/task/action + headline/scorecard/
confidence/mustFix/contested/shouldFix/keepAsIs/order/pattern），已按主题聚类、已把仓内黑话
翻成人话，直接渲染即可，不要再自己从 perExpert 重新组织一遍。
agreements/tensions/decision/killed 仍在 synthesis 里，是机制产物（证据门控 + 张力保留），
star 与它们同源但重排；两者若矛盾以证据为准，别留两个版本的答案。

收尾三步（Colar 2026-08-28 拍板的默认姿态，除非他说"只要 md"）：
  1. 把 star 渲染成 md 落盘到该项目的 docs/（命名 <主题>-STAR-<YYYY-MM-DD>.md）；
  2. bash ~/Desktop/colar-agents/scripts/compile_md.sh <那个 md 的绝对路径> --open
     → 产出 .html + .pdf 并打开 pdf；
  3. chat 里贴 md 全文（他要在对话里直接读到，不是只给路径）。
为什么必须落盘：上一轮 panel 的对照表只活在 chat 里，session 一关就丢了，隔天要重跑整个 panel 重建。`,
  phases: [
    { title: 'Panel', detail: 'N 个专家并发，各自证据门控产出结构化意见 + 决策影响分级' },
    { title: 'Verify', detail: '按决策影响排序取前 K 条：低配分诊票扫一遍，举手的才追派满配票对抗验证' },
    { title: 'Critic', detail: '漂移校准 + 完整性批判 — 是否偏离决策锚点、还缺什么视角，决定是否再开一轮' },
    { title: 'Synthesize', detail: '丢弃被驳倒的 claim，合成决策，保留 tension 不压平成共识，并产出 STAR 呈现层' },
  ],
}

// ───────────────────────── args 约定 ─────────────────────────
// 契约全文见上方 meta.whenToUse —— 那里是调用方唯一读得到的地方，改契约必须先改那里。
// 本段只记实现层细节，不再重复契约（历史上同一份契约有 4 份互不同步的副本，2026-08-08 收敛）。
//
// ⚠️ harness 在某些环境下把 args 当 JSON 字符串投递（实测 typeof args === 'string'）。
// 脚本控制不了投递方式，所以在此做防御性归一：是 JSON 字符串就 parse；
// parse 失败（传进来的是裸问题字符串、非 JSON）就把整段当 question —— 但裸串因无 experts
// 会在专家解析处 hard-refuse（除非 generic:true），不静默降级成通用盘。
let A = args
if (typeof A === 'string') { try { A = JSON.parse(A) } catch (e) { A = { question: args } } }
if (!A || typeof A !== 'object') A = {}

// ── 版本标识 + 未知参数硬拒（2026-09-02 加，事故驱动）────────────────────────
// 事故：2026-09-02 14:27 的一次 run 传了 verifyTopK / cheapVerify / leanPrompts /
// maxVerifyAgents 四个参数，**四个全被静默吞掉**——因为那个 session 跑的是它自己
// 缓存的旧脚本（快照 42369 字符、无 maxVerifyAgents，比当天 13:38 的 commit 还早，
// 而 run 在近一小时后才启动）。结论：`Workflow({name:'expert-panel'})` 不是每次调用
// 都读盘，已加载过它的 session 会一直用缓存那份；改文件只对**尚未加载过的 session** 生效。
// 代价：调用方以为自己配了一次深思熟虑的 run，实际拿到旧默认行为，白烧 46 分钟 / 5.23M token。
//
// 两道护栏：
// (1) SCRIPT_VERSION 进开场 log —— 旧脚本压根不打这一行，所以**看不到版本行**本身
//     就是"你正在跑缓存的旧版"的信号，不需要额外机制去检测。
// (2) 未知参数 throw 而不是 warn —— 权衡很清楚：throw 的代价是几秒后重来，
//     warn 的代价是上面那 46 分钟。且"调用方的意图静默落空"正是本文件通篇在防的病，
//     对自己的 args 契约不该例外。改契约时**必须同步 bump 版本号和这张表**。
const SCRIPT_VERSION = '2026-09-02b'
const KNOWN_ARGS = new Set([
  'question', 'decision', 'experts', 'generic', 'context', 'evalMode',
  'verifyVotes', 'verifyLow', 'verifyTopK', 'cheapVerify', 'leanPrompts',
  'maxClaims', 'maxVerifyAgents', 'maxRounds', 'depth', 'confidential', 'budgetFloor',
])
const UNKNOWN_ARGS = Object.keys(A).filter(k => !KNOWN_ARGS.has(k))
if (UNKNOWN_ARGS.length) {
  throw new Error(
    `expert-panel(v${SCRIPT_VERSION}): 收到本版本不认识的参数 ${JSON.stringify(UNKNOWN_ARGS)} —— 拒绝开 panel。\n` +
    `这**通常不是拼写错误**，而是你在跑一份缓存的旧脚本：Workflow 按名字解析的定义是 session 级缓存的，\n` +
    `已加载过 expert-panel 的 session 不会重新读盘。开一个新 session 再跑，或改用 scriptPath 显式指向文件。\n` +
    `本版本认识的参数：${[...KNOWN_ARGS].join(' / ')}`
  )
}

// fail-fast：question 缺失/空白直接抛错，绝不下发占位符给专家。
// 静默降级是根因：2026-07-03 字符串投递丢 question 踩过一次；
// 2026-07-06 调用方传了 object 但用了自造 key（无 question 字段）又白烧一整轮（4 专家 ×86k token）。
const Q = (A.question != null && String(A.question).trim()) || null
if (!Q) throw new Error('expert-panel: args.question 缺失或为空 — 拒绝开 panel。最少传 {question: "要审的决策"}，完整 args 契约见 meta.whenToUse。')

// 数值入参归一化（2026-08-08 加）：旧代码用 `||`，显式传 0 会被静默换成默认值 ——
// budgetFloor:0（意图"不设 floor"）变 50000，maxRounds:0（意图"别深挖"）在有 budget 时
// 直接变 12 轮，从最保守跳到最激进。这与文件历史反复修的"静默降级"同根因，只是迁到了数值入参上。
const numArg = (v, dflt) => (typeof v === 'number' && Number.isFinite(v) && v >= 0) ? v : dflt

// leanPrompts（2026-09-02 加）：同一份 Q + CTX 被原样拼进**每一个** agent 的 prompt。
// 实测一次 run 有 75 个 agent ⟹ 长 context 是一笔 75 倍的乘法开销，且下游 skeptic 只需要
// 语境来判"这条 claim 的适用范围"，并不需要全文。刻意做成**只在超长时才截**：短问题
// （绝大多数）一个字不动，避免为了省 token 把小 run 的信息也切掉。
const LEAN = !(A && A.leanPrompts === false)
const clip = (s, n, what) => {
  const t = String(s == null ? '' : s)
  if (!LEAN || t.length <= n) return t
  return `${t.slice(0, n)}\n…（${what}原文共 ${t.length} 字，此处截断至 ${n} 字。截断只影响下游转述，不影响判定——需要全文的信息应由你自己去查证，不要因为看不到全文就判 UNVERIFIABLE）`
}

const CTX_RAW = (A && A.context) ? String(A.context) : ''
const CTX = CTX_RAW ? `\n\n## 已知上下文（视为事实，不要重新质疑其存在性）\n${CTX_RAW}` : ''
// skeptic 侧的瘦身版：CTX 保留（它是"视为事实"的锚，砍了会让 skeptic 把"我无法独立证实
// 这个上下文"当成反证——文件里已为此写过一条 ⚠️ 护栏）；Q 只保留够判定语境的开头。
const CTX_LEAN = CTX_RAW ? `\n\n## 已知上下文（视为事实，不要重新质疑其存在性）\n${clip(CTX_RAW, 800, '上下文')}` : ''
const Q_LEAN = clip(Q, 800, '原问题')

// ── 决策锚点（2026-09-02 加）─────────────────────────────────────────────
// 病灶：专家 prompt 此前只有 Q + lens，没有任何"这次要拍的板是什么"。lens 越具体，
// 专家越容易滑进自己领域的细枝末节，产出一堆"有趣但改变不了决定"的 claim —— 而这些
// claim 会各自吃掉一个完整 skeptic。所以漂移不只是可读性问题，它**直接就是账单**。
// 锚点焊进全部四个通道（专家 / skeptic / critic / synth）：只堵一半是本文件反复踩的坑。
const DECISION = (A && A.decision != null && String(A.decision).trim()) || null
const ANCHOR = `
## 决策锚点（每写一条之前先对一次，防跑题）
本次要拍的板：${DECISION || '（调用方未显式声明 decision —— 以上面「问题」整句为准）'}
判据：一条信息只有在【它成立与不成立会让上面这个板拍得不一样】时，才值得占用验证预算。
"有趣但改变不了这个决定"的观察不要写进 claims —— 放进 recommendation 或 topRisks，
那两处不派 skeptic、不占预算，照样会被读到。`

const EVAL = !!(A && A.evalMode)
// VOTES 强制取奇数（2026-08-08）：多数判据 `hard > vs.length/2` 在偶数票下退化成**要求全票**
// —— VOTES=2 时需 2/2，比 VOTES=1 更难杀假 claim 却贵一倍，是纯粹的陷阱档位。
// 向上取奇（2→3）保留"收紧检方"的语义方向，只消除这个边界。
const RAW_VOTES = Math.max(1, numArg(A && A.verifyVotes, 1))
const VOTES = RAW_VOTES % 2 === 0 ? RAW_VOTES + 1 : RAW_VOTES
const VERIFY_LEVELS = (A && A.verifyLow) ? ['HIGH', 'MEDIUM', 'LOW'] : ['HIGH', 'MEDIUM']
// MAX_CLAIMS（2026-09-02 加）：墙钟正比于 claim 总数，不是专家数。实测一次 6 专家的 run
// 跑出 75 个 agent / 45.8 分钟，其中 69 个是 skeptic（92%）—— 因为专家产出多少条 claim
// 就派多少个 skeptic，而此前**没有任何上限**，平均每人吐 11.5 条。
// 上限不砍机制只砍凑数：专家被迫自己排序、只交最关键的几条，边缘 claim 不再各吃一个
// 完整 skeptic。设 0 表示不限（回到旧行为）。
const MAX_CLAIMS = numArg(A && A.maxClaims, 5)
// MAX_VERIFY_AGENTS（2026-09-02 加）：出口闸。maxClaims 管进料，管不住 escalation ——
// 收到硬反证的 claim 会自动追派到 ESCALATE_QUORUM 票，这一步发生在入口之后，
// 所以单靠 maxClaims 无法给总规模封顶。2026-09-02 实测：一次 resume 从 155 个 agent
// 一路涨到 210 且仍在涨，而脚本此前只有轮数上限（HARD_ROUND_CAP），没有 agent 数上限。
// ⚠️ 墙钟做不了：脚本里 Date.now() 会抛错（为了 resume 可复现），只能按计数封顶。
// 触闸后不再派新 skeptic，未验的 claim 保持 NOTCHECKED 并计入 runRecord.gatedClaims ——
// **绝不静默**：「没验」长得像「验过没问题」正是本文件反复在修的那类病。
const MAX_VERIFY_AGENTS = numArg(A && A.maxVerifyAgents, 60)
// VERIFY_TOP_K（2026-09-02 加）：**分级闸**。此前唯一的验证门是 confidence
// （`VERIFY_LEVELS.includes(c.confidence)`），而 confidence 测的是"专家对这条有多确定"，
// 跟"这条能不能改变决策"完全正交 —— 于是一条 HIGH 的边角事实和一条 HIGH 的致命风险
// 吃掉一模一样的验证预算。maxClaims 是钝刀：它砍数量，砍不掉这个错配。
// 新门：按 decisionImpact × confidence 排序，只验前 K 条，CONTEXT 档一条不验。
// 被跳过的**不静默** —— 计入 triagedClaims，收尾播报，digest 里标 policy=TRIAGED。
const VERIFY_TOP_K = numArg(A && A.verifyTopK, 3)
// CHEAP_VERIFY（2026-09-02 加）：单价闸。实测 92% 的 agent 是 skeptic，而每个 skeptic
// 都是满配（拿全量 Q+CTX、要实际 grep/web）。绝大多数 skeptic 的结论是 HOLDS ——
// 用满配去确认"没问题"是最贵的一种确认。改成两档：
//   分诊票（sonnet + effort:low）只回答"这条有没有明显问题"；
//   它举手才追派 ESCALATE_QUORUM 张满配票，且**判杀只看满配票**（见 tallyVotes 的 tier 过滤）。
// 所以低配的误判权重是零：它只能决定"要不要花钱复核"，不能决定"杀不杀"。
const CHEAP_VERIFY = !(A && A.cheapVerify === false)
const CHEAP_OPTS = CHEAP_VERIFY ? { model: 'sonnet', effort: 'low' } : {}
const BUDGET_FLOOR = numArg(A && A.budgetFloor, 50000)
const HARD_ROUND_CAP = 12 // runaway 兜底：即使预算充足也不超过这么多轮
const DEPTH = !!(A && A.depth === true) // 一键深挖：无需手动传 budget 也触发多轮（critic 门控，DEPTH_ROUND_CAP 封顶）
const DEPTH_ROUND_CAP = 4 // depth:true 时的轮数上限（靠 critic.complete 提前收口，这只是兜底）
// 保密模式：置位后剥掉全流程的 web 通道。见下方 CONFIDENTIAL_RULE / VERIFY_METHODS / PROBE_CHANNELS。
const CONFIDENTIAL = !!(A && A.confidential === true)

// 轮数策略（2026-08-08 改：budget 从"触发器"降级为"闸门"）。
// 旧行为：`budget && budget.total ? HARD_ROUND_CAP : ...` —— 只要 runtime 注入了 budget，
// 每次调用就悄悄变成最多 12 轮。实测 139 次留存 run 中 budget 全为 none，该分支从未被执行过，
// 所以这个"深挖能力"一直是空头支票，同时又是一颗定时炸弹（harness 哪天默认给 budget.total 就引爆）。
// 新行为：只有显式 maxRounds 或 depth:true 才多轮；budget 仅在已经多轮时用来提前收口（见主循环预算闸）。
const RAW_MAX = numArg(A && A.maxRounds, null)
const MAX_ROUNDS = RAW_MAX != null
  ? Math.min(Math.max(1, RAW_MAX), HARD_ROUND_CAP)
  : (DEPTH ? DEPTH_ROUND_CAP : 1)

// 专家来源：显式 experts > 写死通用盘（须 generic:true 显式 opt-in）。
// 2026-08-08：agentRoster + selector 路径已删除 —— 139 次留存 run 里 castMode='selector' 真实调用 0 次，
// 且结构上也不会被走到：调用方是主 loop 自己，能拼出 agentRoster 就说明已经枚举过池子，直接传 experts 更省一个 agent。
const hasExplicitExperts = !!(A && Array.isArray(A.experts) && A.experts.length)
const GENERIC_OK = !!(A && A.generic === true) // 显式要通用默认盘的逃生舱；无 experts 且无此标志 → 拒绝（禁静默降级）
const GENERIC_PANEL = [
  // 2026-08-05：本盘四席全面去 agentType 化，只留一个确定存在的内置 agent。起因是三个死名——
  // Software Architect / Security Engineer（2026-08-04 退役）+ Trend Researcher（master 库有
  // product/product-trend-researcher.md，但从未部署到 ~/.claude/agents/、也未 sync 进任何 project
  // ⟹ 库存 ≠ 可调用，正是 CLAUDE.md 路由协议警告的 INDEX.md 陷阱）。
  // 2026-08-08 更正前注：非法 agentType **不会**让 agent() 直接崩 —— pipeline 用 allSettled，
  // 单个 slot 抛错只变成 null 被下方 filter(Boolean) 吃掉，是**静默降级**：盘悄悄少一席、
  // castMode 仍显示 explicit，比崩更难发现。这也是下方 validateExperts 存在的理由。
  // 修法不变：除内置 Plan 外一律用 role 走通用 subagent prompt 扮演——role 无注册表依赖；lens 原样保留。
  // 核 agent 名请看**系统注入的 available agent types**（运行时真相源），不是 ls ~/.claude/agents/
  // （那只列自定义 agent，看不到 Plan/Explore/general-purpose 等内置项），更不是 agents/INDEX.md。
  { role: 'Trend Researcher',          lens: '市场/竞品/外部真实验证 — 有没有人已经做、为什么没成' },
  { role: 'Product Manager',           lens: '用户 JTBD、真实需求强度、distribution 现实' },
  { agentType: 'Plan',                 lens: '实现复杂度、技术风险、最小可行路径' },
  { role: 'Security Engineer',         lens: '隐私/安全/凭证/数据暴露面' },
]

// ───────────────────────── 入席 deny-list（形态冲突，不是配置问题）─────────────────────────
// callee 视角写的保密条款在被 fan-out 时**不 fire**：verify skeptic（见 runRound stage2）是不继承
// 任何 agent 侧约束的通用 subagent，却拿到 claim+evidence 原文并被明确指示可走 web 查证。
// 所以把一个 CONFIDENTIAL agent 放进席位，等于它自己关了 web、转手被验证者代为搜出去。
// 另有形态冲突：VC 模型 Critic 自述是「不是 reviewer 给一次性 verdict，是 dialogue partner 追问」，
// 有 boot sequence 和需人作答的 Phase-0 闸门，塞不进一次性 EXPERT_SCHEMA 席位。
// 散文护栏已被实证无效（memory 早写明"lens 素材库，非 spawn 名单"，实测仍被 cast 22 次、
// 派出 188 个可走 web 的 skeptic），故焊进代码。要 VC 视角就先跑 /vc模型，把结论当 context 喂进来。
const DENY_AGENTS = new Map([
  ['VC 模型 Critic', '它是 dialogue partner + CONFIDENTIAL agent，形态与一次性 panel 席位冲突，且其保密条款在 fan-out 时不 fire。先跑 /vc模型，再把结论当 context 传进 panel 让别的视角去打它。'],
])

// experts 元素级校验（2026-08-08 加）：最被推荐的 explicit 路径此前对元素形状零校验，
// 而次要的 selector 路径反而有白名单 —— drift 暴露面刚好开在主路径上。
// 传 experts:['Code Reviewer','Plan'] 这种自然手写形态会让 roleName 落到 '专家'、
// lens 渲染成字面量 undefined，castMode 仍显示 'explicit'，是标准的静默质量悬崖。
function validateExperts(list) {
  list.forEach((e, i) => {
    const at = `experts[${i}]`
    if (!e || typeof e !== 'object' || Array.isArray(e)) {
      throw new Error(`expert-panel: ${at} 不是对象（收到 ${JSON.stringify(e)}）。每个元素必须是 {role?, agentType?, lens}，契约见 meta.whenToUse。`)
    }
    const name = e.agentType || e.role
    if (typeof name !== 'string' || !name.trim()) {
      throw new Error(`expert-panel: ${at} 缺 role/agentType（至少要有一个非空字符串）。推荐用 {role, lens} —— 无注册表依赖。`)
    }
    if (typeof e.lens !== 'string' || !e.lens.trim()) {
      throw new Error(`expert-panel: ${at}（${name}）缺 lens。lens 是"这一次要它专门挖什么"，不能省 —— 省了等于派一个没有视角的通用 agent。`)
    }
    if (e.agentType && DENY_AGENTS.has(e.agentType)) {
      throw new Error(`expert-panel: ${at} 的 agentType「${e.agentType}」不得入席 —— ${DENY_AGENTS.get(e.agentType)}`)
    }
  })
}

// ───────────────────────── 质量门控（焊进每个专家 prompt）─────────────────────────
// ⚠️ 2026-08-08 实测发现：**纯散文纪律对置信度通胀基本无效**。反通胀条款（下方第 5 条）上线一个月后，
// HIGH 占比 pooled 69.2%、8 月中位 77.4%，比修前的 73.0% 更高。结论：不要再往这里加第六条纪律，
// 可机器判定的规则一律搬进 JS（见 majorityVerdict 的证据门 / effectiveStrength）。
const EVIDENCE_KINDS = CONFIDENTIAL
  ? '代码 file:line / grep|ls 输出 / 具体数据（本次禁外部检索，URL 不算合格证据）'
  : '代码 file:line / grep|ls 输出 / 外部可点 URL / 具体数据'
const VERIFY_METHODS = CONFIDENTIAL
  ? ['code', 'data', 'logic', 'none']
  : ['code', 'web', 'data', 'logic', 'none']
const PROBE_CHANNELS = CONFIDENTIAL ? 'grep/ls/read' : 'grep/ls/read/web'

// ── 探测通道显式授权（2026-09-02 加）─────────────────────────────────────
// 病灶：verify prompt 一直明确给了 PROBE_CHANNELS，而**专家 prompt 一个字都没提**。
// 于是"专家该不该去实际查证、能不能调 skill、web 工具怎么载入"全靠模型自己猜，
// 结果是大量纯推理 claim 被自评成 HIGH（历史审计的置信度通胀，散文反通胀条款已被实证无效）。
// 关键实现细节：WebSearch/WebFetch 在本 harness 里是 **deferred 工具**，schema 不在
// context 里，直接调会 InputValidationError —— 必须先 ToolSearch 载入。不写明这一点
// 等于给了通道却没给钥匙。
const PROBE_KIT = `
## 你的探测通道（用起来，别只靠推理）
- 读码 / 搜索：Read · Grep · Glob · Bash（ls / grep / sed -n）—— 有仓库就先去仓库里看
- 专项打法：若有与本题匹配的 Skill，直接用 Skill 工具调它，别自己重造流程${CONFIDENTIAL ? '' : `
- 外部检索：WebSearch / WebFetch —— 它们是 deferred 工具，**先 \`ToolSearch "select:WebSearch,WebFetch"\` 载入 schema 再调**，直接调会报 InputValidationError`}
- 其他工具（含 MCP）：\`ToolSearch\` 按关键词捞，同样先载 schema 再调

纪律：**至少跑一次真实探测再下结论。** 全程只靠推理得出的 claim，confidence 上限是 MEDIUM——
这不是谦虚，是 HIGH 这一档的定义（已实际查证、证据在手）。`

const CONFIDENTIAL_RULE = CONFIDENTIAL ? `

## 保密硬约束（本次 run 置位 confidential:true，全程不解除）
- ❌ 禁用 WebSearch / WebFetch —— 问题里的关键词不得外泄到任何外部服务。
- 引用问题内容时用抽象描述，不要逐字复制可识别的专有名词/公司名/技术栈组合。
- 因此查不了的 claim 直接标 UNVERIFIED 并写清缺什么证据，绝不为了补证据走外部检索。` : ''

// critic 与 synthesize 也是**不继承任何调用方约束的通用 subagent**，而它们的 prompt 同样拼了原问题 Q。
// 2026-08-08 第一版只把保密条款接进 GROUND_RULES（panel prompt）和 verify prompt，漏了这两条通道 ——
// 保密 run 下问题原文照样流进两个没有禁 web 条款的 agent。这是"只堵一半"的典型，补齐。
const CONFIDENTIAL_NOTE = CONFIDENTIAL ? `

## 保密硬约束（本次 run 置位 confidential:true）
❌ 禁用 WebSearch / WebFetch —— 上面的问题与专家产出不得外泄到任何外部服务。
你的任务是整合已有材料，不需要也不允许外部检索；材料不足就如实说不足。` : ''

const GROUND_RULES = `
## 输出纪律（违反即视为低质量产出）
1. 证据门控：每条 claim 必须附证据 —— ${EVIDENCE_KINDS}。
2. 反编造：无法验证的 claim 一律标 confidence="UNVERIFIED" 并说明缺什么证据；绝不 fabricate 数据/URL/"我跑了发现 X"。能力上做不到的（如无浏览器跑不了实测）直说做不到，不要假装。
3. 反复读 prompt：不要把问题换个说法复述当结论。只报你独立查证后新增的信息。
4. 反附和：你的任务是给独立专业判断，不是迎合提问者预期。证据指向反直觉结论时，照实报。
5. 置信度别通胀 + 标验证方式：HIGH 只给"已实际查证、证据在手"的 claim；只推理没查证 = 最多 MEDIUM；没查证但合理 = LOW；查不了 = UNVERIFIED（历史审计发现 75% claim 被标 HIGH = 通胀，别再这样）。每条 claim 标 verifyMethod（${VERIFY_METHODS.join('｜')}）指明该怎么验。${MAX_CLAIMS ? `
6. **claims 最多 ${MAX_CLAIMS} 条，这是硬上限。**每条都会被独立 skeptic 逐条对抗验证，所以多交等于让边缘判断挤掉关键判断的验证预算。自己先排序，只交最能改变决策的那几条；宁可 ${MAX_CLAIMS} 条全是硬的，也不要凑满。想说但够不上前 ${MAX_CLAIMS} 的，写进 recommendation 或 topRisks，那两处不派 skeptic。` : ''}
7. **每条 claim 必须标 decisionImpact，对着上面的「决策锚点」判，不是对着你的专业兴趣判。**
   · DECISIVE = 这条被推翻，上面那个板就得拍成另一个样子；
   · SUPPORTING = 改变的是"怎么做 / 先做哪个"，不改变"做不做"；
   · CONTEXT = 背景信息，任何一种结果都不改变任何决定。
   ${VERIFY_TOP_K ? `验证预算按 DECISIVE → SUPPORTING 排序发放，每人只验前 ${VERIFY_TOP_K} 条，**CONTEXT 档一条都不验**。` : '**CONTEXT 档不派验证。**'}   注意 DECISIVE 换来的**不是优待而是更严的审查**：它会跳过快速分诊、直接由满配的对抗验证者逐条查证。所以虚标 DECISIVE 既挤掉你自己真正关键那条的名额，又把这条送去更容易被推翻的通道——诚实分级才是对你有利的。DECISIVE 按定义应当是少数（多数结论改变的是"怎么做"，不是"做不做"）。${CONFIDENTIAL_RULE}`

const EVAL_RULES = EVAL ? `
8. 三档锚点（强制）：给 Floor（保守可达）/ Base（现实最可能）/ Optimal（最优情形）三档，不要只给 Optimal。` : ''

// ───────────────────────── schema ─────────────────────────
const EXPERT_SCHEMA = {
  type: 'object',
  required: ['summary', 'claims', 'recommendation', 'topRisks'],
  properties: {
    summary: { type: 'string', description: '该视角下的一句话核心判断' },
    claims: {
      // maxItems 与 GROUND_RULES 第 6 条是同一个约束的两层：prompt 讲清为什么，schema 兜住
      // 不听话的模型。只靠 prompt 时实测会被无视（一次 run 平均每人吐 11.5 条）。
      type: 'array', description: `支撑判断的关键 claim，每条带证据${MAX_CLAIMS ? `（最多 ${MAX_CLAIMS} 条，每条都会被独立 skeptic 验，别凑数）` : ''}`,
      ...(MAX_CLAIMS ? { maxItems: MAX_CLAIMS } : {}),
      items: {
        type: 'object',
        required: ['claim', 'evidence', 'confidence', 'verifyMethod', 'decisionImpact'],
        properties: {
          claim: { type: 'string' },
          evidence: { type: 'string', description: 'file:line / grep 输出 / URL / 数据；无则写缺什么' },
          confidence: { type: 'string', enum: ['HIGH', 'MEDIUM', 'LOW', 'UNVERIFIED'] },
          // 进 required 是刻意的（与 evidenceRefs 的"刻意不进 required"相反）：
          // 缺 decisionImpact 会让 JS 侧的分级排序整条失效并静默回退成"按 confidence 排"，
          // 也就是回到本次要修的那个 bug。这里宁可让模型重试，也不接受静默降级。
          decisionImpact: {
            type: 'string', enum: ['DECISIVE', 'SUPPORTING', 'CONTEXT'],
            description: '对着决策锚点判：DECISIVE=推翻这条，那个板就得拍成另一样｜SUPPORTING=只改变怎么做/先做哪个，不改变做不做｜CONTEXT=背景，任何结果都不改变任何决定（CONTEXT 不派验证）',
          },
          verifyMethod: { type: 'string', enum: VERIFY_METHODS, description: '这条 claim 该用哪种方式验证：code=读码/grep｜web=外部检索｜data=跑数据/查询｜logic=纯推理｜none=不可验证。' },
        },
      },
    },
    recommendation: { type: 'string' },
    topRisks: { type: 'array', items: { type: 'string' } },
  },
}

// 证据的结构化载体（2026-08-08 加）。此前证据只能落在自由散文 reason 里，JS 侧只能对它跑正则，
// 实测该正则近乎常真函数：REFUTED 的 reason 过门 94.8% vs HOLDS 的 reason 过门 91.9%，
// 似然比≈1.03 —— 它测的不是"有没有证据"，而是"这段中文里有没有出现类 ASCII 锚点"。
// 被它拦下的 31 条里 30 条其实带真锚点（L284 / line 392 / 第X行 / 裸路径），拒绝侧精度≈0。
// 修法不是继续调正则（在近乎常真的维度上调参只是换个摆的方向），而是给证据一个字段，
// 让 JS 只校验元素格式 —— 与本文件 :422 自己写的"可机器判定的规则不留在散文层"一致。
const EVIDENCE_REF_KINDS = CONFIDENTIAL
  ? ['file_line', 'command', 'data', 'quote']
  : ['file_line', 'command', 'url', 'data', 'quote']

const VERDICT_SCHEMA = {
  type: 'object',
  required: ['verdict', 'refutationStrength', 'reason'],
  properties: {
    verdict: { type: 'string', enum: ['HOLDS', 'REFUTED', 'UNVERIFIABLE'] },
    refutationStrength: { type: 'string', enum: ['HARD', 'WEAK', 'NA'], description: 'verdict=REFUTED 时必填：HARD=有具体反证(file:line/命令输出/URL/数据)；WEAK=仅推理或"查无确证"。非 REFUTED 一律 NA。注意：自称 HARD 但 evidenceRefs 为空、且 reason 里也没有可核验锚点的，会在 JS 侧被自动降为 WEAK。' },
    reason: { type: 'string', description: '为什么 —— 附反证或确证的具体证据' },
    // 刻意不进 required：这是新字段，遵守率未知，而"硬要求"的失败模式正是本次诊断出的病
    // （把 kill 通道整条关掉）。JS 侧走 evidenceRefs OR 放宽正则的双通道，见 effectiveStrength。
    evidenceRefs: {
      type: 'array',
      description: 'verdict=REFUTED 且 refutationStrength=HARD 时必填至少 1 条。每条是一个你**实际查到**的可核验锚点，不是转述。禁止编造：查不到就别填，改判 WEAK 或 UNVERIFIABLE。',
      items: {
        type: 'object',
        required: ['kind', 'ref'],
        properties: {
          kind: { type: 'string', enum: EVIDENCE_REF_KINDS, description: 'file_line=代码位置｜command=你实际跑过的命令｜data=具体数字/统计｜quote=原文引用' + (CONFIDENTIAL ? '（本次保密 run 已禁 url）' : '｜url=外部可点链接') },
          ref: { type: 'string', description: 'file_line 填 path:line（如 workflows/expert-panel.js:446）｜command 填带参数的完整命令｜url 填 http(s) 链接｜data 填指标名｜quote 填出处' },
          value: { type: 'string', description: '你在那里实际看到的内容/数值。强烈建议填 —— 只有 ref 没有 value 的证据无法被后续复核。' },
        },
      },
    },
  },
}

// 完整性批判：决定是否再开一轮 + 下一轮派谁。刻意只产 lens（视角描述），
// 不强制 agentType —— critic 动态造的 agentType 大概率不在注册表里，会被静默吞成 null，
// 所以下一轮统一用通用 subagent 靠 prompt 扮演（见 runRound 的 agentType 处理）。
// 2026-09-02：加 drift/driftNote。此前 critic 的动作集只有 {complete, gaps, nextExperts}，
// 也就是**它唯一能做的事是再加专家** —— 结构上是一台单向发散棘轮，永远不会把话题拽回来。
// Colar 的原话："希望有一个锚定的论点，而不是让 subagent 过度发散。"
// 现在给它第二个动作：判本轮是否已经在回答别的问题。判 SEVERE 直接收口，不再开新轮
// （多开一轮 = 在已经跑偏的方向上再花 N 个专家 + N×K 个 skeptic，是最贵的一种错）。
const CRITIC_SCHEMA = {
  type: 'object',
  required: ['complete', 'drift', 'driftNote', 'gaps', 'nextExperts'],
  properties: {
    complete: { type: 'boolean', description: '覆盖是否已足够 —— 再加视角无新增边际价值时为 true。宁缺毋滥，不要为多而多。' },
    drift: {
      type: 'string', enum: ['ON_TARGET', 'MILD', 'SEVERE'],
      description: '本轮产出相对「决策锚点」的偏离度：ON_TARGET=都在回答那个板｜MILD=有部分跑题但主线还在｜SEVERE=主线已经在回答另一个问题了。判 SEVERE 会直接终止深挖——所以别为了显得严格而滥用，也别因为产出"看起来很专业"就放过跑题。',
    },
    driftNote: { type: 'string', description: 'drift 的依据：具体哪几条产出偏离了锚点、偏到哪去了。ON_TARGET 时写"无"。' },
    gaps: { type: 'array', items: { type: 'string' }, description: '还缺的：未覆盖的视角 / 未验证的关键 claim / 没跑的查证方式' },
    nextExperts: {
      type: 'array',
      description: '下一轮要派的专家（仅 complete=false 时填）。每个针对一个具体 gap，不要重复已覆盖的视角。',
      items: {
        type: 'object',
        required: ['role', 'lens'],
        properties: {
          role: { type: 'string', description: '该专家扮演的角色名（自由命名，如 "成本结构分析师"）' },
          lens: { type: 'string', description: '这一轮要这个角色专门挖的 gap' },
        },
      },
    },
  },
}

// ── STAR 呈现层（2026-08-28 加）────────────────────────────────────────────
// 为什么是新增字段而不是替换 agreements/tensions/decision：那三个是**机制产物**，
// 承载证据门控与"张力不得压平"的纪律，下游（runRecord 统计、killed 封闭清单覆盖）也在读它们。
// 动它们等于把对抗验证的骨架和呈现格式绑死。star 是纯呈现层，从同一批 claim 二次组织，
// 坏了只损失可读性、不损失结论。
//
// 病灶（Colar 2026-08-28）：panel 报告"读起来非常困难"。实测三个根因——
//   ① 按专家分栏 ⟹ 同一个毛病散在 5 个地方，读者要自己做 join；
//   ② 满篇仓内黑话（fail-closed / 锚点 / 契约门 / tripwire），术语密度高于信息密度；
//   ③ 决策所需的"要不要现在动手"埋在论证里，得读完全文才能排序。
// star 逐条对治：按主题聚类（不按专家）、强制翻译黑话、按动手紧迫度分桶。
const STAR_SCHEMA = {
  type: 'object',
  required: ['situation', 'task', 'action', 'headline', 'confidence', 'mustFix', 'shouldFix', 'order'],
  properties: {
    situation: { type: 'string', description: 'S — 背景：为什么会有这次 panel。1-3 句，说清"在什么状态下开审的"' },
    task: { type: 'array', items: { type: 'string' }, description: 'T — 这次要回答的问题，每条一句话，通常 2-4 条' },
    action: { type: 'string', description: 'A — 怎么做的，1-2 句封顶。读者不关心过程，**不要**展开方法论' },
    headline: { type: 'string', description: 'R 的第一行：整场结论压成一句话。要能单独拎出来当结论用' },
    scorecard: {
      type: 'array', description: '打分表 —— 仅当各专家给了 self_score 时填；非评分类 panel 给空数组',
      items: {
        type: 'object', required: ['dimension', 'score', 'note'],
        properties: {
          dimension: { type: 'string', description: '维度名，用人话（"前后端契约"而非 "contract"）' },
          score: { type: 'string', description: '分数，如 "8.0"' },
          delta: { type: 'string', description: '相比上次基线的方向，如 "↓ 从 7.5" / "—"（无基线时给 "—"）' },
          note: { type: 'string', description: '一句话说明扣分/加分落在哪条轴上' },
        },
      },
    },
    confidence: { type: 'string', description: '一句话交代结论可信度：多少条确认 / 多少条存疑 / 多少条被推翻' },
    mustFix: {
      type: 'array', description: '必须现在动手的（**只能取 status=KEPT 的 claim**）',
      items: {
        type: 'object', required: ['problem', 'hurt', 'fix'],
        properties: {
          problem: { type: 'string', description: '问题是什么，人话，一句话讲完' },
          hurt: { type: 'string', description: '**会怎么疼** —— 具体后果，不是抽象风险。有实测数字就带上' },
          fix: { type: 'string', description: '怎么修，给到能直接动手的粒度' },
        },
      },
    },
    contested: {
      type: 'array', description: '有争议但值得看的（**只能取 status=CONTESTED / UNVERIFIABLE 的 claim**）',
      items: {
        type: 'object', required: ['problem', 'whyDisputed', 'read'],
        properties: {
          problem: { type: 'string' },
          whyDisputed: { type: 'string', description: '**必须分清争的是"事实成不成立"还是"有多严重"** —— 这两者对读者的意义完全不同' },
          read: { type: 'string', description: '你的读法：综合看该不该动它，给个明确倾向' },
        },
      },
    },
    shouldFix: {
      type: 'array', description: '该修但不急 —— **必须按问题主题聚类，严禁按专家分栏**（同一个毛病散在多处正是可读性的头号杀手）',
      items: {
        type: 'object', required: ['theme', 'items'],
        properties: {
          theme: { type: 'string', description: '主题名，说清这簇的共同形状，如"检查机制本身没被检查"' },
          items: { type: 'array', items: { type: 'string' }, description: '该主题下各条，每条一行讲完' },
        },
      },
    },
    keepAsIs: { type: 'array', items: { type: 'string' }, description: '做得好、别动的地方。防"只报忧"导致的失真' },
    order: { type: 'array', items: { type: 'string' }, description: 'R 的落地：建议动手顺序，带时间档（今天 / 本周 / 有空）' },
    pattern: { type: 'string', description: '（可选）跨多条 finding 反复出现的同一形状，及其根因。没有就留空' },
  },
}

const SYNTH_SCHEMA = {
  type: 'object',
  required: ['agreements', 'tensions', 'decision', 'killed', 'star'],
  properties: {
    star: STAR_SCHEMA,
    agreements: { type: 'array', items: { type: 'string' }, description: '多专家独立达成的共识（非互抄）' },
    tensions: {
      type: 'array', description: '真实分歧 —— 必须保留，不许压平成共识',
      items: {
        type: 'object',
        required: ['axis', 'sideA', 'sideB'],
        properties: {
          axis: { type: 'string', description: '分歧轴' },
          sideA: { type: 'string' },
          sideB: { type: 'string' },
        },
      },
    },
    decision: { type: 'string', description: EVAL ? 'Floor/Base/Optimal 三档建议' : '综合建议' },
    killed: { type: 'array', items: { type: 'string' }, description: '被对抗验证驳倒、已剔除的 claim' },
  },
}

// ───────────────────────── 证据门 + 票数聚合 ─────────────────────────
// ⚠️ 位置要求：本区块必须在 runRound 之前 —— stage2 的定向升级要调 effectiveStrength，
// 而 const 不 hoist（TDZ）。2026-08-08 前它住在文件末尾，那时只有 synthesize 阶段用它。
//
// 判据分两条通道 OR：
// (1) 主通道 evidenceRefs（结构化，JS 只校验元素格式，不读散文）；
// (2) fallback 放宽正则（仅在 skeptic 没填 evidenceRefs 时兜底）。
// 为什么留 fallback：evidenceRefs 是新字段、遵守率未知，而"硬要求结构化证据"的失败模式
// 恰是本次诊断出的病 —— 把 kill 通道整条关掉，还长得像"本轮没有假 claim"。
// fallback 刻意比旧版**更宽**：实测被旧正则拦下的 31 条里 30 条带真锚点，拒绝侧精度≈0，
// 失败轴是书写记法（L284 / line 392 / 第X行 / 全角冒号 / 单反引号引码 / 白名单外命令）而非勤奋。
const EVIDENCE_MARK = new RegExp([
  '[\\w\\u4e00-\\u9fff./-]+\\.[A-Za-z]{1,5}\\s*[:：#]\\s*L?\\d+', // path.ext:123 / path.ext：123 / path.ext#L12
  '[\\w\\u4e00-\\u9fff./-]+\\.[A-Za-z]{1,5}\\s+(?:line|L)\\s*\\d+', // path.ext line 392
  '[\\w\\u4e00-\\u9fff-]+/[\\w\\u4e00-\\u9fff./-]+\\.[A-Za-z]{1,5}', // 带目录的裸路径（无行号）
  '第\\s*\\d+\\s*行',                    // CJK 行号记法；「第」必须在 —— 设为可选会把「709 行」这类数量词算进来
  '\\bL\\d+\\b',                         // L284 记法
  'https?://',
  '```',
  '`[^`\\n]{3,}`',                       // 单反引号引码（实测真实高频桶之一）
  // 命令词分两组：像英语单词的那些不能只要求"后面跟点什么"。
  // 实测误放样本全出在这里：「an ls of the repo shows nothing」「a wc of the file」——
  // `ls\s+[-\w]` 会把 "of" 的 o 认成参数。所以 ls/wc/cat/head/tail/find 必须跟 -flag 或带 ./ 的路径。
  '\\b(?:grep|rg|sed|awk|git|node|python3?|jq|curl|diff|npm|pytest)\\s+[-\\w\'"/.]',
  '\\b(?:ls|wc|cat|head|tail|find|du|sort|uniq)\\s+(?:-{1,2}\\w|[\\w./-]*[./][\\w./-]*)',
].join('|'), 'i')

// evidenceRefs 元素级校验：只看形状，不判断内容真假（那是 skeptic 的职责，JS 判不了）。
// 哪些 kind 算硬锚点**只由下面的 switch 表达**——曾经还有一个 HARD_REF_KINDS 集合做前置过滤，
// 两处重复表达同一规则，结果是往集合里加 kind 根本不改变行为（突变测试逮到的等价变异体）。
// 单一判据即单一真相源：quote 没有 case 分支，所以引文不单独构成硬锚点——不指明出处无法复核。
function isUsableRef(r) {
  if (!r || typeof r !== 'object') return false
  const ref = String(r.ref || '').trim()
  if (ref.length < 3) return false
  const val = String(r.value || '')
  switch (r.kind) {
    case 'file_line': return /\d/.test(ref) && /[./\\]/.test(ref)   // 要有位置感：路径味 + 数字
    case 'command': return /\S\s+\S/.test(ref)                       // 命令必须带参数（"我没 grep 过"不算）
    case 'url': return /^https?:\/\//i.test(ref)
    case 'data': return /\d/.test(ref) || /\d/.test(val)             // 指标必须落到某个数
    default: return false
  }
}

const effectiveStrength = v => {
  if (!v || v.verdict !== 'REFUTED') return 'NA'
  if (v.refutationStrength !== 'HARD') return 'WEAK'
  const refs = Array.isArray(v.evidenceRefs) ? v.evidenceRefs : []
  if (refs.some(isUsableRef)) return 'HARD'                          // 主通道
  return EVIDENCE_MARK.test(String(v.reason || '')) ? 'HARD' : 'WEAK' // fallback
}

// 定向升级的法定人数：单票 HARD 不直接杀，而是**只对这一条 claim** 追派到 3 票、2/3 才杀。
// 为什么不全局 VOTES=3：实测 90% 的历史 run 跑默认 1 档，全局提档的开销 80% 花在无人反对的
// claim 上（约 +82 次调用 vs 定向 +16）。为什么不允许单票杀：单票杀权是上一轮判定的误杀源。
const ESCALATE_QUORUM = 3

// 分级排序键（2026-09-02 加）。刻意做成 JS 侧的确定性排序而不是"让专家自己只交重要的" ——
// 散文纪律对排序的约束力和它对置信度通胀的约束力是同一个量级（本文件 :168 已实证为近零）。
// 位置要求同 effectiveStrength：必须在 runRound 之前，const 不 hoist。
const IMPACT_RANK = { DECISIVE: 0, SUPPORTING: 1, CONTEXT: 2 }
const CONF_RANK = { HIGH: 0, MEDIUM: 1, LOW: 2, UNVERIFIED: 3 }

// 票分两档（2026-09-02 加，配合 cheapVerify）：
//   tier='cheap' = 分诊票（sonnet + effort:low），职责只有"要不要花钱复核"；
//   tier='full'  = 满配票，唯一有表决权的那种。
// 聚合规则：这条 claim 上只要出现过满配票，就**只用满配票**裁决；一张都没有
// （= 分诊没举手，从未触发追派）才回落到分诊票。
// 为什么不让分诊票参与投票：低配模型的假阳性会直接变成误杀，而误杀是本文件历史上最贵的
// 一类错误（真话被弱反证打掉，输出还长得像"验过了"）。给它提名权、不给表决权，
// 低配误判的成本上限就锁死在"多花 ESCALATE_QUORUM 张满配票"，永远污染不了结论。
// cheapVerify=false 时首轮票本身就是 full，本函数行为与 2026-09-02 之前完全一致。
function tallyVotes(verdicts, claim) {
  const all = (verdicts || []).filter(v => v && v.claim === claim)
  const full = all.filter(v => v.tier !== 'cheap')
  const vs = full.length ? full : all
  return {
    vs, all, fullCount: full.length,
    hard: vs.filter(v => effectiveStrength(v) === 'HARD').length,
    weak: vs.filter(v => effectiveStrength(v) === 'WEAK').length,
  }
}

// 聚合：标出每条被验证 claim 的多数裁决。
// 2026-08-08 第二轮修 contest 侧（第一轮只修了 kill 侧，留下单向棘轮）：
// 旧 `if (anyRefuted > 0) return 'CONTESTED'` 完全不看 effectiveStrength —— 一张被降为 WEAK
// 的孤票（即空口怀疑）就能把已验证 claim 打成"存疑，不得当既定事实"，而 kill 侧要 ≥2 票且过半，
// 且全函数没有任何把 CONTESTED 升回 KEPT 的分支 ⟹ 验证阶段只能减分不能加分。
// 新判据：孤票 WEAK 不改 status，只作 tensions 附注（见 digest 的 weakNotes）。
function majorityVerdict(verdicts, claim) {
  const { vs, hard, weak } = tallyVotes(verdicts, claim)
  if (!vs.length) return 'NOTCHECKED'
  if (vs.length >= 2 && hard > vs.length / 2) return 'REFUTED'    // 多数 HARD 反证（且非单票）→ 真杀
  if (hard > 0 || weak >= 2) return 'CONTESTED'                    // 有硬反证但未过半，或 ≥2 张软反对 → 存疑保留
  // 全员判"查不实" ≠ 已确证：出口侧必须能区分「已确证为真」与「没查出反证」。
  // 旧实现没有这个分支，两者同码返回 KEPT，Verify 阶段在最后一公里失去分辨率
  // （实测 3218 条 verdict 里 UNVERIFIABLE 只用了 1 次 = 0.03%）。
  if (vs.every(v => v.verdict === 'UNVERIFIABLE')) return 'UNVERIFIABLE'
  return 'KEPT'   // 含"孤票 WEAK"：反证不丢，降级为 weakNotes 附注
}

// ───────────────────────── 跨轮去重 ─────────────────────────
// 语义（2026-08-08 修正）：**只对已完成轮次去重，同轮内不互相去重**。
// 旧实现把同轮多个专家独立得出的相同 claim 也删掉，正好摧毁了 synthesize 判断 agreements
// （"多个专家各自独立得出"）赖以存在的收敛信号 —— 独立复现是信号，不是冗余。
// 另：去重必须发生在**验证之前**才有省 token 的意义；旧实现跑在 runRound 返回之后，
// 注释承诺的"防止重复论点白烧验证 token"在实现上收益为零。
// norm 不再截断（旧代码 slice(0,160) 会让共享长前缀的不同 claim 误合并）。
// 已知残留局限：前缀精确匹配对 LLM 改述无能为力，这是软去重不是硬保证。
const priorClaims = new Set()
const norm = s => String(s || '').toLowerCase().replace(/\s+/g, ' ').trim()

// 定向升级的实际发生次数（追派出去的额外 skeptic 票数），进 runRecord 供成本核算。
let escalationVotes = 0
let escalatedClaims = 0

// verify prompt 提取成模块级函数：定向升级要用同一份 prompt 追派，内联在 stage2 里无法复用。
// lensIdx=null 表示单票（不给切入 lens）；否则从三个 lens 里取，保证追派的票和第一票视角不同。
const VERIFY_LENSES = ['事实正确性', '证据是否真支撑', '是否可复现/可验证']
// 出口闸的计数在这里收口 —— 首轮验证与定向升级都经由 spawnVerify，卡一处即可全覆盖。
let verifySpawned = 0, gatedClaims = 0, cheapSpawned = 0, fullSpawned = 0, triagedClaims = 0
const spawnVerify = (c, res, round, lensIdx, cheap) => {
  if (MAX_VERIFY_AGENTS && verifySpawned >= MAX_VERIFY_AGENTS) {
    gatedClaims++
    // 只在触闸那一刻播报一次，之后静默累加，收尾时再报总数（见 runRecord.gatedClaims）
    if (gatedClaims === 1) log(`⛔ 出口闸触发：已派出 ${verifySpawned} 个 skeptic（上限 maxVerifyAgents=${MAX_VERIFY_AGENTS}），此后不再派新的。剩余 claim 保持 NOTCHECKED，收尾会报总数。要放开就调大 maxVerifyAgents。`)
    return Promise.resolve(null)
  }
  verifySpawned++
  if (cheap) cheapSpawned++; else fullSpawned++
  return _spawnVerify(c, res, round, lensIdx, cheap)
}
const _spawnVerify = (c, res, round, lensIdx, cheap) => agent(
  `对抗验证下面这条 claim —— 默认立场是「它是错的」，尽力找反证。只有反证不成立才判 HOLDS。
${lensIdx == null ? '' : `\n用这个 lens 切入：${VERIFY_LENSES[lensIdx % VERIFY_LENSES.length]}`}
${cheap ? `
## 你的角色是【分诊票】，不是终审
你判 REFUTED+HARD **不会**直接杀掉这条 claim，只会触发 ${ESCALATE_QUORUM} 张满配复核票来重判。
所以：看出可疑就大胆举手（代价只是多花几张复核票），但**绝不为了举手编造锚点** ——
编出来的 ref 会在复核时被逐条核，代价远大于老实判 WEAK。查得动就查，查不动判 UNVERIFIABLE。
` : ''}
## 原问题（仅用于判定这条 claim 的适用范围与语境，不要回答它）
${Q_LEAN}
${CTX_LEAN}${DECISION ? `

## 本次要拍的板（用来判这条 claim 切不切题，不要去回答它）
${DECISION}` : ''}

Claim: ${c.claim}
专家给的证据: ${clip(c.evidence, 600, '专家证据')}
来源专家: ${res.exp.agentType}

去实际查证（${PROBE_CHANNELS}）。${CONFIDENTIAL ? '' : 'WebSearch / WebFetch 是 deferred 工具，schema 不在 context 里 —— **先 `ToolSearch "select:WebSearch,WebFetch"` 载入再调**，直接调会报 InputValidationError（别因此以为"查不了"）。'}判 REFUTED 必须附具体反证并标 refutationStrength=HARD；若只是推理/"查无确证"级别的怀疑 → 仍可判 REFUTED 但 refutationStrength=WEAK（只把 claim 降为"存疑保留"，不直接杀）。给不出任何反证判 UNVERIFIABLE、refutationStrength=NA。不许用直觉/猜测做 HARD 否决真 claim；不确定判 UNVERIFIABLE，不要默认放过。

## evidenceRefs（判 HARD 时的硬要求）
refutationStrength=HARD 必须同时填 evidenceRefs（至少 1 条），每条是你**实际查到**的锚点：
{kind:"file_line", ref:"path/to/file.js:446", value:"那一行的原文"} ｜ {kind:"command", ref:"grep -n foo bar.js", value:"实际输出"} ｜ {kind:"data", ref:"指标名", value:"具体数字"}${CONFIDENTIAL ? '' : ' ｜ {kind:"url", ref:"https://…", value:"页面上的原话"}'}
填不出就说明你没有硬证据 —— 改判 WEAK 或 UNVERIFIABLE，**不要编造锚点**（编造的 ref 会在复核时被抓出来，代价远大于判 WEAK）。JS 侧只校验字段形状：evidenceRefs 为空且 reason 里也无可核验锚点的"自称 HARD"，会被自动降为 WEAK。
⚠️ 上面「已知上下文」里的内容是本次 run 的既定事实，不要把"我无法独立证实这个上下文"当作反证。${CONFIDENTIAL ? '\n⚠️ 本次为保密 run：禁用 WebSearch/WebFetch，查不了就判 UNVERIFIABLE，不要走外部检索。' : ''}`,
  { label: `verify${cheap ? '·分诊' : ''}:${res.exp.agentType}#r${round}`, phase: 'Verify', schema: VERDICT_SCHEMA, ...(cheap ? CHEAP_OPTS : {}) }
  // claim / tier 放最后：防 skeptic 万一回带同名字段把锚点或票档覆盖掉
).then(v => ({ ...v, claim: c.claim, tier: cheap ? 'cheap' : 'full' }))

// ───────────────────────── 一轮 = Panel fan-out → Verify（pipeline，验证随产出即开）─────────────────────────
// roundExperts: [{ agentType?, role?, lens }]，第一轮由调用方 cast，
// 后续轮由 critic 生成、不带 agentType（用通用 subagent 扮演 role）。
async function runRound(roundExperts, round) {
  return pipeline(
    roundExperts,
    // stage 1：专家并发产出（pipeline 本身不串行，每个专家独立跑）
    (exp, _orig, i) => {
      const roleName = exp.agentType || exp.role || '专家'
      const opts = { label: `panel:${roleName}#r${round}`, phase: 'Panel', schema: EXPERT_SCHEMA }
      // 只有调用方 cast 的合法注册名才传 agentType；critic 生成的靠 prompt 扮演，避免非法 type 被静默吞掉
      if (exp.agentType) opts.agentType = exp.agentType
      return agent(
        `你是 ${roleName}。从你的专业视角审下面这个问题。

## 问题
${Q}

## 你的视角
${exp.lens}
${CTX}${ANCHOR}
${PROBE_KIT}
${GROUND_RULES}${EVAL_RULES}

只输出你这个视角独立查证后的判断。`,
        opts
      ).then(out => {
        // 可见性（2026-09-02 加）：此前 log() 只在阶段边界打，中途只能看到计数在涨、
        // 看不到谁在争什么 —— Colar 的原话是"完全黑盒，做不到中途干预"。
        // 每个专家一落地就播一行实质摘要，/wf-progress 与终端都能当场读到。
        const cs = (out && out.claims) || []
        const byImpact = cs.reduce((m, c) => (m[c.decisionImpact || '?'] = (m[c.decisionImpact || '?'] || 0) + 1, m), {})
        log(`📋 ${roleName}#r${round}：${clip((out && out.summary) || '(无 summary)', 90, 'summary')} ｜ claim ${cs.length} 条 ${JSON.stringify(byImpact)}`)
        return { exp: { agentType: roleName, lens: exp.lens }, out, i, round }
      })
    },

    // stage 2：先跨轮去重（省 token），再对达到验证门槛的 claim 做对抗验证（该专家一产出就开始，不等别人）
    async (res) => {
      if (!res || !res.out) return null
      // 去重两层，语义不同：
      // (1) 跨轮：跟**已完成轮次**比对，省重复验证的 token；
      // (2) 同轮同专家内：2026-08-08 加。EXPERT_SCHEMA 的 claims 无 uniqueItems，同一专家吐出两条
      //     byte-identical claim 时，:442 按 claim **文本**聚合会让 vs.length 虚增到 2 —— 等于
      //     一个专家自己复读就能凑出"多个独立 skeptic"的假象绕过票数门，且同一条 claim 会被
      //     重复计进 KILLED_LIST 让 killedCount 虚高。实测（dup 脚本）可复现。
      // 仍然**不做**跨专家去重：不同专家独立得出同一条是收敛信号，是 agreements 的存在基础。
      const seenInThisExpert = new Set()
      res.out.claims = (res.out.claims || []).filter(c => {
        const k = norm(c.claim)
        if (!k || priorClaims.has(k) || seenInThisExpert.has(k)) return false
        seenInThisExpert.add(k)
        return true
      })
      // ── 分级闸（2026-09-02 加）───────────────────────────────────────────
      // 旧门只有 confidence，而 confidence 测的是"专家有多确定"，跟"这条能不能改变决策"
      // 正交 ⟹ 一条 HIGH 的边角事实和一条 HIGH 的致命风险吃掉一样的验证预算，
      // 这就是"在没意义的事情上争很久"的机制根因（不是模型爱吵，是预算被均摊了）。
      // 新门叠两层：CONTEXT 一律不验；其余按 DECISIVE→SUPPORTING × confidence 排序取前 K。
      // 被跳过的**绝不静默**：计入 triagedClaims、记进 res.triaged，digest 里标 policy。
      // DECISIVE 破格入池（2026-09-02 冒烟测试逮到）：旧门 `VERIFY_LEVELS.includes(confidence)`
      // 会把「能翻转决策、但专家自己没把握」的 claim（DECISIVE + LOW）挡在门外 ——
      // 而那恰恰是最该花钱查的一类：它对结论的杠杆最大，且真伪未知。
      // confidence 门原本的意思是"专家有多确定"，拿它当验证门就是在**优先验证已经确定的东西**。
      // UNVERIFIED 仍不破格：合成纪律第 2 条本就禁止它进 decision，验了也用不上，纯浪费。
      const eligible = res.out.claims.filter(c =>
        c.decisionImpact !== 'CONTEXT' &&
        (VERIFY_LEVELS.includes(c.confidence) ||
         (c.decisionImpact === 'DECISIVE' && c.confidence !== 'UNVERIFIED')))
      // 缺 decisionImpact（schema required 理论上兜住，但"理论上不该发生"正是要防的）
      // 按 SUPPORTING 处理：不白拿最高优先级，也不被当 CONTEXT 直接丢掉。
      const ranked = eligible.slice().sort((a, b) =>
        (IMPACT_RANK[a.decisionImpact] ?? 1) - (IMPACT_RANK[b.decisionImpact] ?? 1) ||
        (CONF_RANK[a.confidence] ?? 9) - (CONF_RANK[b.confidence] ?? 9))
      const checkable = VERIFY_TOP_K ? ranked.slice(0, VERIFY_TOP_K) : ranked
      const checkedKeys = new Set(checkable.map(c => norm(c.claim)))
      const skipped = res.out.claims.length - checkable.length
      if (skipped > 0) {
        triagedClaims += skipped
        // 两个不验的桶语义不同，分开报：`门外` = CONTEXT 档或没到 confidence 门槛；
        // `降优先级` = 够格但排在第 K 名之后。前者是分级正常工作，后者才是预算真的不够。
        const outOfGate = res.out.claims.length - eligible.length
        log(`🎚 分级：${res.exp.agentType}#r${round} ${res.out.claims.length} 条 claim → 实验 ${checkable.length} 条（门外 ${outOfGate} 条 · 降优先级 ${eligible.length - checkable.length} 条）`)
      }
      // DECISIVE 不走分诊，首票就上满配（2026-09-02 加，由实测数据驱动）。
      // 分诊设计防住的是**假阳性**（低配乱举手 → 只多花几张满配复核票，结论不受污染），
      // 但它防不住**假阴性**：低配判 HOLDS 而这条其实是假 claim ⟹ 永不触发升级 ⟹ 静默 KEPT。
      // 2026-09-02 那次 run 给了这个口子的基准错误率：25 条 claim 里 6 条被判杀（24%），
      // 而专家自评 96% 是 HIGH —— 也就是"高置信且错"是常态而非例外，假阴性的机会面不小。
      // 折中而非退让：只让 DECISIVE（推翻它就得改决定的那些）吃满配首票，SUPPORTING
      // 仍走分诊。省钱的大头在后者（DECISIVE 按定义就该是少数），风险最大的那类拿到全额检方。
      const cheapFor = (c) => CHEAP_VERIFY && c.decisionImpact !== 'DECISIVE'
      const verdicts = (await parallel(
        checkable.flatMap(c =>
          // 每条 claim 派 VOTES 个 skeptic，多票时换不同 lens 增加视角多样性。
          Array.from({ length: VOTES }, (_, v) => () => spawnVerify(c, res, round, VOTES > 1 ? v : null, cheapFor(c)))
        )
      )).filter(Boolean)

      // ── 定向升级（2026-08-08）：只给"有人给了硬反证但票数不够判杀"的 claim 加派 ──
      // 病因：`vs.length >= 2 && hard > vs.length/2` 配默认 VOTES=1 ⟹ 互不相同的 claim
      // REFUTED 数学上不可达、kill 率精确 0%，而实测 90% 的历史 run 就跑在这个默认档；
      // 更糟的是它静默 —— killedCount=0 长得像"本轮没有假 claim"，实际是枪被规则关掉了。
      // 定向而非全局提档：无人反对的 claim 不加钱（全局 VOTES=3 约 80% 开销花在那上面）。
      const needEscalate = checkable.filter(c => {
        const { fullCount, hard } = tallyVotes(verdicts, c.claim)
        return fullCount < ESCALATE_QUORUM && hard > 0
      })
      if (needEscalate.length) {
        escalatedClaims += needEscalate.length
        log(`⚖️ 定向升级：${res.exp.agentType}#r${round} 有 ${needEscalate.length} 条 claim 收到硬反证，追派至 ${ESCALATE_QUORUM} 张**满配**票复核`)
        const extra = (await parallel(
          needEscalate.flatMap(c => {
            // 缺口只按**满配票**算：分诊票没有表决权，所以它不能顶掉一张复核票。
            // cheapVerify=false 时首轮票本身是 full，have=VOTES，缺口与 2026-09-02 前一致。
            const have = tallyVotes(verdicts, c.claim).fullCount
            const need = ESCALATE_QUORUM - have
            escalationVotes += need
            // lensIdx 从 1 起：第一票（VOTES=1 时）无 lens，追派的走另外两个视角
            return Array.from({ length: need }, (_, k) => () => spawnVerify(c, res, round, k + 1, false))
          })
        )).filter(Boolean)
        verdicts.push(...extra)
        // 判杀可见性：复核完当场把结论播出来，别等到 synthesize 之后才知道杀了什么。
        for (const c of needEscalate) {
          const st = majorityVerdict(verdicts, c.claim)
          if (st === 'REFUTED') log(`☠️ 判杀：「${clip(c.claim, 70, 'claim')}」（${res.exp.agentType}#r${round}）`)
        }
      }
      return { ...res, verdicts, checkedKeys }
    }
  )
}

// ───────────────────────── 专家来源解析（禁静默降级）─────────────────────────
let SEED_EXPERTS = null
let castMode = null
if (hasExplicitExperts) { validateExperts(A.experts); SEED_EXPERTS = A.experts; castMode = 'explicit' }
else if (GENERIC_OK) { SEED_EXPERTS = GENERIC_PANEL; castMode = 'generic-optin' }
else throw new Error('expert-panel: 未传 experts 也未传 generic:true —— 拒绝静默用通用默认盘（72% 历史 run 掉这里的质量悬崖根因）。按题选人传 {question, experts:[{role|agentType, lens}]}（推荐 role，无注册表依赖）；确实只要通用盘传 {question, generic:true}。注：agentRoster/selector 路径已于 2026-08-08 移除（139 次留存 run 中 0 次真实调用），请直接传 experts。')

// ───────────────────────── 主循环：多轮深挖（maxRounds / depth 驱动，budget 只当闸）─────────────────────────
// 首轮 skeptic 的真实上限由**两个闸的较小者**决定：maxClaims（专家能交几条）
// 与 verifyTopK（每人实际验几条）。此前这行只报 maxClaims，会把预期高估到实际的 ~1.7 倍。
const _perExpertVerify = VERIFY_TOP_K ? (MAX_CLAIMS ? Math.min(MAX_CLAIMS, VERIFY_TOP_K) : VERIFY_TOP_K) : (MAX_CLAIMS || null)
log(`expert-panel v${SCRIPT_VERSION}: seed ${SEED_EXPERTS.length} 专家｜maxClaims=${MAX_CLAIMS || "不限"}｜verifyTopK=${VERIFY_TOP_K || "不限"} ⟹ 首轮 skeptic ≤ ${_perExpertVerify ? SEED_EXPERTS.length * _perExpertVerify * VOTES : "无上限"}｜cheapVerify=${CHEAP_VERIFY}｜leanPrompts=${LEAN}｜maxVerifyAgents=${MAX_VERIFY_AGENTS || "不限"}（硬上限）｜evalMode=${EVAL}｜verifyVotes=${VOTES}｜verifyLow=${!!(A && A.verifyLow)}｜confidential=${CONFIDENTIAL}｜depth=${DEPTH}｜maxRounds=${MAX_ROUNDS}｜budget=${budget && budget.total ? Math.round(budget.total / 1000) + 'k' : 'none'}`)
if (!DECISION) log(`ℹ️ 未传 decision —— 漂移锚点退化为"拿 question 整句当靶心"，claim 分级质量会掉。下次传 {decision:"这次要拍的板"} 能同时提升分级准确度与省钱效果。`)

if (RAW_VOTES !== VOTES) log(`ℹ️ verifyVotes ${RAW_VOTES} → ${VOTES}（强制取奇：偶数票下 "HARD 过半" 退化成要求全票，比少一票更难杀假 claim 却贵一倍）`)
if (castMode === 'generic-optin') log(`ℹ️ generic:true —— 按显式请求用了通用默认盘（${GENERIC_PANEL.map(e => e.agentType || e.role).join('/')}），非按题选人。`)

const allResults = []
const driftFlags = []   // critic 每轮的漂移判定（非 ON_TARGET 才记），进 runRecord + 喂给 synthesize
let nextExperts = SEED_EXPERTS
let round = 0
// stopReason 在各 break 点就地赋值（2026-08-08 修）。旧实现在 synthesize **之后**才回推
// budget.remaining()，而 BUDGET_FLOOR 本就是"留给 synthesize 的余量"—— 正常收敛的 run 会被
// 系统性误标成 budget-floor，让 runRecord 里唯一的停因信号自我污染。
let stopReason = MAX_ROUNDS === 1 ? 'single-round' : 'max-rounds'

while (round < MAX_ROUNDS && nextExperts && nextExperts.length) {
  // 预算闸：第二轮起，剩余预算不够就停（留 BUDGET_FLOOR 给 synthesize）
  if (round > 0 && budget && budget.total && budget.remaining() < BUDGET_FLOOR) {
    stopReason = 'budget-floor'
    log(`预算剩余 ${Math.round(budget.remaining() / 1000)}k < floor ${Math.round(BUDGET_FLOOR / 1000)}k，停止开新轮（已跑 ${round} 轮）`)
    break
  }
  round++
  log(`── 第 ${round}/${MAX_ROUNDS} 轮：${nextExperts.length} 专家 ──`)

  const roundResults = (await runRound(nextExperts, round)).filter(Boolean)
  allResults.push(...roundResults)
  // 本轮结束才把 claim 并入 priorClaims —— 保证同轮内不互相去重
  for (const r of roundResults) {
    for (const c of (r.out && r.out.claims) || []) {
      const k = norm(c.claim)
      if (k) priorClaims.add(k)
    }
  }

  // 最后一轮不必再批判（不会再开轮）
  if (round >= MAX_ROUNDS) break
  // 预算已见底，也不浪费一个 critic agent
  if (budget && budget.total && budget.remaining() < BUDGET_FLOOR) { stopReason = 'budget-floor'; break }

  // 完整性批判：本轮产出给全量细节，既往轮只给视角+结论（防 prompt 随轮数二次方增长）
  const critic = await agent(
    `你是这个专家 panel 的完整性批判者 **兼漂移校准者**。下面是专家产出。

## 原问题
${Q}
${ANCHOR}

## 本轮（第 ${round} 轮）专家产出
${JSON.stringify(roundResults.map(r => ({
      expert: r.exp.agentType,
      summary: r.out && r.out.summary,
      claims: ((r.out && r.out.claims) || []).map(c => ({ claim: c.claim, verifyMethod: c.verifyMethod, confidence: c.confidence })),
    })), null, 2)}

## 既往轮已覆盖的视角与结论（仅供判重，不必重复审视）
${JSON.stringify(allResults.filter(r => r.round < round).map(r => ({ expert: r.exp.agentType, round: r.round, summary: r.out && r.out.summary })), null, 2)}

## 你的纪律
0. **先判漂移，再判缺口。**对着上面的「决策锚点」看本轮产出：它们是在回答那个板，还是各自滑进了自己领域里更有趣但改变不了结论的话题？填 drift + driftNote。判 SEVERE 会直接终止深挖 —— 因为在已经跑偏的方向上再开一轮，等于再烧 N 个专家 + N×K 个验证 agent。
1. 找真实 gap：哪些关键视角没人覆盖？哪些重大 claim 还没被验证？哪种查证方式（市场/技术/法务/成本/分发…）还没跑？**gap 必须是"缺了它就拍不了那个板"的缺口**，不是"这个领域还能再挖挖"。
2. 宁缺毋滥：只有当新增专家能带来「目前完全没有的」边际信息时才 complete=false。重复已覆盖的视角 = 为多而多 = 禁止。
3. 若覆盖已足够，complete=true，nextExperts 留空。
4. nextExperts 里每个角色必须对应一个具体 gap，lens 写清这一轮要它专门挖什么，**且要能说清它挖到的东西会怎么影响那个板**。${CONFIDENTIAL_NOTE}`,
    { label: `critic#r${round}`, phase: 'Critic', schema: CRITIC_SCHEMA }
  )

  if (critic && critic.drift && critic.drift !== 'ON_TARGET') {
    driftFlags.push({ round, drift: critic.drift, note: critic.driftNote || '' })
    log(`🧭 漂移校准（第 ${round} 轮）：${critic.drift} —— ${clip(critic.driftNote || '(critic 未给依据)', 200, 'driftNote')}`)
  }
  // SEVERE 直接收口：在已经跑偏的方向上再开一轮，是这个 workflow 里最贵的单一错误
  // （一轮 = N 个专家 + N×verifyTopK 个 skeptic）。宁可少一轮，也不要在错的靶子上加钱。
  if (critic && critic.drift === 'SEVERE') {
    stopReason = 'drift-stop'
    log(`🛑 漂移收口：本轮产出已偏离决策锚点（SEVERE），停止深挖，直接进合成。合成阶段会显式标注这一点。`)
    break
  }
  if (!critic || critic.complete || !Array.isArray(critic.nextExperts) || !critic.nextExperts.length) {
    stopReason = 'critic-complete'
    log(`完整性批判：覆盖已足够（complete=${critic && critic.complete}），收口于第 ${round} 轮`)
    break
  }
  log(`完整性批判：发现 ${(critic.gaps || []).length} 个 gap，下一轮派 ${critic.nextExperts.length} 个新角色`)
  nextExperts = critic.nextExperts // 下一轮：critic 生成的角色（无 agentType，prompt 扮演）
}

// ───────────────────────── Synthesize（barrier：需要全部轮 + 验证结果）─────────────────────────
phase('Synthesize')
// 判据要求 out 里真有内容：schema 的 required 理论上保证 summary/claims 都在，但空结果门
// 正是为"理论上不该发生"准备的 —— 只判 r.out 为 truthy 会让空壳 {} 流进 synthesize。
// 判据要求 out 里真有内容：schema 的 required 理论上保证 summary/claims 都在，但空结果门
// 正是为"理论上不该发生"准备的 —— 只判 r.out 为 truthy 会让空壳 {} 流进 synthesize
// （注意 stage2 会给 out.claims 赋一个空数组，所以不能只判 Array.isArray）。
const clean = allResults.filter(r => r && r.out && (r.out.summary || (r.out.claims || []).length))

// 空结果门（2026-08-08 加）：在空 digest 上跑 synthesize 会产出一份**凭空合成**的决策，
// 而它长得跟正常输出一模一样 —— 这是本文件最危险的失败形态，宁可抛错。
if (!clean.length) {
  throw new Error(`expert-panel: ${SEED_EXPERTS.length} 个专家全部无有效产出（agent 失败或被跳过），拒绝在空数据上合成决策。检查 experts 里的 agentType 是否为合法注册名（非法名会被静默吞成 null），或看 journal.jsonl 里各 agent 的真实返回值。`)
}

const digest = clean.map(r => {
  const vAll = r.verdicts || []
  const claims = ((r.out && r.out.claims) || []).map(c => {
    const status = majorityVerdict(vAll, c.claim)
    // 把 skeptic 的反证理由一并交给 synthesize。旧实现要求它引用**从未收到**的 reason，
    // 指令无法从所给数据满足时模型只能编 —— 这是文件里最直接的幻觉诱因。
    // 只渲染**有表决权的**反证（满配票）；分诊票的理由不进 synthesize —— 它没有杀伤力，
    // 却会以"skeptic 说了什么"的形态影响合成的措辞，等于让低配票从后门拿回权重。
    // 例外：这条 claim 上一张满配票都没有时（分诊判 HOLDS，从未追派），分诊票就是全部证据。
    const votes = vAll.filter(v => v.claim === c.claim)
    const scoring = votes.some(v => v.tier !== 'cheap') ? votes.filter(v => v.tier !== 'cheap') : votes
    const refuted = scoring.filter(v => v.verdict === 'REFUTED')
    const rendered = refuted.map(v => `[${effectiveStrength(v)}] ${clip(v.reason, 500, '反证理由')}`)
    // NOTCHECKED 分两种，出口侧必须能区分（"没验"长得像"验过没问题"是本文件反复在修的病）：
    //   TRIAGED = 按 decisionImpact/verifyTopK 主动不验，是设计意图；
    //   GATED   = 送去验了但撞上 maxVerifyAgents 出口闸，是预算不够。
    const wasSent = r.checkedKeys ? r.checkedKeys.has(norm(c.claim)) : true
    const checkPolicy = status !== 'NOTCHECKED' ? 'VERIFIED' : (wasSent ? 'GATED' : 'TRIAGED')
    return {
      claim: c.claim, confidence: c.confidence, evidence: clip(c.evidence, 500, '证据'),
      verifyMethod: c.verifyMethod, decisionImpact: c.decisionImpact || null,
      status, checkPolicy,
      // status=KEPT 却有反对票 = 孤票 WEAK（空口怀疑，未过 contest 门槛）。
      // 反证不丢，但降级为附注：不改 claim 的既定性，只允许当 tensions 的脚注。
      refutations: status === 'KEPT' ? [] : rendered,
      weakNotes: status === 'KEPT' ? rendered : [],
    }
  })
  return {
    expert: r.exp.agentType,
    round: r.round,
    summary: r.out.summary,
    recommendation: r.out.recommendation,
    risks: r.out.topRisks,
    claims,
  }
})

// killed 由代码确定性算出并作为**封闭清单**下发，不让 synthesize 自由发挥。
// 去重（2026-08-08）：同一条 claim 文本若在多处出现会被重复计入，让 killedCount 虚高。
const KILLED_LIST = [...new Set(digest.flatMap(d => d.claims.filter(c => c.status === 'REFUTED').map(c => c.claim)))]

const synthesis = await agent(
  `把下面多个专家（可能跨多轮深挖）的独立意见 + 对抗验证结果合成为一个决策视图。

## 原问题
${Q}
${ANCHOR}
${driftFlags.length ? `\n## ⚠️ 漂移记录（critic 逐轮判定，非 ON_TARGET 才在此列出）\n${driftFlags.map(d => `- 第 ${d.round} 轮 [${d.drift}]：${d.note}`).join('\n')}\n跑偏轮次的产出仍在下面，但你必须**优先采信贴着决策锚点的那些**，并在 decision 里说明本次覆盖偏离过靶心。\n` : ''}
## 各专家产出
每条 claim 附 decisionImpact（DECISIVE / SUPPORTING / CONTEXT，见决策锚点）、status 与 checkPolicy。
decisionImpact 是排序依据：decision 与 star.order 必须让 DECISIVE 的结论排在 SUPPORTING 前面，CONTEXT 不进 decision。

checkPolicy 三档（**这一档决定读者该给结论打多少折，不许略过**）：
- VERIFIED = 真的派了 skeptic 去对抗验证，status 是验证结果
- TRIAGED = 按 decisionImpact 分级**主动没验**（预算给了更关键的 claim）—— 它没被否定，但也没被确认
- GATED = 送去验了但撞上验证预算上限，被迫没验 —— 同上，且说明本次预算不够
TRIAGED / GATED 的 claim **一律不得当既定事实进 agreements/decision**；若确实关键，写进 tensions 并标"未验证"。

每条 claim 附 status：
- KEPT = 经验证站住（可能带 weakNotes，见下）
- CONTESTED = 收到硬反证但未过多数门槛，或收到 ≥2 张软反对 —— 存疑保留、不得当既定事实
- UNVERIFIABLE = 验证者查不实也证不伪（≠ 已确证），只能当待验证假设
- REFUTED = 已被多数硬反证驳倒
- NOTCHECKED = 没验（具体是主动分级还是撞预算闸，看同条的 checkPolicy）
refutations 字段是 skeptic 给出的反证原文（供你写 tensions 时引用，别自己编）。
weakNotes 字段是**孤立的一张软反对票**（空口怀疑，无可核验锚点，未过存疑门槛）：它不改变该 claim 的既定性，
你可以在相关 tensions 里把它当脚注提一句，但**不得**据此把一条 KEPT claim 降格、也不得因此拒绝把它写进 decision。
round = 第几轮深挖产出。

${JSON.stringify(digest, null, 2)}

## 已被驳倒的 claim（封闭清单，killed 字段必须逐字等于这个列表，不许增删）
${JSON.stringify(KILLED_LIST, null, 2)}

## 合成纪律（硬约束）
1. status=REFUTED 的 claim 必须剔除，不得进入 agreements/decision；killed 字段照抄上面的封闭清单。
1b. status=CONTESTED 的 claim：不得当既定事实进 agreements/decision，但【必须】作为"存疑点"进 tensions 显式标注，并引用 refutations 里的反对理由 —— 这是防"真话被弱反证误杀"的保留位，绝不静默丢弃。
1c. status=UNVERIFIABLE 的 claim：与 CONTESTED 同级处理 —— 只能进 tensions 并显式标注"验证者查不实"，绝不当既定事实。
2. confidence=UNVERIFIED 的 claim（专家自己都没验证的）不得进 agreements/decision；如仍相关只能作为"待验证假设"进 tensions 并显式标注未验证。
3. 真实分歧必须放进 tensions 保留 —— 严禁为了"给个干净答案"把对立观点压平成虚假共识。
4. 禁止附和提问者的既有立场。若 KEPT 证据整体指向提问者不想听的结论，明确说出来。
5. agreements 只放"多个专家各自独立得出"的点，不是一个专家说、其他没反对。
6. star 字段是给人读的呈现层，与 agreements/tensions/decision 取自同一批 claim，但**重新组织**。它的纪律见下方专节，同样是硬约束。
${VOTES === 1 ? `7. 本次 verifyVotes=1（基础档${CHEAP_VERIFY ? '，且首轮走低配分诊票' : ''}）：${escalatedClaims > 0
      ? `其中 ${escalatedClaims} 条 claim 因收到硬反证已被追派到 ${ESCALATE_QUORUM} 张满配票复核（判 REFUTED 的都经过多数确认，可信度最高）；**其余** claim 只被${CHEAP_VERIFY ? '一张低配分诊票扫过' : '一个未经审计的裁判检查过'}。请在 decision 里区分这两类的可信度，不要一刀切打折。`
      : `本轮没有任何 claim 收到硬反证，所以一次满配复核都没触发 —— 全部"站住"的判决都只出自${CHEAP_VERIFY ? '单张低配分诊票' : '单个未经审计的裁判'}。请在 decision 里对这一点给出显式折扣提示。`}` : ''}${EVAL ? '\n8. decision 给 Floor / Base / Optimal 三档，star.order 与之对齐。' : ''}

## STAR 呈现层纪律（star 字段的硬约束）

读者是**懂技术但不熟这个仓**的决策者。他要的是"该不该动手、先动哪个"，不是论证过程。

1. **语言**：禁止仓内黑话与英文术语裸奔。「fail-closed」写成"出错就直接拦住不放行"，「锚点孤本」写成"回滚用的存档只有一份"，「契约门」写成"上线前的自动检查"。术语是给同事看的，这份是给拍板的人看的。
2. **shouldFix 必须按主题聚类，严禁按专家分栏。** 同一个毛病被 5 个专家从不同角度各报一次，读者要自己做 join —— 这是可读性的头号杀手。先看这批 finding 有哪些**共同形状**（如"检查机制本身没被检查"/"注释和代码对不上"/"一件事有多份实现"），再往里塞条目。
3. **来源映射不许串桶**：mustFix 只取 KEPT；contested 只取 CONTESTED / UNVERIFIABLE；REFUTED 一条都不许出现在 star 的任何字段里。
3b. **checkPolicy=TRIAGED / GATED 且 decisionImpact=DECISIVE 的 claim 必须进 contested**，whyDisputed 写"没验证过——本次验证预算按优先级分配时排在名额外"，read 里给出你的倾向。它们既不是 KEPT 也不是 CONTESTED，若不显式安排就会从 star 里**整条消失** —— 而"能翻转决策却没人查过"恰恰是读者最需要知道的一类。宁可让 contested 长一点，也不能静默丢。
4. **contested 必须分清争的是"事实成不成立"还是"有多严重"。** 读者极易把"有争议"误读成"被驳倒了"。若两个 skeptic 都确认锚点属实、只是严重度投票低于自评，要明写"事实成立，争的是优先级"。
5. **每条 mustFix 都要说"会怎么疼"**，且要具体。"有数据丢失风险"是废话；"磁盘上的旧快照 29MB 对现库 2.09GB，这笔债已经兑现了"才是能拍板的信息。
6. **keepAsIs 不许省。** 只报忧的报告会让读者高估系统的糟糕程度，进而对整份结论打折。做得好的地方要点名。
7. **order 给时间档**（今天 / 本周 / 有空），并优先安排"一个动作同时解决多个问题"的那些。
8. **headline 要能单独拎出来当结论用**，不依赖上下文。
9. star 与 decision 不得互相矛盾。两者结论不一致时，以证据为准并同时改，不要留下两个版本的答案。${CONFIDENTIAL_NOTE}`,
  { label: 'synthesize', phase: 'Synthesize', schema: SYNTH_SCHEMA }
)

// ───────────────────────── runRecord：紧凑可落盘的一行元数据 ─────────────────────────
// 不持久化成台账文件 —— runtime 已把每次 run 的完整结构化产出写进 journal.jsonl，
// 要纵向数据直接读那些文件即可，再建一份台账是重复基建（2026-08-08 更正："不落盘=主动遗忘"
// 这个说法的前提本就不成立，产出一直在磁盘上）。
const _vstat = { HOLDS: 0, REFUTED: 0, UNVERIFIABLE: 0 }
const _cstat = { HIGH: 0, MEDIUM: 0, LOW: 0, UNVERIFIED: 0 }
let _softened = 0    // 自称 HARD 但两条通道都无锚点、被 JS 降为 WEAK 的条数
let _structured = 0  // 自称 HARD 且带合格 evidenceRefs 的条数（主通道遵守率）
let _fallbackOnly = 0 // 自称 HARD、evidenceRefs 不合格但散文正则救回的条数（fallback 依赖度）
for (const r of clean) {
  for (const v of (r.verdicts || [])) {
    if (v && v.verdict in _vstat) _vstat[v.verdict]++
    if (v && v.verdict === 'REFUTED' && v.refutationStrength === 'HARD') {
      const refs = Array.isArray(v.evidenceRefs) ? v.evidenceRefs : []
      if (refs.some(isUsableRef)) _structured++
      else if (effectiveStrength(v) === 'HARD') _fallbackOnly++
      else _softened++
    }
  }
  for (const c of ((r.out && r.out.claims) || [])) if (c && c.confidence in _cstat) _cstat[c.confidence]++
}

// status 五档分布（2026-08-08 加）。此前 runRecord 只记 verdict 级统计，而"claim 最终落到哪一档"
// 才是出口质量 —— 想知道它得去解析 transcript 里的 digest JSON，属可做但费劲的 ergonomics 缺口。
const _sstat = { KEPT: 0, CONTESTED: 0, UNVERIFIABLE: 0, REFUTED: 0, NOTCHECKED: 0 }
for (const d of digest) for (const c of d.claims) if (c.status in _sstat) _sstat[c.status]++
const _verified = _sstat.KEPT + _sstat.CONTESTED + _sstat.UNVERIFIABLE + _sstat.REFUTED
// 退化告警：受检 claim 里过半沉淀成"存疑/查不实"时，输出正在滑向"什么都存疑"的无信息态。
// 阈值 0.45 取自历史基线（逐 run REFUTED 率中位 0.12、p90 0.34，74 个 run 无一 ≥0.50）。
const _contestedRatio = _verified ? (_sstat.CONTESTED + _sstat.UNVERIFIABLE) / _verified : 0
const _degraded = _contestedRatio > 0.45
if (_degraded) log(`⚠️ degraded：受检 claim 中 ${(_contestedRatio * 100).toFixed(0)}% 落 CONTESTED/UNVERIFIABLE（基线 p90≈34%），本次结论的信息量偏低，读 decision 时按此打折。`)
const runRecord = {
  scriptVersion: SCRIPT_VERSION, // 落在产物里：事后回看一份 run record 就能确认它跑的是哪版
  question: Q,
  castMode,                    // explicit | generic-optin
  seedExperts: SEED_EXPERTS.length,
  expertCount: clean.length,
  evalMode: EVAL,
  verifyVotes: VOTES,
  confidential: CONFIDENTIAL,
  depth: DEPTH,
  budget: budget && budget.total ? budget.total : null,
  rounds: round,
  stopReason,
  verdictStats: _vstat,        // HOLDS/REFUTED/UNVERIFIABLE 计数 —— 长期 refute 率监控
  confidenceStats: _cstat,     // 专家 claim 的置信度分布 —— 监控 HIGH 通胀
  statusStats: _sstat,         // claim 最终五档分布 —— 出口质量，比 verdictStats 更接近"用户读到什么"
  contestedRatio: Number(_contestedRatio.toFixed(3)), // (CONTESTED+UNVERIFIABLE)/受检数
  degraded: _degraded,         // >0.45 → 本次输出滑向"什么都存疑"，结论信息量偏低
  softenedHardRefutations: _softened,   // 两条通道都无锚点、被降 WEAK 的条数
  structuredHardRefutations: _structured, // 走 evidenceRefs 主通道的条数
  fallbackOnlyHardRefutations: _fallbackOnly, // 仅靠散文正则救回的条数 —— 主通道遵守率的补数
  escalatedClaims,             // 因收到硬反证而被追派复核的 claim 数
  escalationVotes,             // 追派出去的额外 skeptic 票数（成本核算）
  verifySpawned,               // 实际派出的 skeptic 总数（出口闸的分子）
  cheapSpawned,                // 其中低配分诊票 —— 这一项越高，本次省得越多
  fullSpawned,                 // 其中满配票（首轮 cheapVerify=false 的票 + 全部追派复核票）
  cheapVerify: CHEAP_VERIFY,
  leanPrompts: LEAN,
  verifyTopK: VERIFY_TOP_K || null,
  // 按 decisionImpact/verifyTopK **主动**跳过验证的 claim 数（≠ gatedClaims 的"撞闸被迫跳过"）。
  // 这是本次分级闸省下来的验证量；同时它也是必须打折的部分 —— 这些 claim 没被否定，
  // 但也没被确认，digest 里标 checkPolicy=TRIAGED。
  triagedClaims,
  // critic 逐轮的漂移判定（只记非 ON_TARGET）。非空 = 本次讨论至少一度偏离过决策锚点。
  driftFlags,
  decisionAnchor: DECISION,    // null = 调用方没传，锚点退化成 question 整句
  maxVerifyAgents: MAX_VERIFY_AGENTS || null,
  // 触闸后被跳过的验证次数。**非零即意味着本次结论有未经验证的 claim** ——
  // 它们停在 NOTCHECKED，既没被确认也没被驳倒，读结论时必须按此打折。
  gatedClaims,
  killedCount: KILLED_LIST.length,    // 确定性计算，不取 synthesize 的自述
  // synthesize 自述的 killed 条数。它被 :495 的封闭清单散文约束要求"逐字照抄"，
  // 而本文件自己的结论是散文约束不可靠 —— 记下偏离量，让"到底遵不遵守"变成可测而非可信。
  killedSelfReported: ((synthesis && synthesis.killed) || []).length,
  tensionsCount: ((synthesis && synthesis.tensions) || []).length,
  agreementsCount: ((synthesis && synthesis.agreements) || []).length,
  // STAR 呈现层的产出体检（2026-08-28）。schema 会强制字段存在，但**存在 ≠ 有用**：
  // 空 mustFix 加空 order 一样能过校验，且长得像"没什么要修的"。记下桶计数，让空壳可测。
  starBuckets: synthesis && synthesis.star ? {
    mustFix: (synthesis.star.mustFix || []).length,
    contested: (synthesis.star.contested || []).length,
    shouldFixThemes: (synthesis.star.shouldFix || []).length,
    shouldFixItems: (synthesis.star.shouldFix || []).reduce((n, t) => n + ((t && t.items) || []).length, 0),
    keepAsIs: (synthesis.star.keepAsIs || []).length,
    order: (synthesis.star.order || []).length,
  } : null,
  tokensSpent: budget ? budget.spent() : null,
}
// 出口闸告警：触闸不是错误，但它意味着本次结论**有未经验证的 claim**。放在收尾播报是因为
// 触闸那一刻只播一次、之后静默累加，不在这里报总数的话它会淹没在几十条 log 里。
if (gatedClaims > 0) {
  log(`⛔ 出口闸拦下 ${gatedClaims} 次验证（已派 ${verifySpawned}/${MAX_VERIFY_AGENTS}）——这些 claim 停在 NOTCHECKED，既没被确认也没被驳倒。读结论时按此打折；要跑全就调大 maxVerifyAgents 重来。`)
}

// star 空壳告警：受检 claim 不为零却什么都没进 mustFix/shouldFix，多半是合成偷懒或来源映射串桶，
// 不是"真的没问题"。不 throw —— agreements/tensions/decision 仍完整可用，只损失呈现层。
if (runRecord.starBuckets && _verified > 0
    && runRecord.starBuckets.mustFix === 0 && runRecord.starBuckets.shouldFixItems === 0) {
  log(`⚠️ star 呈现层疑似空壳：受检 claim ${_verified} 条，但 mustFix 与 shouldFix 双双为零 —— 请直接读 synthesis.decision，别信 star 的"没什么要修"。`)
}
if (synthesis && !synthesis.star) {
  log(`⚠️ synthesize 未产出 star 字段（schema required 未生效）—— 呈现层缺失，回退读 decision/agreements/tensions。`)
}
// 分级闸的账单：主动跳过多少条、省了多少个 skeptic。**必须播报** —— 省钱与"结论有未验部分"
// 是同一件事的两面，只报省钱不报未验就是静默降级，那正是本文件通篇在防的病。
if (triagedClaims > 0) {
  log(`🎚 分级闸：主动跳过 ${triagedClaims} 条 claim 的验证（省下同等数量的 skeptic）。它们在 digest 里标 checkPolicy=TRIAGED —— 没被否定，也**没被确认**，读 decision 时按此打折。放宽办法：verifyTopK 调大或传 0 放开名额上限；confidence=LOW 的非 DECISIVE claim 要验得传 verifyLow:true。注意 decisionImpact=CONTEXT 一档**不可放开**，它按定义就是"任何结果都不改变任何决定"。`)
}
if (CHEAP_VERIFY) {
  log(`💰 双档验证：分诊票 ${cheapSpawned} 张（sonnet/low，只提名不表决）+ 满配复核票 ${fullSpawned} 张。满配占比 ${verifySpawned ? Math.round(fullSpawned / verifySpawned * 100) : 0}%。`)
}
if (driftFlags.length) {
  log(`🧭 漂移记录：${driftFlags.map(d => `r${d.round}=${d.drift}`).join(' ')} —— 本次讨论至少一度偏离过决策锚点，synthesize 已收到这份记录并被要求在 decision 里说明。`)
}
log(`runRecord: castMode=${castMode}｜rounds=${round}｜verdict=${JSON.stringify(_vstat)}｜status=${JSON.stringify(_sstat)}｜confidence=${JSON.stringify(_cstat)}｜softened=${_softened}(struct=${_structured}/fallback=${_fallbackOnly})｜escalated=${escalatedClaims}(+${escalationVotes}满配票)｜skeptic=${verifySpawned}(cheap ${cheapSpawned}/full ${fullSpawned})｜triaged=${triagedClaims}｜killed=${runRecord.killedCount}｜contested=${(_contestedRatio * 100).toFixed(0)}%${_degraded ? ' ⚠️degraded' : ''}｜stop=${stopReason}`)
if (runRecord.killedSelfReported !== runRecord.killedCount) {
  log(`ℹ️ synthesize 自述 killed ${runRecord.killedSelfReported} 条 ≠ 封闭清单 ${runRecord.killedCount} 条 —— 已由 JS 覆盖为封闭清单（散文约束再次被实证不可靠）`)
}

return {
  question: Q,
  rounds: round,
  expertCount: clean.length,
  tokensSpent: budget ? budget.spent() : null,
  castMode,        // explicit | generic-optin —— 调用侧可据此确认按题选人是否生效
  runRecord,       // 本次 run 的紧凑元数据，供调用侧当场查看，不持久化
  // killed 用 JS 的封闭清单覆盖 synthesize 的自述（2026-08-08）。
  // 此前 KILLED_LIST 只出现在 :476 计算 / :496 塞进 prompt / runRecord 取 .length —— 返回对象里
  // **没有它**，输出的 killed 是 synthesis agent 自由生成的，只受两条散文约束，而 SYNTH_SCHEMA
  // 对它仅约束 array of string，返回 [] 也能过校验。这正是本文件 :422 判定为无效的那一层。
  synthesis: synthesis ? { ...synthesis, killed: KILLED_LIST } : synthesis,
  // 顶层再暴露一次 star（2026-08-28）：调用侧 99% 的用途是"拿去渲染成给人读的报告"，
  // 让它不必先钻进 synthesis 再取。同一个对象引用，不是副本。
  star: (synthesis && synthesis.star) || null,
  perExpert: digest,
}
