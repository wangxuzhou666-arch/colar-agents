# Agent Eval Harness

Minimal output-quality regression harness for the high-frequency agents. For each
golden case it runs the **target agent's prompt body as a system prompt** via
`claude -p`, then has an **LLM judge** score the output against specific criteria.

Goal: stop changing agent prompts blind. Run this before and after a prompt edit
and compare pass rates — if a change regresses an agent, a case flips to FAIL.

## What it tests

Output quality only (golden input → run agent → judge scores against criteria).
It does **not** test routing/description quality — that's a separate concern.

**All 6 deployed agents are covered** (2026-08-04 — was 2/6 before; the other four
were being edited blind). 3 capability cases + 1 degradation probe each, except
VC Critic (see its caveat below):

| Agent | Master file | Cases |
|---|---|---|
| Code Reviewer | `engineering/engineering-code-reviewer.md` | `cases/code-reviewer.jsonl` (4) |
| Senior Developer | `engineering/engineering-senior-developer.md` | `cases/senior-developer.jsonl` (4) |
| Agent Infra Engineer | `engineering/engineering-agent-infra.md` | `cases/agent-infra.jsonl` (4) |
| Applied AI Engineer | `engineering/engineering-applied-ai.md` | `cases/applied-ai.jsonl` (4) |
| Frontend Developer | `engineering/engineering-frontend-developer.md` | `cases/frontend-developer.jsonl` (4) |
| VC 模型 Critic | `specialized/idea-vc-critic.md` | `cases/vc-critic.jsonl` (2, discipline only) |

Every criterion is derived from the agent's OWN stated contract (its Critical
Rules / route-to-me-when exclusions), not from invented preferences — so a FAIL
means the agent broke a rule it declares for itself, which is checkable rather
than a matter of taste.

`agent_file()` in `run-eval.sh` is the coverage registry: **an agent with no entry
there has no eval coverage and its prompt is edited blind.** Keep it in sync with
the deployed roster in `~/.claude/agents/`.

> 2026-07-04: UI Designer retired (design work moved to the skill-based stack:
> frontend-design plugin); its cases were removed with it.
> 2026-08-04: `ui-ux-pro-max` skill removed (conflicted with frontend-design +
> dataviz on the same trigger); Software Architect / Security Engineer / Trend
> Researcher agents retired. Degradation-probe criteria no longer name a specific
> destination agent — they test the BEHAVIOUR (does it refuse to overstep?), so a
> future roster change can't silently invalidate a probe.

Each agent has at least one **degradation-probe** case (a scope-boundary test)
designed to flip to FAIL first if the prompt's boundary language gets damaged.

> ⚠️ **Validity caveat — VC Critic gets discipline cases only.** Its boot sequence
> requires *reading* the versioned framework MANIFEST + spec from disk, which this
> harness (plain `claude -p`, no tools) cannot provide. Capability cases would
> therefore measure nothing real. What IS measurable single-shot is its two red
> lines: refusing to start when the spec is unreadable (instead of reconstructing
> a stale framework from memory), and refusing web research under CONFIDENTIAL
> mode. Those are the two cases. Do not "fix" the count to 4 by inventing
> capability cases the harness cannot honestly run.

## How it works

1. `run-eval.sh` strips the agent `.md`'s YAML frontmatter (everything after the
   2nd `---`) into a temp file. Frontmatter is routing metadata, not behavior, so
   only the body becomes the system prompt.
2. Runs the agent: `claude -p "<case input>" --system-prompt-file <body> --output-format json --model claude-opus-4-8`.
3. Runs the judge: feeds `{task + criteria + agent output}` to `claude -p` with
   `judge-prompt.md` as system prompt; judge returns `{"pass":bool,"score":1-5,"reasoning":"..."}`.
4. Aggregates pass/total per agent and prints a report.

## Usage

```bash
cd ~/Desktop/colar-agents

bash eval/run-eval.sh                                   # all covered agents (~16 claude calls)
bash eval/run-eval.sh --agent code-reviewer             # one agent only (cheaper)
bash eval/run-eval.sh --agent code-reviewer --case cr-sql-injection   # one case (smoke)
bash eval/run-eval.sh --model claude-opus-4-8           # override model
```

### Regression workflow (the whole point)

```bash
bash eval/run-eval.sh --agent code-reviewer    # baseline BEFORE editing the prompt
# ... edit engineering/engineering-code-reviewer.md ...
bash eval/run-eval.sh --agent code-reviewer    # AFTER — compare pass rate
```

A drop in pass rate (or the degradation-probe case flipping) means the edit hurt
the agent. **Exit code 0 = all pass, 1 = at least one FAIL** — so it can gate CI.

> ⚠️ **Degradation probes are flaky on a single run — use majority-of-3.** A
> probe's verdict is sensitive to agent output non-determinism: the same prompt
> can flip PASS↔FAIL run to run (observed on `sd-no-architect-overreach`). To
> judge whether a probe passes or regressed, run it 3× (`--case <probe-id>`) and
> take the majority — a single PASS/FAIL is not authoritative. Normal cases are
> stable enough to trust on one run. If verdicts wobble, first check *which*
> variance it is: re-read the judge reasoning — different scores on the **same
> output** = judge variance (tighten criteria); different scores on **different
> outputs** = agent variance (strengthen the agent's boundary language, the
> criteria is fine).

> ⚠️ **Piping eats the exit code.** `run-eval.sh | tee log.txt` reports `tee`'s
> status (always 0), masking FAILs. For CI gating, don't pipe
> (`bash run-eval.sh; echo $?`), or capture `${PIPESTATUS[0]}`:
> ```bash
> bash eval/run-eval.sh 2>&1 | tee log.txt; exit ${PIPESTATUS[0]}
> ```

> 🚨 **Tool isolation is enforced by `--tools ""`, and it must stay.** Both the
> agent call and the judge call in `run-eval.sh` pass `--tools ""`. Until
> 2026-08-04 they did not, and this README wrongly asserted the harness had "no
> tools" — `claude -p` actually inherits full Write/Edit/Bash access. A run of the
> then-new `ai-new-agent-symlink-discipline` case made Agent Infra Engineer
> genuinely create a live agent file + `~/.claude/agents/` symlink and edit a
> sibling agent's description, because the case asked it to "deploy" something and
> nothing stopped it. Two rules follow: **(1)** never remove `--tools ""`;
> **(2)** phrase every case input as *produce the output*, never *perform the
> action* — every case now carries "no file tools are available in this
> environment". A whitelist is used rather than `--disallowedTools` so a newly
> added mutating tool cannot silently slip through.

> ⚠️ **Validity caveat — implementer-class agents are under-measured here.**
> This harness runs agents via `claude -p` with **no tools and no real
> repo** (enforced, see above). That fits agents whose output IS text (Code Reviewer), but
> an agent whose real job is editing files (Senior Developer) tends to *describe a
> plan* instead of emitting code unless the case input explicitly says "no file
> tools available — output the code inline" (see the two `sd-` implementation
> cases). A bare implementation prompt failing here is usually this environment
> mismatch, not a prompt regression. The text-shaped degradation probe
> (`sd-no-architect-overreach`) stays valid either way.

## Cost warning

Each case = **2 `claude` calls** (agent + judge), both on Opus. Full run is
22 cases × 2 = **~44 calls** — that is roughly 10+ minutes wall clock and real
token spend. For iterating on one agent use `--agent` (8 calls); for a sanity
check use `--case` (2 calls). **Don't run the full suite casually** — and don't
run it in a foreground shell with a short timeout, it will be killed mid-run and
you'll pay for the calls already made. Background it and read the log:

```bash
bash eval/run-eval.sh > /tmp/eval.log 2>&1 &
```

## Robustness

- A failed `claude` call or unparseable output marks the case **ERROR** (skipped,
  not crashed). The judge gets **1 retry** on bad JSON before ERROR.
- ERRORs are reported but do **not** flip the exit code (only real FAILs do) — an
  infra hiccup shouldn't look like a regression.
- `claude`'s JSON envelope puts the agent's raw markdown in `.result` with literal
  unescaped control chars, which strict `jq` rejects — so envelope/verdict parsing
  uses Python `json.loads(strict=False)`. (See "implementation notes" below.)

## Files

- `run-eval.sh` — the runner.
- `judge-prompt.md` — judge system prompt (strict, JSON-only output).
- `cases/*.jsonl` — golden cases, one JSON object per line: `{id, input, criteria}`.

## Adding a case

Append a line to the agent's `.jsonl`:

```json
{"id": "unique-id", "input": "the task given to the agent", "criteria": "specific checkable conditions — MUST X / MUST NOT Y / format includes Z"}
```

Keep `criteria` concrete and checkable (MUST/MUST NOT phrasing) — vague criteria
make judge scores unstable and defeat the regression purpose.

## Implementation notes

- `--system-prompt-file` is used (verified working on `claude` 2.1.158); it
  replaces the default system prompt entirely with the agent body — exactly what
  we want so a prompt edit is reflected in eval behavior.
- Every `claude` call uses `</dev/null` and the case loop reads via FD 3, so the
  CLI never blocks on or consumes the loop's stdin.
