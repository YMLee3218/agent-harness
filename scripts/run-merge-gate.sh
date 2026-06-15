#!/usr/bin/env bash
# Merge gate: final branch integrity check before plan merge into main.
# Called from run-dev-cycle.sh when phase reaches 'done'.
# Exit 0: gate passed (caller may proceed to merge-approval marker).
# Exit 1: gate failed (caller must re-block the plan).
set -euo pipefail
if [[ "${CLAUDE_PLAN_CAPABILITY:-}" != "harness" ]]; then
  exec /usr/bin/env CLAUDE_PLAN_CAPABILITY=harness "$0" "$@"
fi

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/run-context.sh
source "$SCRIPTS_DIR/lib/run-context.sh"
setup_run_context
# shellcheck source=lib/llm-runner.sh
source "$SCRIPTS_DIR/lib/llm-runner.sh"

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

export CRITIC_MERGE_PLAN="$PLAN"
export CRITIC_MERGE_BRANCH="$BRANCH"
export CRITIC_MERGE_MAIN="$MAIN_BRANCH"
export CRITIC_MERGE_TEST_CMD="${UNIT_CMD}"
export CRITIC_MERGE_INTEGRATION_CMD="${INTEGRATION_CMD}"

echo "[merge-gate] Running final branch integrity audit for ${SLUG}…"
_CALL_RC=0
CLAUDE_NONINTERACTIVE=1 CLAUDE_CRITIC_SESSION=1 CLAUDE_PLAN_FILE="${PLAN}" \
  env -u CLAUDE_PLAN_CAPABILITY claude --model sonnet --permission-mode auto --dangerously-skip-permissions \
  -p "You are critic-merge. Run the merge-gate audit for plan ${PLAN} on branch ${BRANCH}. $(cat "$SCRIPTS_DIR/../agents/critic-merge.md" 2>/dev/null || echo 'See agents/critic-merge.md')" \
  > "$REPORT_FILE" 2>&1 || _CALL_RC=$?

if [[ $_CALL_RC -ne 0 ]]; then
  echo "[merge-gate] critic-merge invocation failed (exit ${_CALL_RC})" >&2
  exit 1
fi

if grep -qE '^MERGE-READY: yes[[:space:]]*$' "$REPORT_FILE" 2>/dev/null; then
  echo "[merge-gate] PASS — branch ${BRANCH} is merge-ready."
  cat "$REPORT_FILE"
  exit 0
else
  echo "[merge-gate] FAIL — branch ${BRANCH} did not pass all criteria." >&2
  cat "$REPORT_FILE" >&2
  exit 1
fi
