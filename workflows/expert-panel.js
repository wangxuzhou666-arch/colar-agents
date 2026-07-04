export const meta = {
  name: 'expert-panel',
  description: '多专家并发 fan-out + 证据门控 + 对抗验证 + 保留异见的合成（替代手动串行召唤+假装辩论）。支持 budget 驱动的多轮深挖（max 模式）。',
  whenToUse: '需要多个专项视角共同审一个决策/方案/idea 时触发。口语触发词（命中任一即应考虑调用本 workflow）："多专家讨论" / "找几个专家审一下" / "几个角度对抗一下" / "让专家们辩一辩" / "open a panel" / "panel review" / "多视角审"。机制：独立专家并发跑（非串行），每条 claim 证据门控，关键 claim 对抗验证，最后合成时强制保留张力、禁止附和用户既有立场。带 budget（用户 "+500k" 式预算）时自动多轮深挖直到吃满预算。',
  phases: [
    { title: 'Panel', detail: 'N 个专家并发，各自证据门控产出结构化意见' },
    { title: 'Verify', detail: '每个专家的关键 claim 被独立 skeptic 对抗验证（refute-by-default）' },
    { title: 'Critic', detail: '完整性批判 — 还缺什么视角/未验证 claim，决定是否再开一轮' },
    { title: 'Synthesize', detail: '丢弃被驳倒的 claim，合成决策，保留 tension 不压平成共识' },
  ],
}

// ───────────────────────── args 约定 ─────────────────────────
// {
//   question: string  (必填) — 要审的决策/方案/idea
//   context:  string  (选填) — 相关事实/文件路径/数据，直接喂进每个专家的 prompt
//   experts:  [{ agentType, lens }]  (选填) — 显式指定专家。调用方按上下文 cast，最高优先级。
//   agentRoster: [{ agentType, description }] (选填) — 可用专家清单。传了 roster 但没传 experts 时，
//             workflow 用一个 selector agent 读 question 从 roster 里挑 2-4 个 cast
//             （roster 由调用方传入而非 workflow 内硬编码 → 既不引入注册表 drift，
//              又不让「忘传 experts」静默降级成通用 panel —— 2026-07-03 args-contract 事故的根因）。
//             experts 和 agentRoster 都不传，才掉进写死的通用 panel（仅安全网，非智能选择）。
//   evalMode: boolean (选填) — true 时强制每个专家给 Floor/Base/Optimal 三档（idea/方案评估用）
//   verifyVotes: number (选填，默认 1) — 每个 claim 派几个 skeptic（>1 = 多视角对抗）
//   verifyLow: boolean (选填，默认 false) — true 时连 LOW confidence 的 claim 也对抗验证（更狠、更烧 token）
//   maxRounds: number (选填) — 显式限定深挖轮数。不传时：有 budget → 跑到预算耗尽（硬上限 HARD_ROUND_CAP）；无 budget → 单轮（向后兼容）
//   budgetFloor: number (选填，默认 50000) — budget.remaining() 低于此值就不再开新轮，留够 synthesize 的余量
// }
// ⚠️ harness 在某些环境下把 args 当 JSON 字符串投递（实测 typeof args === 'string'）。
// 脚本控制不了投递方式，所以在此做防御性归一：是 JSON 字符串就 parse；
// parse 失败（传进来的是裸问题字符串、非 JSON）就降级把整段当 question，
// 避免静默落进占位符「（未提供）」让专家对着空输入白跑一轮（2026-07-03 踩过）。
let A = args
if (typeof A === 'string') { try { A = JSON.parse(A) } catch (e) { A = { question: args } } }
if (!A || typeof A !== 'object') A = {}

const Q = (A && A.question) || '（未提供 question — 请在 args.question 写要审的决策）'
const CTX = (A && A.context) ? `\n\n## 已知上下文（视为事实，不要重新质疑其存在性）\n${A.context}` : ''
const EVAL = !!(A && A.evalMode)
const VOTES = Math.max(1, (A && A.verifyVotes) || 1)
const VERIFY_LEVELS = (A && A.verifyLow) ? ['HIGH', 'MEDIUM', 'LOW'] : ['HIGH', 'MEDIUM']
const BUDGET_FLOOR = (A && A.budgetFloor) || 50000
const HARD_ROUND_CAP = 12 // runaway 兜底：即使预算充足也不超过这么多轮
// 轮数策略：显式 maxRounds 优先；否则有 budget 跑到预算耗尽（封顶 HARD_ROUND_CAP）；无 budget 单轮。
const MAX_ROUNDS = (A && A.maxRounds)
  ? Math.min(A.maxRounds, HARD_ROUND_CAP)
  : (budget && budget.total ? HARD_ROUND_CAP : 1)

// 专家来源优先级：显式 experts > selector(读 agentRoster 匹配) > 写死通用 panel(安全网)。
const hasExplicitExperts = !!(A && Array.isArray(A.experts) && A.experts.length)
const ROSTER = (A && Array.isArray(A.agentRoster) && A.agentRoster.length) ? A.agentRoster : null
const GENERIC_PANEL = [
  { agentType: 'Trend Researcher',     lens: '市场/竞品/外部真实验证 — 有没有人已经做、为什么没成' },
  { agentType: 'Product Manager',      lens: '用户 JTBD、真实需求强度、distribution 现实' },
  { agentType: 'Software Architect',   lens: '实现复杂度、技术风险、最小可行路径' },
  { agentType: 'Security Engineer',    lens: '隐私/安全/凭证/数据暴露面' },
]

// ───────────────────────── 质量门控（焊进每个专家 prompt）─────────────────────────
const GROUND_RULES = `
## 输出纪律（违反即视为低质量产出）
1. 证据门控：每条 claim 必须附证据 —— 代码 file:line / grep|ls 输出 / 外部可点 URL / 具体数据。
2. 反编造：无法验证的 claim 一律标 confidence="UNVERIFIED" 并说明缺什么证据；绝不 fabricate 数据/URL/"我跑了发现 X"。能力上做不到的（如无浏览器跑不了实测）直说做不到，不要假装。
3. 反复读 prompt：不要把问题换个说法复述当结论。只报你独立查证后新增的信息。
4. 反附和：你的任务是给独立专业判断，不是迎合提问者预期。证据指向反直觉结论时，照实报。`

const EVAL_RULES = EVAL ? `
5. 三档锚点（强制）：给 Floor（保守可达）/ Base（现实最可能）/ Optimal（最优情形）三档，不要只给 Optimal。` : ''

// ───────────────────────── schema ─────────────────────────
const EXPERT_SCHEMA = {
  type: 'object',
  required: ['summary', 'claims', 'recommendation', 'topRisks'],
  properties: {
    summary: { type: 'string', description: '该视角下的一句话核心判断' },
    claims: {
      type: 'array', description: '支撑判断的关键 claim，每条带证据',
      items: {
        type: 'object',
        required: ['claim', 'evidence', 'confidence'],
        properties: {
          claim: { type: 'string' },
          evidence: { type: 'string', description: 'file:line / grep 输出 / URL / 数据；无则写缺什么' },
          confidence: { type: 'string', enum: ['HIGH', 'MEDIUM', 'LOW', 'UNVERIFIED'] },
        },
      },
    },
    recommendation: { type: 'string' },
    topRisks: { type: 'array', items: { type: 'string' } },
  },
}

const VERDICT_SCHEMA = {
  type: 'object',
  required: ['verdict', 'reason'],
  properties: {
    verdict: { type: 'string', enum: ['HOLDS', 'REFUTED', 'UNVERIFIABLE'] },
    reason: { type: 'string', description: '为什么 —— 附反证或确证的具体证据' },
  },
}

// 完整性批判：决定是否再开一轮 + 下一轮派谁。刻意只产 lens（视角描述），
// 不强制 agentType —— critic 动态造的 agentType 可能不在注册表里会让 agent() 崩，
// 所以下一轮统一用通用 subagent 靠 prompt 扮演（见 runRound 的 agentType 处理）。
const CRITIC_SCHEMA = {
  type: 'object',
  required: ['complete', 'gaps', 'nextExperts'],
  properties: {
    complete: { type: 'boolean', description: '覆盖是否已足够 —— 再加视角无新增边际价值时为 true。宁缺毋滥，不要为多而多。' },
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

const SYNTH_SCHEMA = {
  type: 'object',
  required: ['agreements', 'tensions', 'decision', 'killed'],
  properties: {
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

// ───────────────────────── 一轮 = Panel fan-out → Verify（pipeline，验证随产出即开）─────────────────────────
// roundExperts: [{ agentType?, role?, lens }]，第一轮带 agentType（调用方 cast 的合法注册名），
// 后续轮由 critic 生成、不带 agentType（用通用 subagent 扮演 role）。
async function runRound(roundExperts, round) {
  return pipeline(
    roundExperts,
    // stage 1：专家并发产出（pipeline 本身不串行，每个专家独立跑）
    (exp, _orig, i) => {
      const roleName = exp.agentType || exp.role || '专家'
      const opts = { label: `panel:${roleName}#r${round}`, phase: 'Panel', schema: EXPERT_SCHEMA }
      // 只有调用方 cast 的合法注册名才传 agentType；critic 生成的靠 prompt 扮演，避免非法 type 崩溃
      if (exp.agentType) opts.agentType = exp.agentType
      return agent(
        `你是 ${roleName}。从你的专业视角审下面这个问题。

## 问题
${Q}

## 你的视角
${exp.lens}
${CTX}
${GROUND_RULES}${EVAL_RULES}

只输出你这个视角独立查证后的判断。`,
        opts
      ).then(out => ({ exp: { agentType: roleName, lens: exp.lens }, out, i, round }))
    },

    // stage 2：对达到验证门槛的 claim 做对抗验证（该专家一产出就开始，不等别人）
    async (res) => {
      if (!res || !res.out) return null
      const checkable = (res.out.claims || []).filter(c => VERIFY_LEVELS.includes(c.confidence))
      const verdicts = await parallel(
        checkable.flatMap(c =>
          // 每条 claim 派 VOTES 个 skeptic，多票时换不同 lens 增加视角多样性
          Array.from({ length: VOTES }, (_, v) => () =>
            agent(
              `对抗验证下面这条 claim —— 默认立场是「它是错的」，尽力找反证。只有反证不成立才判 HOLDS。
${VOTES > 1 ? `\n用这个 lens 切入：${['事实正确性', '证据是否真支撑', '是否可复现/可验证'][v % 3]}` : ''}

Claim: ${c.claim}
专家给的证据: ${c.evidence}
来源专家: ${res.exp.agentType}

去实际查证（grep/ls/read/web）。判 REFUTED 必须附具体反证（file:line / 命令输出 / URL / 数据）—— 单票就能杀掉这条 claim，所以给不出反证就判 UNVERIFIABLE，不许用直觉/猜测否决真 claim。不确定也判 UNVERIFIABLE，不要默认放过。`,
              { label: `verify:${res.exp.agentType}#r${round}`, phase: 'Verify', schema: VERDICT_SCHEMA }
            ).then(v => ({ claim: c.claim, ...v }))
          )
        )
      )
      return { ...res, verdicts: verdicts.filter(Boolean) }
    }
  )
}

// ───────────────────────── 专家选择：selector 前置 stage（根除不传 experts 的质量悬崖）─────────────────────────
// 显式 experts 直接用；否则若调用方传了 agentRoster（可用专家清单），用 selector agent 读 question 挑 2-4 个 cast。
// roster 传入而非硬编码 → 既不引入注册表 drift，又不让「忘传 experts」静默降级成通用 panel。
const SELECTOR_SCHEMA = {
  type: 'object',
  required: ['experts'],
  properties: {
    experts: {
      type: 'array', description: '从 roster 里挑 2-4 个视角互补的专家',
      items: {
        type: 'object', required: ['agentType', 'lens'],
        properties: {
          agentType: { type: 'string', description: '必须逐字来自 roster，不许发明不存在的' },
          lens: { type: 'string', description: '这个专家针对本问题要专门审的角度' },
        },
      },
    },
  },
}

let SEED_EXPERTS = hasExplicitExperts ? A.experts : GENERIC_PANEL
if (!hasExplicitExperts && ROSTER) {
  const picked = await agent(
    `你是专家 panel 的选人官。从下面的 roster 里挑 2-4 个能给出【互补、非冗余】视角的专家来审这个问题，各写清这一次要它专门挖的 lens。

## 待审问题
${Q}

## 可用专家 roster（agentType — 能力）
${ROSTER.map(r => `- ${r.agentType} — ${r.description || ''}`).join('\n')}

## 纪律
1. agentType 逐字来自 roster，不许发明不存在的。
2. 挑视角互补的，别选会给雷同意见的。
3. 宁少毋滥：2-4 个，只选对这个问题真有专业增量的。`,
    { label: 'selector', phase: 'Panel', schema: SELECTOR_SCHEMA }
  )
  const valid = new Set(ROSTER.map(r => r.agentType))
  // 只留 roster 里真实存在的 agentType，防 selector 幻觉出非法 type 让后续 agent() 崩
  const cast = (picked && Array.isArray(picked.experts) ? picked.experts : []).filter(e => valid.has(e.agentType))
  if (cast.length) { SEED_EXPERTS = cast; log(`selector 从 ${ROSTER.length} 个 roster cast 了 ${cast.length} 个专家`) }
  else log(`selector 未产出合法专家，回退通用 panel`)
}

// ───────────────────────── 主循环：多轮深挖（budget / maxRounds 驱动）─────────────────────────
log(`expert-panel: seed ${SEED_EXPERTS.length} 专家｜evalMode=${EVAL}｜verifyVotes=${VOTES}｜verifyLow=${!!(A && A.verifyLow)}｜maxRounds=${MAX_ROUNDS}｜budget=${budget && budget.total ? Math.round(budget.total / 1000) + 'k' : 'none'}`)

const allResults = []
const seenClaims = new Set() // 跨轮去重：规范化后的 claim 文本，防止后续轮重复同一论点白烧验证 token
const norm = s => String(s || '').toLowerCase().replace(/\s+/g, ' ').trim().slice(0, 160)

let nextExperts = SEED_EXPERTS
let round = 0

while (round < MAX_ROUNDS && nextExperts && nextExperts.length) {
  // 预算闸：第二轮起，剩余预算不够就停（留 BUDGET_FLOOR 给 synthesize）
  if (round > 0 && budget && budget.total && budget.remaining() < BUDGET_FLOOR) {
    log(`预算剩余 ${Math.round(budget.remaining() / 1000)}k < floor ${Math.round(BUDGET_FLOOR / 1000)}k，停止开新轮（已跑 ${round} 轮）`)
    break
  }
  round++
  log(`── 第 ${round}/${MAX_ROUNDS} 轮：${nextExperts.length} 专家 ──`)

  const roundResults = (await runRound(nextExperts, round)).filter(Boolean)
  // 去重：丢掉跟既有产出重复的 claim（按 claim 文本），但保留专家壳用于 summary/risk
  for (const r of roundResults) {
    if (r && r.out && Array.isArray(r.out.claims)) {
      r.out.claims = r.out.claims.filter(c => {
        const k = norm(c.claim)
        if (!k || seenClaims.has(k)) return false
        seenClaims.add(k)
        return true
      })
    }
  }
  allResults.push(...roundResults)

  // 最后一轮不必再批判（不会再开轮）
  if (round >= MAX_ROUNDS) break
  // 预算已见底，也不浪费一个 critic agent
  if (budget && budget.total && budget.remaining() < BUDGET_FLOOR) break

  // 完整性批判：看目前全部产出，决定还缺什么 / 是否再开一轮
  const critic = await agent(
    `你是这个专家 panel 的完整性批判者。下面是目前所有专家的产出。判断覆盖是否已足够。

## 原问题
${Q}

## 目前所有专家产出（summary + 关键 claim）
${JSON.stringify(allResults.map(r => ({
      expert: r.exp.agentType,
      summary: r.out && r.out.summary,
      claims: (r.out && r.out.claims || []).map(c => c.claim),
    })), null, 2)}

## 你的纪律
1. 找真实 gap：哪些关键视角没人覆盖？哪些重大 claim 还没被验证？哪种查证方式（市场/技术/法务/成本/分发…）还没跑？
2. 宁缺毋滥：只有当新增专家能带来「目前完全没有的」边际信息时才 complete=false。重复已覆盖的视角 = 为多而多 = 禁止。
3. 若覆盖已足够，complete=true，nextExperts 留空。
4. nextExperts 里每个角色必须对应一个具体 gap，lens 写清这一轮要它专门挖什么。`,
    { label: `critic#r${round}`, phase: 'Critic', schema: CRITIC_SCHEMA }
  )

  if (!critic || critic.complete || !Array.isArray(critic.nextExperts) || !critic.nextExperts.length) {
    log(`完整性批判：覆盖已足够（complete=${critic && critic.complete}），收口于第 ${round} 轮`)
    break
  }
  log(`完整性批判：发现 ${critic.gaps.length} 个 gap，下一轮派 ${critic.nextExperts.length} 个新角色`)
  nextExperts = critic.nextExperts // 下一轮：critic 生成的角色（无 agentType，prompt 扮演）
}

// ───────────────────────── Synthesize（barrier：需要全部轮 + 验证结果）─────────────────────────
phase('Synthesize')
const clean = allResults.filter(Boolean)

// 聚合：标出每条被验证 claim 的多数裁决（REFUTED 占多数则剔除）
function majorityVerdict(verdicts, claim) {
  const vs = verdicts.filter(v => v.claim === claim)
  if (!vs.length) return 'NOTCHECKED'
  const refuted = vs.filter(v => v.verdict === 'REFUTED').length
  return refuted > vs.length / 2 ? 'REFUTED' : 'KEPT'
}

const digest = clean.map(r => {
  const claims = (r.out.claims || []).map(c => ({
    claim: c.claim, confidence: c.confidence, evidence: c.evidence,
    status: majorityVerdict(r.verdicts || [], c.claim),
  }))
  return {
    expert: r.exp.agentType,
    round: r.round,
    summary: r.out.summary,
    recommendation: r.out.recommendation,
    risks: r.out.topRisks,
    claims,
  }
})

const synthesis = await agent(
  `把下面多个专家（可能跨多轮深挖）的独立意见 + 对抗验证结果合成为一个决策视图。

## 原问题
${Q}

## 各专家产出（已附每条 claim 的对抗验证 status：KEPT / REFUTED / NOTCHECKED；round = 第几轮深挖产出）
${JSON.stringify(digest, null, 2)}

## 合成纪律（硬约束）
1. status=REFUTED 的 claim 必须剔除，放进 killed 字段，不得进入 agreements/decision。
2. confidence=UNVERIFIED 的 claim（专家自己都没验证的）不得进 agreements/decision；如仍相关只能作为"待验证假设"进 tensions 并显式标注未验证，绝不当既定事实用。
3. 真实分歧必须放进 tensions 保留 —— 严禁为了"给个干净答案"把对立观点压平成虚假共识。
4. 禁止附和提问者的既有立场。若 KEPT 证据整体指向提问者不想听的结论，明确说出来。
5. agreements 只放"多个专家各自独立得出"的点，不是一个专家说、其他没反对。
${EVAL ? '6. decision 给 Floor / Base / Optimal 三档。' : ''}`,
  { label: 'synthesize', phase: 'Synthesize', schema: SYNTH_SCHEMA }
)

return {
  question: Q,
  rounds: round,
  expertCount: clean.length,
  tokensSpent: budget ? budget.spent() : null,
  synthesis,
  perExpert: digest,
}
