# colar-agents

*English | [中文](README.zh.md)*

A workflow framework I run my own Claude Code setup on. The underlying agent pool is forked from [msitarzewski/agency-agents](https://github.com/msitarzewski/agency-agents); everything on top of it — Tier 1/2/3 task routing, a 4-platform opportunity-mining pipeline, a two-layer SOUL/Memory persona system, a UI/UX design gate — grew out of keeping a personal AI assistant consistent across devices and multiple daily-driver projects.

Take whatever's useful; I may be slow on issues.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

---

## Three layers of "layering"

What actually differentiates this repo from the upstream fork isn't agent count — it's three independent layering mechanisms stacked on top of each other. This section is enough to tell whether it's worth borrowing from.

### 1. Tier 1/2/3 — routing execution rhythm by task size

This came out of running a full plan → review cycle on every task, including typo fixes that took 5 minutes just to open. Now tasks split into three tiers by expected effort:

| Tier | Scope | Flow |
|---|---|---|
| **Tier 1** (< 30min) | single-file / single-function edit | `act → /diff → commit` — no plan, no review |
| **Tier 2** (30min–2h) | cross-file changes | load context → pick 1-3 agents → execute autonomously → `/diff` → build → `/review` → save memory → commit |
| **Tier 3** (2h+) | cross-session refactor / new system | full plan mode → incremental commits per submodule → verify each milestone → `/review` → PR |

Full rules live at the top of [CLAUDE.md](CLAUDE.md). All time estimates are for effort *collaborating with Claude Code*, not hand-writing the code.

> Companion rule: memory writes only capture what isn't obvious from the code — excluded approaches and why, trade-offs behind architectural decisions, context the next session needs to inherit. Code patterns, file paths, git history stay in the code, not in memory.

### 2. Three-tier agent discovery — single source of truth + per-project scoping

Agent files are laid out so Claude Code auto-discovers them without manual specification:

```
~/.claude/agents/                ← Tier 1: global agents, available to every project
<project>/.claude/agents/        ← Tier 2: project-specific agent selection
~/Desktop/colar-agents/         ← Master library: agent source (not loaded directly)
```

> Agent count changes as projects evolve and isn't pinned here. Current snapshot: `ls ~/.claude/agents/ | wc -l`.

**The master library is the single source of truth.** Each project's `.claude/agent-config.yaml` declares which agents it needs; [scripts/sync-all.sh](scripts/sync-all.sh) copies them in from master. Agents are never hand-written outside master, to avoid N drifting copies.

Adding an agent to a project: edit `.claude/agent-config.yaml` → `bash scripts/sync-agents.sh <project-path>`.

### 3. SOUL ↔ Memory two-layer persona — stable axioms vs. mutable facts

The biggest failure mode for keeping a consistent persona across sessions is writing mutable facts (a direction still under evaluation, job-search status, portfolio numbers) into the stable layer, so it silently drifts within months. The split:

| Layer | Role | Examples |
|---|---|---|
| **SOUL.md** | Fixed axioms: voice, boundaries, output formatting rules, time-anchoring discipline | "default to Chinese", "no emoji unless the user uses them first" |
| **Memory** | Mutable facts + evolving frameworks: project status, feedback, references, predictions | "evaluating idea X under framework v0.6", "project Y paused on 2026-04-21" |

**Three anti-drift guardrails:**

1. **When writing to memory** (while the semantics are freshest): does the new memory contradict or upgrade something in SOUL? Sync it immediately.
2. **Manual drift scan**: `bash scripts/drift-check.sh` scans for a blacklist of stale phrasing and dead paths, output as advisory (non-blocking).
3. **When editing SOUL**: reverse-grep memory for old phrasing that should now be deprecated.

Rule of thumb: if a statement might be false in 6 months, it belongs in Memory, not SOUL.

---

## Repo layout

```
colar-agents/
├── CLAUDE.md                ← Tier routing + UI/UX pipeline + agent discovery mechanism
├── soul/
│   ├── SOUL.md              ← stable axioms (voice / boundaries / output formatting / time anchoring)
│   ├── drift-blacklist.txt
│   └── drift-whitelist.txt
├── scripts/
│   ├── sync-all.sh          ← sync agent config across all projects
│   ├── sync-agents.sh       ← sync a single project
│   ├── drift-check.sh       ← manual run (not yet wired to a Stop hook)
│   ├── convert.sh           ← multi-tool integration conversion
│   └── install.sh           ← multi-tool integration install
├── engineering/             ← engineering agents
├── design/                  ← UI/UX/brand
├── marketing/               ← multi-platform content ops
├── sales/                   ← B2B sales
├── paid-media/              ← paid acquisition
├── product/                 ← product management
├── project-management/      ← project coordination
├── testing/                 ← testing / QA
├── support/                 ← ops / finance / legal
├── spatial-computing/       ← AR/VR/XR
├── specialized/             ← cross-domain specialists
├── academic/                ← academic / worldbuilding
├── game-development/        ← game dev (cross-engine + Unity / Unreal / Godot / Blender / Roblox)
└── integrations/            ← exports for Cursor / Aider / Windsurf etc.
```

Full agent list (by division, with specialty + use case): [agents/INDEX.md](agents/INDEX.md)

---

## Quick Start

Primary path is Claude Code. For the other 10 supported IDEs (Cursor / Aider / Windsurf / Copilot / …) see [integrations/README.md](integrations/README.md).

```bash
# 1. clone the master library
git clone https://github.com/wangxuzhou666-arch/colar-agents.git ~/Desktop/colar-agents

# 2. sync global agents into ~/.claude/agents/
bash ~/Desktop/colar-agents/scripts/sync-all.sh

# 3. declare project-specific agents
cd <your-project>
mkdir -p .claude
# create .claude/agent-config.yaml with the agent slugs you need
bash ~/Desktop/colar-agents/scripts/sync-agents.sh "$(pwd)"
```

If you fork this for your own use: keep each project to 4-7 declared agents — beyond that, Claude's selection gets noisy.

---

## A few pipelines that actually run every week

Three of these run weekly, triggered by keyword. A few more (Idea Maximum Mode's tiered budget, sunk-cost gates) are still being documented.

### Money Finder (4-platform opportunity mining)

Trigger phrase: `money finder`. Digs for real signal on an idea across four Chinese platforms simultaneously — not "has anyone built this" but where users are actually complaining, and in what context they'd pay.

The trigger phrase is deliberately English, because Chinese phrasing for "opportunity scan" kept getting parsed by Claude as a coupon/subsidy search.

### Idea Maximum Mode (17-agent jury)

Trigger phrase: `max mode`. Evaluating a startup idea defaults to a 17-agent adversarial jury running in parallel — a hard safeguard against yes-man drift. A lighter 3-agent mode is too easily pulled toward agreeing with whatever framing the user brings in.

Gated behind a ≥1500-word brief or ≥4h of committed effort, so the process doesn't become ritual.

### UI/UX Design Bridge (mandatory design gate)

Every UI task passes through this agent first. It locks in a target design system (74 options: Linear / Stripe / Notion / Apple / Vercel / Spotify …) → fetches the matching DESIGN.md → outputs `instructions-{brand}.md`, which downstream consumers (a frontend-design skill and a Frontend Developer agent) build against.

Never skipped — even "just change a button color" checks whether a design spec exists first.

---

## Acknowledgments

The underlying agent pool prototype comes from [msitarzewski/agency-agents](https://github.com/msitarzewski/agency-agents); I kept its naming style (Whimsy Injector, Rapid Prototyper, Reality Checker) as-is — reusing good placeholders beat inventing 12 division names myself.

What's actually been rebuilt is the layer on top: tier routing, three-tier discovery, SOUL/Memory, the design gate, Money Finder, Idea Maximum Mode — these workflows have little left in common with the original repo.

---

## License

MIT.

---

> This is a personal working system, not an OSS product. I read issues/PRs but respond slowly — fixing a cross-repo sync script has clear ROI for me; for someone who forked this, maybe not.
