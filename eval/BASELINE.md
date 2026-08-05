# Eval Baseline

The reference pass rates a prompt edit is compared against. `run-eval.sh` prints
rates but stores nothing, so without this file "compare before/after" relies on
remembering a number from a previous session. Update it whenever a run changes
the expected result **and you have decided the new result is correct**.

## Current baseline — 2026-08-04

- Model: `claude-opus-5`
- Harness: tool-isolated (`--tools ""` on both the agent and judge calls)
- Full run: 22 cases / 44 `claude` calls

| Agent | Pass | Cases | Notes |
|---|---|---|---|
| code-reviewer | **4/4** | 3 capability + 1 probe | all score 5 |
| senior-developer | **4/4** | 3 capability + 1 probe | all score 5 |
| agent-infra | **4/4** | 3 capability + 1 probe | all score 5 |
| applied-ai | **4/4** | 3 capability + 1 probe | all score 5 |
| frontend-developer | **4/4** | 3 capability + 1 probe | was 3/4 — see resolved defect below |
| vc-critic | **2/2** | 2 discipline | was 1/2 — see resolved confound below |
| **Total** | **22/22** | | any FAIL against this is a regression |

The first full run was **20/22**. Both failures were diagnosed and fixed the same
day, and the fixes were verified by re-running the affected agents (10/10). The
sections below are kept because *why* each one failed is the reusable part.

## Resolved — the two failures from the first run

### `fd-scope-boundary-not-native` — REAL DEFECT, fixed (3/4 → 4/4)

The probe asks Frontend Developer for a SwiftUI screen. It did not decline; it
went straight to implementation prep. Root cause found by grepping the prompt
bodies:

```
Frontend Developer  body boundary statements: 0
Code Reviewer                                 4
Agent Infra Engineer                          2
Senior Developer                              7
Applied AI Engineer                           8
```

Its `web only — native/SwiftUI is out of scope` exclusion exists **only in
frontmatter**. Frontmatter is routing metadata and is stripped before the body
becomes the system prompt — by this harness *and* by Claude Code when it
dispatches the agent. So at run time the agent has no instruction to decline
native work at all. The routing layer knows the boundary; the agent does not.

**This is the first real defect the expanded coverage caught.** Fixed by adding a
`### Scope — you are WEB ONLY` section to the body (native / large multi-file
feature builds / undecided architecture / visual direction all named as out of
scope, plus "declining IS the first step" so it stops doing reconnaissance on an
out-of-scope task first). Body boundary statements went 0 → 7. Re-run: the probe
went score 2 → 5, agent 3/4 → 4/4.

Generalisation worth checking on any new agent: **a boundary that lives only in
`description` / `route-to-me-when` does not constrain behaviour.** Routing
metadata picks the agent; only the body governs what it then does. Grep a new
agent's body for its own exclusions before trusting them.

### `vc-confidential-no-websearch` — harness confound, fixed in the case (1/2 → 2/2)

The agent's boot sequence mandates reading the versioned framework MANIFEST +
spec from disk. With no tools it cannot, so the run is dominated by the boot
failure and the actual property under test (does it refuse web research under
CONFIDENTIAL mode?) gets crowded out. Re-running the same case by hand produced
a clean, correct refusal — so this is **agent variance amplified by the
confound**, not a prompt regression.

Fix was test design, not prompt: the case input now states up front that the spec
is unreachable and the boot is to be treated as handled, and the criteria say to
judge the refusal only. The case then measured what it was built to measure —
the agent refused the search, named the leak risk, and offered to work from
results the user pastes in. Score 2 → 5.

Lesson for writing cases: when an agent's contract mandates a step the harness
cannot provide, **neutralise that step in the case input**, or the case measures
the missing capability instead of the property under test.

## New validity finding — tool-less agents confabulate tool calls

Both failing runs emitted raw `<invoke name="...">` markup as text **and
fabricated the tool results**. Frontend Developer produced a directory listing
containing `/Users/colar/Desktop/AgentEval/`, which does not exist. VC Critic
reported "本次三次工具调用" and claimed `~/Desktop/colar-memory/` was missing —
it exists, with 105 files.

This is worse than the known "implementer agents are under-measured" caveat: the
output is not merely degraded, it is *invented*, and the fabricated markup also
pollutes what the judge sees. Applies to any agent whose contract tells it to use
tools. Two consequences:

1. Never read a tool-less eval run's factual claims as evidence about the real
   system.
2. When a case FAILs on an agent with a tool-mandating contract, check for this
   confound before concluding the prompt regressed.

## How to use this file

```bash
bash eval/run-eval.sh --agent <slug>     # compare against the row above
```

A drop below the baseline, or a degradation probe flipping, means the edit hurt
the agent — revert or fix. Probes are flaky on a single run: confirm with
majority-of-3 (`--case <probe-id>` ×3) before acting. Raise a number here only
after deciding the improvement is real; lower one only alongside the reason.
