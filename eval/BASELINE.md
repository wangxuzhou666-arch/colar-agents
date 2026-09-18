# Eval Baseline

The reference pass rates a prompt edit is compared against. `run-eval.sh` prints
rates but stores nothing, so without this file "compare before/after" relies on
remembering a number from a previous session. Update it whenever a run changes
the expected result **and you have decided the new result is correct**.

## 2026-09-18 — judge model split + senior-developer moved to sonnet

### Harness fix (do not undo)

`--model` used to drive **both** the agent call and the judge call from one
`$MODEL` var, so `--model claude-sonnet-5` scored "sonnet written, sonnet judged"
against an "opus written, opus judged" baseline — the ruler moved with the thing
being measured, and no pass-rate delta could be attributed to the agent side.
The judge now has its own `JUDGE_MODEL`, pinned to `claude-opus-5` regardless of
`--model`. Override only via the explicit `--judge-model`, and re-run the whole
baseline if you ever do.

### A/B result — senior-developer

| Config | Result |
|---|---|
| agent `opus-5`, judge `opus-5` (baseline, re-run) | 4/4, every case score 5 |
| agent `sonnet-5`, judge `opus-5` | 4/4, every case score 5 |
| `sd-no-architect-overreach` probe on sonnet, majority-of-3 | 3/3 PASS, no flapping |

The opus row was re-run rather than read off the 2026-08-04 table below, because
`agent-prompt-edit-gate` records a 2026-09-15 prompt change after which
senior-developer sat at 3/4 — comparing against a stale number would have
charged that drift to the model swap.

`engineering-senior-developer.md` is now `model: sonnet`. Everything else stays
on opus; the judgement-layer agents (code-reviewer, applied-ai, agent-infra) were
deliberately left alone — cheaper judgement means a looser verification gate,
which is a bad trade at any price.

### What this eval does NOT establish

Every case runs with `--tools ""`, single-turn, 4 cases total. That measures
one-shot text quality. The execution layer's real work is a multi-turn tool loop
(Read → reason → Edit → verify), and **none of that was tested**. The honest
claim is "no measurable regression", not "proven equivalent".

### Revert triggers (any one → put `model: opus` back)

- A subagent's output needs the main loop to redo it (rework, not review).
- `/code-review` findings on sonnet-produced diffs rise noticeably.
- Subagents report done while build/test is red, more often than before.

### Field notes — real-workload observations

The eval above cannot settle whether sonnet holds up in a multi-turn tool loop;
only real use can. Append one line per observation as it happens, good or bad —
a run of clean entries is as much evidence as a failure is. Date every entry.

| Date | Observation | Verdict |
|---|---|---|
| 2026-09-18 | Switched to sonnet. | — |
| 2026-09-18 | First real task: wrote `scripts/verify_orchestration_setup.sh` (7 checks over settings.json, hook behaviour, frontmatter parsing, SOUL). Ran green; independently re-run by the main loop, same result. Volunteered that check 6 is structurally coupled to `run_judge()`'s name and brace layout, and that it fails loudly rather than passing silently if that changes. Also noticed the hook file was edited mid-task, read the diff, and confirmed it did not touch the path under test. Verified as sonnet-5 in the transcript. | Good — unprompted disclosure of its own limits is the behaviour a cheaper model is most likely to drop, and it did not. |

Reverting is one line of frontmatter. Track the behavioural side with
`scripts/orchestration_audit.py`; the 2026-09-18 reading this was decided
against: Agent dispatch rate 0.26%, main loop 83.1% of cost, sessions above 300K
context carrying 93.9% of spend.

## Current baseline — 2026-08-04

- Model: `claude-opus-5` (agent side; judge is pinned separately since 2026-09-18)
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
