export const meta = {
  name: 'spike-to-production',
  description: 'Spike/playground 成果移植进产品并上线的编排，人工审核 gate 前后分两 phase 跑',
  whenToUse:
    '把 spike/playground/调参台里调通的渲染参数、算法或管线搬进产品仓时。' +
    'phase=survey 先摸清落地状态/版本差/资产 lane 并产出移植方案（只读，不改任何文件）；' +
    'Colar 肉眼审完 playground 后，phase=port 才执行移植与验证。',
  phases: [
    { title: 'Survey', detail: '并发勘察：落地状态 / 版本差 / 资产 lane / 目标文件结构' },
    { title: 'Plan', detail: '合成移植方案 + 风险清单 + 该弹给 Colar 看什么' },
    { title: 'Port', detail: '按方案改代码（单写者，避免并发改同一文件）' },
    { title: 'Check', detail: '并发验证：类型/lint · 老资产回归 · 真浏览器亲验' },
    { title: 'Preflight', detail: '部署前置：增量范围 / 磁盘 / 四道门 / 资产追踪面' },
  ],
}

// ── args 契约（调用方唯一读得到的就是这段）──────────────────────────────
//   必填：
//     spikeDir     spike/playground 所在目录（绝对路径）
//     productRepo  产品仓根目录（绝对路径）
//     targetFile   要移植进的目标文件（相对 productRepo）
//   选填：
//     phase        'survey'（默认，gate 前只读）| 'port'（gate 后执行）
//     capabilities 要搬的能力清单 [{name, spikeMarker, productMarker}]
//                  spikeMarker/productMarker 是 grep 用的正则，用来判"落地了没有"
//     plan         phase='port' 时把 survey 阶段产出的方案原样传回来
//     verifyPath   产品里目标板块的交互路径描述（喂给亲验 agent）
//     deployHost   部署档名，仅用于 preflight 量增量，**本 workflow 绝不执行部署**
// ────────────────────────────────────────────────────────────────────

const a = args || {}
const need = ['spikeDir', 'productRepo', 'targetFile']
const missing = need.filter((k) => !a[k])
if (missing.length) {
  throw new Error(
    `缺少必填 args: ${missing.join(', ')}。` +
      `用法：Workflow({scriptPath:"<本文件>", args:{spikeDir, productRepo, targetFile, phase}})`
  )
}

const PHASE = a.phase || 'survey'
const CAPS = Array.isArray(a.capabilities) ? a.capabilities : []
const capList = CAPS.length
  ? CAPS.map((c) => `- ${c.name}：spike 侧标志 /${c.spikeMarker}/，产品侧标志 /${c.productMarker}/`).join('\n')
  : '(调用方未给能力清单 —— 自己从 spike 源码里读出来，别猜)'

const COMMON = `
【场景】把 spike 里调通的成果移植进产品。这两侧的约束不重叠的部分就是全部翻车点。
  spike:   ${a.spikeDir}
  产品仓:  ${a.productRepo}
  目标文件: ${a.productRepo}/${a.targetFile}

【要移植的能力】
${capList}

【硬纪律】
- 只信直接读到的源码与真实执行结果；不要相信 handoff/注释/上个 session 说的"那个已经搬过了"。
- 路径一律绝对路径。
- 报告要可执行：给具体文件:行号、具体命令、具体数值，不要抽象总结。
`

const SURVEY_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['findings', 'risks'],
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['claim', 'evidence'],
        properties: {
          claim: { type: 'string', description: '一句话结论' },
          evidence: { type: 'string', description: 'file:line 或命令输出，必须是直接证据' },
        },
      },
    },
    risks: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['risk', 'mitigation'],
        properties: { risk: { type: 'string' }, mitigation: { type: 'string' } },
      },
    },
  },
}

// ══════════════════ PHASE: SURVEY（gate 前，全只读）══════════════════
if (PHASE === 'survey') {
  phase('Survey')
  log('只读勘察 —— 本 phase 不改任何文件')

  const [landed, versions, assets, structure] = await parallel([
    () =>
      agent(
        `${COMMON}
【你的任务】判定每项能力在**产品里到底落地了没有**。

对每一项：在目标文件里 grep 产品侧标志，再到 spike 源码里 grep 对应实现。
输出三类之一：已落地 / 未落地（产品里是什么替代形态）/ 部分落地（哪部分缺）。

⚠️ 这一步最常见的错误是相信"应该早就搬过了"。必须给出 file:line 级证据。`,
        { label: 'survey:落地状态', phase: 'Survey', schema: SURVEY_SCHEMA }
      ),

    () =>
      agent(
        `${COMMON}
【你的任务】版本对齐 —— 找出"不能假设像素等价"的地方。

1. 读两侧的库版本（产品读 package.json 依赖声明；**不要**用 node -e require('<pkg>/package.json')，
   exports 限制会报 ERR_PACKAGE_PATH_NOT_EXPORTED）。
2. spike 用到的每个 API，到产品的 node_modules 源码里确认：还在吗？已废弃吗？是真身还是转发壳？
3. 特别注意：废弃转发壳（用真身替代）、已废弃常量（保留产品侧已改好的，别把 spike 的抄回来）。

输出：逐个 API 的 keep/replace 决定 + 依据的源码位置。`,
        { label: 'survey:版本差', phase: 'Survey', schema: SURVEY_SCHEMA }
      ),

    () =>
      agent(
        `${COMMON}
【你的任务】资产 lane 勘察 —— 搬过去的资产该走哪条路，以及体积。

1. 读产品仓 .gitignore 里同类资产的规则（本体入不入 git？清单/缩略图放不放行？）
2. 读部署脚本（scripts/deploy/sync.sh 一类）：这些目录随部署同步吗？有没有 exclude？
3. du -sh 量 spike 侧待搬资产的体积，按文件类型分。
4. 判断：新建的目录是否被现有 .gitignore 规则覆盖？**白名单式挡法只挡已知目录，
   新目录不补规则就会让大二进制进 git 历史。**

输出：lane 结论（照抄哪条现有 convention）+ 需要新补的 .gitignore 行 + 建议的体积压缩方案。`,
        { label: 'survey:资产lane', phase: 'Survey', schema: SURVEY_SCHEMA }
      ),

    () =>
      agent(
        `${COMMON}
【你的任务】读透目标文件，产出**改动点清单**（不要改，只读）。

关注：状态结构（options/defaults 在哪）· 资源生命周期（谁 dispose、cleanup 在哪）·
异步边界（有没有 cancelled 闸 / 陈旧回调防护）· 硬编码常量（该升级成分档的）·
老资产的现有行为（移植必须是纯加法，不能破坏它们）。

顺带记下你看到的**现存 bug**（硬编码的能力上限、无上限的缓存、cleanup 漏项等）。

输出：按"改哪一段 → 改成什么 → 为什么"组织的清单，带行号。`,
        { label: 'survey:目标结构', phase: 'Survey', schema: SURVEY_SCHEMA }
      ),
  ])

  const alive = [landed, versions, assets, structure].filter(Boolean)
  if (!alive.length) throw new Error('survey 四路全部失败，无法产出方案')

  phase('Plan')
  const plan = await agent(
    `${COMMON}
【你的任务】把四路勘察合成一份**可执行的移植方案**。

四路结果（JSON）：
${JSON.stringify({ landed, versions, assets, structure }, null, 1)}

方案必须包含：
1. 移植步骤（有序，每步给文件与改动要点）—— 原则是**纯加法**：新能力由资产/配置自己声明，
   缺省即老行为，老资产逐字节不变。
2. 资产处理（lane、压缩命令、命名 —— 图库原始编号可溯源，进产品清单一律改中性名）。
3. 顺带该修的现存 bug。
4. **该弹给 Colar 看什么**：具体 URL + 该看画面的哪里 + 哪些是自测过的、哪些没验过。
5. 风险与不确定项（需要 Colar 拍板的单列出来）。

⚠️ 结尾必须写明：这份方案在 Colar 肉眼审完 playground 之前**不执行**。`,
    { label: 'plan:合成方案', phase: 'Plan' }
  )

  log('─────────────────────────────────────────────')
  log('⛔ 人工审核 GATE：把 playground 弹给 Colar 肉眼审')
  log('   通过 → Workflow({scriptPath:<本文件>, args:{...同上, phase:"port", plan:<上面这份>}})')
  log('   不通过 → 回 spike 改，改完重弹。不要带着"产品里再调"的想法往下走')
  log('─────────────────────────────────────────────')

  return { phase: 'survey', landed, versions, assets, structure, plan, gate: '等 Colar 肉眼审 playground' }
}

// ══════════════════ PHASE: PORT（gate 后）══════════════════
if (PHASE !== 'port') throw new Error(`未知 phase: ${PHASE}（只接受 'survey' | 'port'）`)

if (!a.plan) {
  throw new Error(
    "phase='port' 需要把 survey 阶段的方案用 args.plan 传回来。" +
      '直接跳过 survey 与人工 gate 去 port，正是本 workflow 要防的事。'
  )
}

phase('Port')
log('⚠️ 本 phase 会改产品仓的文件')

// 单写者：移植集中在同一个文件，并发改必冲突
const portReport = await agent(
  `${COMMON}
【你的任务】按已通过人工审核的方案执行移植。

方案：
${typeof a.plan === 'string' ? a.plan : JSON.stringify(a.plan, null, 1)}

【执行纪律】
- 改文件前必须先 Read（harness 只认 Read 工具）。
- 纯加法：老资产走原路径，行为逐字节不变；新能力由 manifest/配置的可选字段声明。
- 顺带修方案里列出的现存 bug。
- 注释写"为什么"不写"做了什么"，与文件现有注释密度和语言一致。
- 改完自己跑一遍 tsc --noEmit 与 eslint <改动文件>，把错清干净再交。

输出：改了哪些文件、每个文件改了什么、跑 tsc/eslint 的真实结果（失败就说失败）。`,
  { label: 'port:移植', phase: 'Port' }
)

phase('Check')
const checks = await parallel([
  () =>
    agent(
      `${COMMON}
【你的任务】类型与静态检查，如实报告。

cd ${a.productRepo}/frontend（或仓库对应前端目录）
npx tsc --noEmit
npx eslint <本次改动的文件>
npm run build

⚠️ 只报告真实输出。全绿就说全绿，有错就贴错。不要"修好了"却没跑。`,
      { label: 'check:类型与构建', phase: 'Check' }
    ),

  () =>
    agent(
      `${COMMON}
【你的任务】老资产回归审查（纯读代码，不跑）。

移植后的代码里，走**老形态资产**（没有新增可选字段的那些）的那条路径，
与移植前相比行为有没有任何变化？逐条比对：默认值、合成管线、材质参数、机位。

任何"老资产观感会变"的地方都要报出来，并判断是"改进"还是"回归"。
${portReport ? '\n移植报告：\n' + String(portReport).slice(0, 3000) : ''}`,
      { label: 'check:老资产回归', phase: 'Check' }
    ),

  () =>
    agent(
      `${COMMON}
【你的任务】真实浏览器亲验 —— build 绿 ≠ 跑得起来。

路径：${a.verifyPath || '（调用方未给，自己从产品仓读出目标板块的进入路径）'}

1. 起 dev server，确认目标页面与新资产全部 200。
2. 用 playwright（产品仓通常已装）驱动真实点击，走完整路径，逐步截图。
   - WebGL 需要 launch args: --use-gl=angle --use-angle=swiftshader --enable-unsafe-swiftshader
   - 监听 pageerror / console error / requestfailed
   - 画布类：确认 gl.isContextLost() === false
   - ⚠️ scratchpad 里的脚本 import 不到产品仓 node_modules，用
     createRequire("${a.productRepo}/frontend/")
3. 有登录墙且目标板块是零后端组件时：可建临时路由挂载它，**验完必须删并确认 git status 干净**。
   ⛔ 不要去读用户表找账号密码。
4. **读你自己截的图**，判断画面对不对，不要只看"脚本没报错"。

输出：每步截图路径 + 你从图里看到了什么 + 错误清单。如实说哪些没验到。`,
      { label: 'check:浏览器亲验', phase: 'Check' }
    ),
])

phase('Preflight')
const preflight = await agent(
  `${COMMON}
【你的任务】部署前置检查 —— **只检查，绝不执行部署**。

1. git status --short：确认只有预期的文件；大二进制资产必须被 ignore
   （git check-ignore -v <资产路径> 验证），只有清单与缩略图入库。
   确认没有临时验证路由残留。
2. 量真实增量：读线上已部署版本（如 ssh <server> "cat /opt/<app>.DEPLOYED_VERSION"），
   git log --oneline <线上commit>..HEAD —— 线上可能已跑在同一分支，增量往往比想象小。
   ⚠️ 若增量里含**其他 session 的 commit**，明确列出来，这是要 Colar 知情的。
3. 服务器余量：df -h、free -m，对比新资产体积。
4. 仓库的构建/测试门（check_all 一类）是否全绿。
   ⚠️ pre-commit 可能跑全量测试（数百秒），预留足够超时，别让它被 SIGTERM。
${a.deployHost ? `5. 部署档：${a.deployHost}，读 scripts/deploy/hosts/ 确认目标机与域名。` : ''}

输出：一份 go / no-go 清单 + **交给 Colar 手动执行的完整部署命令**。
⛔ 生产部署可能被安全策略拦，也本就该由 Colar 拍板执行 —— 你不要跑它，也不要绕。`,
  { label: 'preflight:部署前置', phase: 'Preflight' }
)

return {
  phase: 'port',
  port: portReport,
  checks: checks.filter(Boolean),
  preflight,
  next: '把 preflight 的部署命令交给 Colar 执行；收尾汇报必附部署状态行',
}
