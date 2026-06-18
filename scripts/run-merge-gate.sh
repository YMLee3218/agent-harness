#!/usr/bin/env bash
# Merge gate: final branch integrity check before plan merge into main.
# Called from run-dev-cycle.sh when phase reaches 'done'.
# Exit 0: gate passed (caller may proceed to merge-approval marker).
# Exit 1: gate failed (caller must re-block the plan).
# Exit 2: sandbox unavailable (caller treats as env failure, not code failure).
set -euo pipefail
if [[ "${CLAUDE_PLAN_CAPABILITY:-}" != "harness" ]]; then
  exec /usr/bin/env CLAUDE_PLAN_CAPABILITY=harness "$0" "$@"
fi

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/run-context.sh
source "$SCRIPTS_DIR/lib/run-context.sh"
setup_run_context
# shellcheck source=lib/sandbox-lib.sh
source "$SCRIPTS_DIR/lib/sandbox-lib.sh" 2>/dev/null || true
_init_worker_sandbox "${PROJECT_DIR:-}"
if [[ "${_SANDBOX_REQUIRED_FAIL:-0}" == "1" ]]; then
  echo "[BLOCKED:env] merge-gate: sandbox-unavailable — Tier 1 sandbox inactive; set CLAUDE_ALLOW_UNSANDBOXED=1 to run unconfined" >&2
  exit 2
fi
# shellcheck source=lib/llm-runner.sh
source "$SCRIPTS_DIR/lib/llm-runner.sh"
# shellcheck source=lib/sidecar.sh
source "$SCRIPTS_DIR/lib/sidecar.sh"

PLAN=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --plan) PLAN="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$PLAN" ]] || { echo "run-merge-gate: --plan required" >&2; exit 1; }

SLUG=$(basename "$PLAN" .md)
BRANCH="feature/${SLUG}"
MAIN_BRANCH="main"
UNIT_CMD=$(grep -m1 '^\- Test:' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null | sed 's/^- Test: *//;s/^`//;s/`.*$//' || echo "")
INTEGRATION_CMD=$(grep -m1 '^\- Integration test:' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null | sed 's/^- Integration test: *//;s/^`//;s/`.*$//' || echo "")
[[ "$UNIT_CMD" == _\(run* || "$UNIT_CMD" == \{* ]] && UNIT_CMD=""
[[ "$INTEGRATION_CMD" == _\(run* || "$INTEGRATION_CMD" == \{* ]] && INTEGRATION_CMD=""

REPORT_FILE="${PLAN%.md}.state/merge-gate-report.txt"
sc_ensure_dir "$PLAN"

export CRITIC_MERGE_PLAN="$PLAN"
export CRITIC_MERGE_BRANCH="$BRANCH"
export CRITIC_MERGE_MAIN="$MAIN_BRANCH"
export CRITIC_MERGE_TEST_CMD="${UNIT_CMD}"
export CRITIC_MERGE_INTEGRATION_CMD="${INTEGRATION_CMD}"

PF="$SCRIPTS_DIR/plan-file.sh"

# ── Tier-1 deterministic pre-gate (authoritative) ──────────────────────────
# Re-derives the mechanically-checkable merge criteria (tests-green / test-integrity /
# tasks-complete) from git, exit codes and the Task Ledger table every run. A
# deterministic FAIL is final: write the report, exit 1, never invoke the LLM — so no
# critic-merge prose can rationalise past it. Criteria 4 (no-stubs) and 5 (contamination)
# stay with the LLM: their grep/ownership checks have a high false-positive rate
# (pass$ matches Protocol/abstract/except bodies; "belongs to another plan" is judgment).
# shellcheck source=lib/timeout-guard.sh
source "$SCRIPTS_DIR/lib/timeout-guard.sh"
MERGE_GATE_TIMEOUT="${CLAUDE_SMOKE_TIMEOUT:-3600}"
timeout_guard_init "$MERGE_GATE_TIMEOUT" CLAUDE_SMOKE_TIMEOUT merge-gate "$PLAN" "$PF"

_det_fail=""

# Criterion 3 — tasks-complete: any non-completed row in the Task Ledger blocks.
# Parser mirrors dev-cycle-phases.sh:330; status enum is closed (plan-cmd.sh:1012).
_pending=$(awk '/^## Task Ledger/{f=1;next} f&&/^## /{exit} f&&/\| pending[ |]|\| in_progress[ |]|\| blocked[ |]/' "$PLAN" 2>/dev/null || true)
[[ -n "$_pending" ]] && _det_fail="${_det_fail}FAIL criterion=tasks-complete: ledger has non-completed rows:
${_pending}
"

# Criterion 2 — test-integrity: for each test(red): commit on this branch, no later
# commit (other than test(red): / chore(state):) may touch its test files.
while IFS= read -r _red_sha; do
  [[ -z "$_red_sha" ]] && continue
  _rfiles=$(git -C "$PROJECT_DIR" show --name-only --format= "$_red_sha" 2>/dev/null \
    | grep -E '(^|/)tests/|(^|/)conftest\.|_test\.|(^|/)test_|\.test\.|\.spec\.|_spec\.' | grep -v '\.spec\.md$' || true)
  [[ -z "$_rfiles" ]] && continue
  while IFS= read -r _tf; do
    [[ -z "$_tf" ]] && continue
    _bad=$(git -C "$PROJECT_DIR" log --oneline "${_red_sha}..HEAD" -- "$_tf" 2>/dev/null \
      | grep -vE ' (test\(red\)|chore\(state\)):' || true)
    [[ -n "$_bad" ]] && _det_fail="${_det_fail}FAIL criterion=test-integrity: ${_tf} modified after Red commit ${_red_sha:0:8}:
${_bad}
"
  done <<< "$_rfiles"
done <<< "$(git -C "$PROJECT_DIR" log --grep='^test(red):' --format='%H' "${MAIN_BRANCH}..HEAD" 2>/dev/null || true)"

# Criterion 1 — tests-green: unit (+integration) suite must exit 0. Unit has one retry to
# absorb flakiness; second failure is authoritative. Integration runs once (single-run). Run inside the sandbox via worker_exec.
# Output goes to sibling files so the LLM's later report (overwrites $REPORT_FILE) stays clean.
if [[ -n "$UNIT_CMD" ]]; then
  # shellcheck disable=SC2086
  _tg_unit() { ( cd "$PROJECT_DIR" && worker_exec ${TIMEOUT_CMD:+$TIMEOUT_CMD --kill-after="$TG_KILL_AFTER" "$MERGE_GATE_TIMEOUT"} bash -c "$UNIT_CMD" >>"${REPORT_FILE}.unit" 2>&1 ); }
  _ec=0; _tg_unit || _ec=$?
  if [[ "$_ec" -eq 124 ]]; then
    _det_fail="${_det_fail}FAIL criterion=tests-green: unit suite TIMEOUT after ${MERGE_GATE_TIMEOUT}s
"
  elif [[ "$_ec" -ne 0 ]]; then
    _ec2=0; _tg_unit || _ec2=$?
    [[ "$_ec2" -ne 0 ]] && _det_fail="${_det_fail}FAIL criterion=tests-green: unit suite exited ${_ec2} (retried once)
"
  fi
fi
if [[ -n "$INTEGRATION_CMD" ]]; then
  _eci=0
  # shellcheck disable=SC2086
  ( cd "$PROJECT_DIR" && worker_exec ${TIMEOUT_CMD:+$TIMEOUT_CMD --kill-after="$TG_KILL_AFTER" "$MERGE_GATE_TIMEOUT"} bash -c "$INTEGRATION_CMD" >>"${REPORT_FILE}.integration" 2>&1 ) || _eci=$?
  [[ "$_eci" -ne 0 ]] && _det_fail="${_det_fail}FAIL criterion=tests-green(integration): exited ${_eci}
"
fi

# Authoritative verdict — deterministic FAIL never reaches the LLM.
if [[ -n "$_det_fail" ]]; then
  {
    echo "MERGE-GATE TIER-1 (deterministic) — FAIL"
    echo "plan: ${SLUG}"; echo "branch: ${BRANCH}"; echo ""
    printf '%s' "$_det_fail"; echo ""
    echo "MERGE-READY: no"
  } > "$REPORT_FILE"
  bash "$PF" append-note "$PLAN" "[BLOCKED:code] merge-gate-tier1 — deterministic pre-gate failed (tests-green/test-integrity/tasks-complete); see ${REPORT_FILE}. Fix the root cause; the gate re-derives truth from git/exit-codes every run and cannot be cleared by a plan note."
  echo "[merge-gate] FAIL (Tier-1 deterministic) — see $REPORT_FILE" >&2
  cat "$REPORT_FILE" >&2
  exit 1
fi
echo "[merge-gate] Tier-1 deterministic checks PASSED — proceeding to LLM audit."

echo "[merge-gate] Running final branch integrity audit for ${SLUG}…"
_CALL_RC=0
CLAUDE_NONINTERACTIVE=1 CLAUDE_CRITIC_SESSION=1 CLAUDE_PLAN_FILE="${PLAN}" \
  worker_exec env -u CLAUDE_PLAN_CAPABILITY claude --model sonnet --permission-mode auto --dangerously-skip-permissions \
  -p "You are critic-merge. Run the merge-gate audit for plan ${PLAN} on branch ${BRANCH}. $(cat "$SCRIPTS_DIR/../agents/critic-merge.md" 2>/dev/null || echo 'See agents/critic-merge.md')" \
  > "$REPORT_FILE" 2>&1 || _CALL_RC=$?

if [[ $_CALL_RC -ne 0 ]]; then
  echo "[merge-gate] critic-merge invocation failed (exit ${_CALL_RC})" >&2
  bash "$PF" append-note "$PLAN" "[BLOCKED:env] merge-gate: critic-merge-invocation-failed — LLM exit ${_CALL_RC}; re-run to retry or check claude availability" 2>/dev/null || true
  exit 1
fi

if grep -qE '^MERGE-READY: yes[[:space:]]*$' "$REPORT_FILE" 2>/dev/null; then
  echo "[merge-gate] PASS — branch ${BRANCH} is merge-ready."
  cat "$REPORT_FILE"
  exit 0
else
  echo "[merge-gate] FAIL — branch ${BRANCH} did not pass all criteria." >&2
  cat "$REPORT_FILE" >&2
  bash "$PF" append-note "$PLAN" "[BLOCKED:code] merge-gate: integrity-fail — see ${REPORT_FILE}. Fix the identified issues, then re-run." 2>/dev/null || true
  exit 1
fi
