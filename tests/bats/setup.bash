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
