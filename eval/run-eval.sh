#!/usr/bin/env bash
#
# run-eval.sh — minimal agent output-quality eval harness.
#
# For each golden case: strip the target agent's frontmatter -> use its body as
# the system prompt -> run the agent via `claude -p` -> feed the agent output +
# criteria to an LLM judge -> aggregate pass rate per agent.
#
# Usage:
#   ./run-eval.sh                       # run all covered agents
#   ./run-eval.sh --agent code-reviewer # run one agent only (cheaper)
#   ./run-eval.sh --agent code-reviewer --case cr-sql-injection  # one case (smoke)
#   ./run-eval.sh --model claude-opus-4-8   # override model
#
# Exit code: 0 if all (non-ERROR) cases pass, 1 if any case fails.
# ERROR cases (infra failures) do NOT flip the exit code by themselves but are
# reported; a run with only ERRORs and no FAILs still exits 0 (nothing regressed).

set -uo pipefail

# ---------------------------------------------------------------------------
# Paths & config
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CASES_DIR="$SCRIPT_DIR/cases"
JUDGE_PROMPT_FILE="$SCRIPT_DIR/judge-prompt.md"
MODEL="claude-opus-4-8"

# Map agent slug -> master .md file (relative to repo root).
agent_file() {
  case "$1" in
    code-reviewer)    echo "$REPO_ROOT/engineering/engineering-code-reviewer.md" ;;
    senior-developer) echo "$REPO_ROOT/engineering/engineering-senior-developer.md" ;;
    *) echo "" ;;
  esac
}

ALL_AGENTS=(code-reviewer senior-developer)

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
ONLY_AGENT=""
ONLY_CASE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) ONLY_AGENT="$2"; shift 2 ;;
    --case)  ONLY_CASE="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Dependency checks.
command -v claude >/dev/null 2>&1 || { echo "FATAL: 'claude' CLI not found in PATH" >&2; exit 2; }
command -v jq     >/dev/null 2>&1 || { echo "FATAL: 'jq' not found in PATH" >&2; exit 2; }
[[ -f "$JUDGE_PROMPT_FILE" ]] || { echo "FATAL: judge prompt missing: $JUDGE_PROMPT_FILE" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Strip YAML frontmatter from an agent .md: everything AFTER the second '---'.
# Writes the body to a temp file and echoes its path.
strip_frontmatter() {
  local md="$1"
  local out
  out="$(mktemp -t agenteval_sp.XXXXXX)"
  awk '
    /^---[[:space:]]*$/ { dashes++; if (dashes <= 2) next }
    dashes >= 2 { print }
  ' "$md" > "$out"
  echo "$out"
}

# Extract the `.result` text from a `claude --output-format json` envelope.
# IMPORTANT: claude's JSON puts the agent's raw markdown in `.result` WITH
# literal unescaped newlines / control chars, which strict jq rejects. Python's
# json.loads(strict=False) tolerates them. Echoes the result text; returns
# non-zero if is_error is true or result is empty/unparseable. Reads raw on stdin.
extract_result() {
  python3 -c '
import sys, json
try:
    d = json.loads(sys.stdin.read(), strict=False)
except Exception:
    sys.exit(1)
if d.get("is_error", True):
    sys.exit(1)
r = d.get("result", "")
if not r:
    sys.exit(1)
sys.stdout.write(r)
'
}

# Run claude -p and echo the result text. Returns non-zero on infra failure.
# $1 = user prompt, $2 = system-prompt file path
run_claude() {
  local prompt="$1" sp_file="$2" raw result
  # </dev/null: prevent claude from blocking on / consuming the loop's stdin
  # (the case-file fed into the `while read` loop).
  raw="$(claude -p "$prompt" \
            --system-prompt-file "$sp_file" \
            --output-format json \
            --model "$MODEL" </dev/null 2>/dev/null)" || return 1
  result="$(printf '%s' "$raw" | extract_result)" || return 1
  printf '%s' "$result"
}

# Run the judge. Echoes a clean JSON object {pass,score,reasoning} on success.
# Retries once on illegal JSON. Returns non-zero if both attempts fail.
run_judge() {
  local criteria="$1" task="$2" agent_out="$3"
  local judge_input attempt raw inner cleaned
  judge_input="$(cat <<EOF
## ORIGINAL TASK
$task

## CRITERIA
$criteria

## AGENT OUTPUT
$agent_out
EOF
)"
  for attempt in 1 2; do
    raw="$(claude -p "$judge_input" \
              --system-prompt-file "$JUDGE_PROMPT_FILE" \
              --output-format json \
              --model "$MODEL" </dev/null 2>/dev/null)" || { continue; }
    # Outer claude envelope -> .result holds the judge's text (control-char safe).
    inner="$(printf '%s' "$raw" | extract_result)" || continue
    [[ -z "$inner" ]] && continue
    # The judge text should be a JSON object {pass,score,reasoning}, possibly
    # wrapped in ```json fences or with stray prose. Extract + validate via
    # python (tolerant of control chars), re-emit as compact canonical JSON.
    cleaned="$(printf '%s' "$inner" | python3 -c '
import sys, json, re
t = sys.stdin.read()
# strip markdown code fences if present
t = re.sub(r"```(?:json)?", "", t)
# grab the first {...} object
m = re.search(r"\{.*\}", t, re.DOTALL)
if not m:
    sys.exit(1)
try:
    obj = json.loads(m.group(0), strict=False)
except Exception:
    sys.exit(1)
if not all(k in obj for k in ("pass", "score", "reasoning")):
    sys.exit(1)
# canonical compact form so downstream jq parsing is safe
sys.stdout.write(json.dumps(obj, ensure_ascii=False))
')" || continue
    [[ -z "$cleaned" ]] && continue
    printf '%s' "$cleaned"
    return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
if [[ -n "$ONLY_AGENT" ]]; then
  if [[ -z "$(agent_file "$ONLY_AGENT")" ]]; then
    echo "FATAL: unknown agent '$ONLY_AGENT' (valid: ${ALL_AGENTS[*]})" >&2; exit 2
  fi
  AGENTS=("$ONLY_AGENT")
else
  AGENTS=("${ALL_AGENTS[@]}")
fi

declare -a REPORT_LINES=()
TOTAL_FAIL=0
TOTAL_ERROR=0
TMP_FILES=()
cleanup() { for f in "${TMP_FILES[@]:-}"; do [[ -f "$f" ]] && rm -f "$f"; done; }
trap cleanup EXIT

echo "============================================================"
echo " Agent Eval Harness  (model: $MODEL)"
echo "============================================================"

for agent in "${AGENTS[@]}"; do
  md="$(agent_file "$agent")"
  cases_file="$CASES_DIR/$agent.jsonl"
  if [[ ! -f "$md" ]]; then
    echo ">> SKIP $agent: agent file not found ($md)"; continue
  fi
  if [[ ! -f "$cases_file" ]]; then
    echo ">> SKIP $agent: cases file not found ($cases_file)"; continue
  fi

  sp_file="$(strip_frontmatter "$md")"
  TMP_FILES+=("$sp_file")

  echo ""
  echo "--- Agent: $agent ---------------------------------------"

  agent_pass=0 agent_total=0

  # Read JSONL line by line via FD 3 so inner commands can't consume loop input.
  while IFS= read -r line <&3 || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    cid="$(echo "$line" | jq -r '.id')"
    [[ -n "$ONLY_CASE" && "$cid" != "$ONLY_CASE" ]] && continue
    input="$(echo "$line" | jq -r '.input')"
    criteria="$(echo "$line" | jq -r '.criteria')"

    agent_total=$((agent_total + 1))

    # 1) Run the target agent.
    if ! agent_out="$(run_claude "$input" "$sp_file")"; then
      echo "  [ERROR] $cid  (agent claude call failed)"
      REPORT_LINES+=("ERROR  $agent/$cid  agent call failed")
      TOTAL_ERROR=$((TOTAL_ERROR + 1))
      continue
    fi

    # 2) Run the judge.
    if ! verdict="$(run_judge "$criteria" "$input" "$agent_out")"; then
      echo "  [ERROR] $cid  (judge returned illegal JSON twice)"
      REPORT_LINES+=("ERROR  $agent/$cid  judge JSON invalid")
      TOTAL_ERROR=$((TOTAL_ERROR + 1))
      continue
    fi

    pass="$(echo "$verdict" | jq -r '.pass')"
    score="$(echo "$verdict" | jq -r '.score')"
    reason="$(echo "$verdict" | jq -r '.reasoning')"

    if [[ "$pass" == "true" ]]; then
      echo "  [PASS]  $cid  (score $score) — $reason"
      agent_pass=$((agent_pass + 1))
    else
      echo "  [FAIL]  $cid  (score $score) — $reason"
      REPORT_LINES+=("FAIL   $agent/$cid  (score $score) $reason")
      TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
  done 3< "$cases_file"

  echo "  => $agent: $agent_pass/$agent_total passed"
done

# ---------------------------------------------------------------------------
# Final report
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " SUMMARY"
echo "============================================================"
if [[ ${#REPORT_LINES[@]} -eq 0 ]]; then
  echo " All cases passed. No failures or errors."
else
  printf ' %s\n' "${REPORT_LINES[@]}"
fi
echo "------------------------------------------------------------"
echo " Failures: $TOTAL_FAIL   Errors: $TOTAL_ERROR"
echo "============================================================"

# Exit code: fail if any case FAILED. Pure infra ERRORs do not flip to 1.
[[ "$TOTAL_FAIL" -gt 0 ]] && exit 1
exit 0
