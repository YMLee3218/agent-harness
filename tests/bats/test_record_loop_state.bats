#!/usr/bin/env bats
# T8: _record_loop_state edge cases — jsonl append failure, ceiling-blocked early exit.

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

setup() {
  setup_plan_dir
}

teardown() {
  teardown_plan_dir
}

_load_libs() { _load_plan_libs; }

@test "T8/L1: ceiling_blocked=true in conv_state triggers immediate rc=1 without scanning jsonl" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir/convergence"
  # Set ceiling_blocked=true in convergence JSON
  printf '{"phase":"implement","agent":"critic-code","first_turn":true,"streak":0,"converged":false,"ceiling_blocked":true,"ordinal":5,"milestone_seq":0}\n' \
    > "$state_dir/convergence/implement__critic-code.json"
  # No verdicts.jsonl — if L1 early-exit works, jq scan never happens

  run bash -c "
    $(_load_libs)
    set +e
    _record_loop_state '$PLAN_FILE' implement critic-code PASS
    echo rc=\$?
  " 2>&1
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"ceiling-blocked"* || "$output" == *"BLOCKED-CEILING"* ]]
}

# ── T-H1: L3 race fix regression ─────────────────────────────────────────────

@test "T-H1: C1/L3 race — ceiling_block survives to final state (public API)" {
  # Verify that after the ceiling-triggering call, BLOCKED-CEILING is written to
  # the plan file (public API) — tests the same race fix without reading internal JSON.
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir/convergence"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  for i in 1 2 3 4 5; do
    printf '{"ts":"%s","phase":"implement","agent":"critic-code","verdict":"PASS","category":"","ordinal":%d,"milestone_seq":0}\n' \
      "$ts" "$i" >> "$state_dir/verdicts.jsonl"
  done
  printf '{"phase":"implement","agent":"critic-code","first_turn":true,"streak":0,"converged":false,"ceiling_blocked":false,"ordinal":5,"milestone_seq":0}\n' \
    > "$state_dir/convergence/implement__critic-code.json"

  run bash -c "
    $(_load_libs)
    export CLAUDE_CRITIC_LOOP_CEILING=5
    set +e
    _record_loop_state '$PLAN_FILE' implement critic-code PASS
    echo rc=\$?
  " 2>&1
  [[ "$output" == *"rc=1"* ]]
  grep -q 'BLOCKED-CEILING' "$PLAN_FILE"
}


