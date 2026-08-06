---
name: nextjs-hmr-proactive-restart
description: 在 Next.js 项目里跑 dev server 时,做 >3 文件批量编辑 / 改 middleware / 改 server component (page.jsx/layout.jsx/API route) / 加新依赖 / 加新路由 / 改 NEXT_PUBLIC_ env 后,主动 nuke .next + 重启 dev,不依赖 HMR。也用于排查 dev server 症状:页面卡「加载中」/ chunks 404 / 热更新(HMR)不生效 / 改完代码不刷新 / server 返回 200 但 client 白屏。Use when: working in a Next.js codebase running `npm run dev` and any of the above triggers fire, or when debugging stale HMR, 404 chunks, or a stuck "loading" page.
version: 1.0.0
source: feedback_nextjs_hmr_restart_proactive (migrated 2026-05-24)
---

## When to Use

跑 Next.js dev server (`next dev`) 期间,**主动**触发,不等用户截图报错。任一命中即启:

1. 一次 Edit/Write batch **改 > 3 个文件**
2. 改了 `middleware.ts` / `middleware.js`(HMR 几乎必坏)
3. 改了 **server component** —— `page.jsx` / `page.tsx` / `layout.jsx` / `layout.tsx` / `app/**/route.ts`
4. 加了新依赖(`npm install` / `pnpm add` / `yarn add`)
5. 加了新路由文件夹(`app/<new-route>/`)
6. 改了 `.env.local` 里 `NEXT_PUBLIC_*` 变量

**不触发**(HMR 正常 work):
- 改单一文件 + 没碰 middleware / server component
- 纯 CSS 改动
- 文档 / README 改动

## Procedure

```bash
# 1. nuke + restart
pkill -f "next dev"
rm -rf .next
npm run dev  # 或 pnpm dev / yarn dev,按 package.json
```

后台启动后等 5 秒做 verify(下一节)。

## Verification

**Pre-open verify(硬约束)** — 重启后,在告诉用户"已重启"之前必跑:

```bash
# 0. 先定实际端口,不要硬编码 3000:
#    优先从 dev server 启动输出读(`- Local: http://localhost:XXXX` — 3000 被占时 Next 会自动换 3001+);
#    其次看 package.json dev script 的 `-p <port>` / PORT env;都没有才 fallback 3000
PORT=3000  # ← 替换为上面读到的实际端口

# 1. trigger initial compile
curl -s "http://localhost:$PORT" > /dev/null && sleep 3

# 2. 三个核心 chunks 必须返回 200(否则 HMR 在出"server 200 + chunks 404"假象)
for c in main-app.js app-pages-internals.js app/page.js; do
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/_next/static/chunks/$c")
    echo "$c → $code"
done
```

任一 chunk 404 → **不要** open / 不要告诉用户 ready,改告知"chunk emit 异常,在修",回 step Procedure 重跑一次 nuke + restart。

## Pitfalls

- **"server Ready in 1.2s" 不等于 client 就绪**: Next.js 14/15 HMR 经常出 dev server 200 但 client chunks 404,页面卡"加载中..."。Colar 无法区分"真在加载"vs"chunks 404 死循环",每次都要他截图报"还是加载中"才发现。verify 30 秒 vs 浪费 10 分钟,ROI 明显。
- **Turbopack(`next dev --turbo`) HMR 比 webpack 稳很多**,但很多项目还在用 webpack default。如果项目是 Next.js 15.5+ stable,优先建议升 Turbopack 作为长期解。
- **macOS 上 `pkill -f` 可能漏掉子进程**: 如果重启后仍看到旧端口占用,用 `lsof -ti:$PORT | xargs kill -9` 兜底(`$PORT` = 实际 dev 端口)。
- **端口漂移陷阱**: 旧进程占着 3000 时,重启后 Next 静默换到 3001+ —— 对着 3000 verify 会误判"chunks 404",实际是端口错了。verify 前必从 dev server 输出确认端口。

## Why This Skill Exists

实战 3 次同 pattern(2026-05-09 / 05-11 × 2): webpack server chunk hash 跟磁盘 ./xxx.js 对不上 → require 失败 → middleware / nextauth route 挂 → 页面失败回退到无样式。HMR 在这些 trigger 后**几乎必坏**,主动重启比"等用户报错"快 10×。

## Related

- 项目级别可加 `package.json` script: `"dev:clean": "rm -rf .next && next dev"`
- 长期: 项目升 Turbopack(`"dev": "next dev --turbo"`)替代 webpack dev
