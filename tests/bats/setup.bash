#!/usr/bin/env bash
# Shared setup for all bats tests — sourced via `load setup` in each .bats file.

# Create a temporary plan dir with sidecar and minimal plan file.
# PLAN_DIR points to the plans/ subdirectory so sc_dir's */plans/*.md check passes.
setup_plan_dir() {
  PLAN_BASE=$(mktemp -d)
  PLAN_DIR="$PLAN_BASE/plans"
  mkdir -p "$PLAN_DIR"
  PLAN_FILE="$PLAN_DIR/test-feature.md"
  cat > "$PLAN_FILE" <<'EOF'
---
feature: test-feature
phase: implement
schema: 2
---

## Vision

## Scenarios

## Test Manifest

## Phase
implement

## Phase Transitions
- brainstorm → (initial)

## Critic Verdicts

## Task Ledger

## Integration Failures

## Verdict Audits

## Open Questions
EOF
  mkdir -p "$PLAN_DIR/test-feature.state/convergence"
  export PLAN_FILE PLAN_DIR
  export CLAUDE_PLAN_FILE="$PLAN_FILE"
  export CLAUDE_PROJECT_DIR="$PLAN_BASE"
}

teardown_plan_dir() {
  [[ -n "${PLAN_BASE:-}" ]] && rm -rf "$PLAN_BASE"
}


SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts"

# _load_plan_libs [full] — prints shell source commands for inline bash -c test blocks.
# Without "full": sources through plan-loop-helpers (no plan-cmd, no harness capability).
# With "full": also sources plan-cmd and sets CLAUDE_PLAN_CAPABILITY=harness + CLAUDE_PLAN_FILE.
_load_plan_libs() {
  local _mode="${1:-}"
  printf '
    export CLAUDE_PROJECT_DIR="%s"
    source "%s/lib/active-plan.sh"
    source "%s/phase-policy.sh"
    source "%s/lib/sidecar.sh"
    export PLAN_FILE_SH="%s/plan-file.sh"
    source "%s/lib/plan-lib.sh"
    source "%s/lib/plan-loop-helpers.sh"
  ' "$PLAN_BASE" \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR" \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR"
  if [[ "$_mode" == "full" ]]; then
    printf '
    export CLAUDE_PLAN_CAPABILITY=harness
    source "%s/lib/plan-cmd.sh"
    export CLAUDE_PLAN_FILE="%s"
    ' "$SCRIPTS_DIR" "$PLAN_FILE"
  fi
}
