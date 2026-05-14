#!/usr/bin/env bash
set -euo pipefail
if [[ "${CLAUDE_PLAN_CAPABILITY:-}" != "harness" ]]; then
  exec /usr/bin/env CLAUDE_PLAN_CAPABILITY=harness "$0" "$@"
fi
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PF="$SCRIPTS_DIR/plan-file.sh"
PLAN="" _CALL_RC=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --plan) PLAN="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# Resolve plan file if not provided
if [[ -z "$PLAN" ]]; then
  find_rc=0
  PLAN=$(bash "$PF" find-active 2>/dev/null) || find_rc=$?
  case $find_rc in
    0) ;;
    2) PLAN="" ;;
    3) echo "[BLOCKED] Multiple active plan files — set CLAUDE_PLAN_FILE=plans/{slug}.md then re-run" >&2; exit 1 ;;
    4) echo "[BLOCKED] Plan file phase unreadable — check ## Phase section" >&2; exit 1 ;;
    *) PLAN="" ;;
  esac
fi

# shellcheck source=lib/run-context.sh
source "$SCRIPTS_DIR/lib/run-context.sh"
setup_run_context

UNIT_CMD=$(grep -m1 '^\- Test:' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null | sed 's/^- Test: *//;s/^`//;s/`.*$//' || echo "")
INTEGRATION_CMD=$(grep -m1 '^\- Integration test:' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null | sed 's/^- Integration test: *//;s/^`//;s/`.*$//' || echo "")
[[ "$UNIT_CMD" == _\(run* ]] && UNIT_CMD=""
[[ "$INTEGRATION_CMD" == _\(run* ]] && INTEGRATION_CMD=""

# shellcheck source=lib/dev-cycle-phases.sh
source "$SCRIPTS_DIR/lib/dev-cycle-phases.sh"
# shellcheck source=lib/llm-runner.sh
source "$SCRIPTS_DIR/lib/llm-runner.sh"

# Preflight: abort if preflight-blocked
if [[ -n "$PLAN" ]]; then
  if bash "$PF" is-blocked "$PLAN" preflight 2>/dev/null; then
    echo "[BLOCKED] preflight marker present — resolve and re-run" >&2; exit 1
  fi
fi

# Phase-aware routing when plan exists
if [[ -n "$PLAN" ]]; then
  current_phase=$(bash "$PF" get-phase "$PLAN" 2>/dev/null || echo "")
  if bash "$PF" is-blocked "$PLAN" 2>/dev/null; then
    echo "[BLOCKED] active block marker present — resolve markers before proceeding" >&2; exit 1
  fi
  case "$current_phase" in
    brainstorm|spec|red|implement|review|green|integration) ;;
    done)
      _found_next=0
      for _p in "${PROJECT_DIR}/plans/"*.md; do
        [[ -f "$_p" && "$_p" != "$PLAN" ]] || continue
        _p_phase=$(bash "$PF" get-phase "$_p" 2>/dev/null || echo "")
        if [[ -n "$_p_phase" && "$_p_phase" != "done" ]]; then
          PLAN="$_p"; current_phase="$_p_phase"; _found_next=1; break
        fi
      done
      if [[ $_found_next -eq 0 ]]; then
        echo "[DONE] All requirements complete. Run /brainstorming to start a new requirement." >&2
        exit 0
      fi
      ;;
    *) echo "[BLOCKED] unrecognised plan phase: ${current_phase}" >&2; exit 1 ;;
  esac
fi

MODE="feature"

# ── Step 1: Brainstorming ─────────────────────────────────────────────────────
if [[ -z "$PLAN" ]] || \
   { [[ -n "${current_phase:-}" ]] && [[ "$current_phase" == "brainstorm" ]] && \
     ! bash "$PF" is-converged "$PLAN" brainstorm critic-feature 2>/dev/null; }; then
  run_llm "Invoke the brainstorming skill." opus
  llm_exit "brainstorming"
  find_rc=0
  PLAN=$(bash "$PF" find-active 2>/dev/null) || find_rc=$?
  case $find_rc in
    0) [[ -n "$PLAN" ]] || { echo "ERROR: plan file not created by brainstorming" >&2; exit 1; } ;;
    3) echo "ERROR: multiple active plan files after brainstorming — set CLAUDE_PLAN_FILE=plans/{slug}.md" >&2; exit 1 ;;
    4) echo "ERROR: plan file phase unreadable after brainstorming — repair the ## Phase section" >&2; exit 1 ;;
    *) echo "ERROR: plan file not created by brainstorming (find-active rc=$find_rc)" >&2; exit 1 ;;
  esac
  if grep -q '^mode:' "$PLAN" 2>/dev/null; then
    sed -i '' "s/^mode:.*$/mode: ${MODE}/" "$PLAN" 2>/dev/null || true
  else
    awk -v m="${MODE}" '/^---$/ && ++n==2 {print "mode: " m} 1' \
      "$PLAN" > "${PLAN}.tmp" && mv "${PLAN}.tmp" "$PLAN" 2>/dev/null || true
  fi
  bash "$PF" reset-milestone "$PLAN" critic-feature
  run_critic critic-feature brainstorm \
    "Review docs/requirements/$(basename "$PLAN" .md).md."
  llm_exit "critic-feature"
  current_phase="brainstorm"
fi

SLUG=$(basename "$PLAN" .md)
REQ_FILE="$PROJECT_DIR/docs/requirements/${SLUG}.md"

get_features() {
  [[ -f "$REQ_FILE" ]] && _features_block "$REQ_FILE" || echo ""
}

# Integration phase re-entry: skip feature loop
if [[ "${current_phase:-}" == "integration" ]]; then
  if [[ -n "$INTEGRATION_CMD" ]]; then
    bash "$SCRIPTS_DIR/run-integration.sh" --plan "$PLAN" \
      --unit-cmd "$UNIT_CMD" --integration-cmd "$INTEGRATION_CMD"
  else
    echo "[SKIP] integration tests — no command found in CLAUDE.md"
    bash "$PF" transition "$PLAN" done "no integration test command — skipped"
  fi
  exit $?
fi

if [[ -z "$(get_features)" ]]; then
  bash "$PF" append-note "$PLAN" "[BLOCKED] run-dev-cycle: no features in ${REQ_FILE} — run /brainstorming first"
  exit 1
fi

# ── Feature-slice phases ──────────────────────────────────────────────────────
_phase_spec_prepass
_phase_cross_spec_review
_phase_implement_cycle

# ── Integration Tests ─────────────────────────────────────────────────────────
if [[ -n "$INTEGRATION_CMD" ]]; then
  bash "$SCRIPTS_DIR/run-integration.sh" \
    --plan "$PLAN" \
    --unit-cmd "$UNIT_CMD" \
    --integration-cmd "$INTEGRATION_CMD"
else
  echo "[SKIP] integration tests — no command found in CLAUDE.md"
  bash "$PF" transition "$PLAN" done "no integration test command — skipped"
fi
