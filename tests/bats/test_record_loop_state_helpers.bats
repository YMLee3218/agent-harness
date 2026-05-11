#!/usr/bin/env bats
# T8: Unit tests for 11th-cycle R3 split helpers in plan-loop-state.sh.

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

setup() {
  setup_plan_dir
}

teardown() {
  teardown_plan_dir
}

_load_libs() {
  printf '
    export CLAUDE_PROJECT_DIR="%s"
    export CLAUDE_PLAN_CAPABILITY=harness
    source "%s/lib/active-plan.sh"
    source "%s/phase-policy.sh"
    source "%s/lib/sidecar.sh"
    export PLAN_FILE_SH="%s/plan-file.sh"
    source "%s/lib/plan-lib.sh"
    source "%s/lib/plan-loop-state.sh"
  ' "$PLAN_BASE" \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR" \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR"
}

# ── _validated_ceiling ────────────────────────────────────────────────────────

@test "T8: _validated_ceiling: empty string falls back to 5" {
  run bash -c "
    $(_load_libs)
    _validated_ceiling '' 2>/dev/null
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == "5" ]]
}

@test "T8: _validated_ceiling: non-numeric falls back to 5 with warning" {
  run bash -c "
    $(_load_libs)
    _validated_ceiling 'abc' 2>&1
  " 2>&1
  [[ "$output" == *"5"* ]]
  [[ "$output" == *"invalid"* || "$output" == *"falling back"* ]]
}

@test "T8: _validated_ceiling: negative integer falls back to 5 with warning" {
  run bash -c "
    $(_load_libs)
    _validated_ceiling '-1' 2>&1
  " 2>&1
  [[ "$output" == *"5"* ]]
}

@test "T8: _validated_ceiling: 1 (< 2) falls back to 5 with warning" {
  run bash -c "
    $(_load_libs)
    _validated_ceiling '1' 2>&1
  " 2>&1
  [[ "$output" == *"5"* ]]
  [[ "$output" == *"< 2"* || "$output" == *"falling back"* ]]
}

@test "T8: _validated_ceiling: valid value 3 returns 3" {
  run bash -c "
    $(_load_libs)
    _validated_ceiling '3'
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == "3" ]]
}

@test "T8: _validated_ceiling: valid value 10 returns 10" {
  run bash -c "
    $(_load_libs)
    _validated_ceiling '10'
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == "10" ]]
}

# ── _get_run_ordinal ─────────────────────────────────────────────────────────

@test "T8: _get_run_ordinal: empty verdicts → ordinal 1" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir"
  local vpath="$state_dir/verdicts.jsonl"

  run bash -c "
    $(_load_libs)
    sc_ensure_dir '$PLAN_FILE'
    _get_run_ordinal '$PLAN_FILE' '$vpath' 'implement' 'critic-code' '0'
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == "1" ]]
}

@test "T8: _get_run_ordinal: 2 prior verdicts → ordinal 3" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir"
  local vpath="$state_dir/verdicts.jsonl"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '{"ts":"%s","phase":"implement","agent":"critic-code","verdict":"PASS","category":"","ordinal":1,"milestone_seq":0}\n' "$ts" > "$vpath"
  printf '{"ts":"%s","phase":"implement","agent":"critic-code","verdict":"PASS","category":"","ordinal":2,"milestone_seq":0}\n' "$ts" >> "$vpath"

  run bash -c "
    $(_load_libs)
    sc_ensure_dir '$PLAN_FILE'
    _get_run_ordinal '$PLAN_FILE' '$vpath' 'implement' 'critic-code' '0'
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == "3" ]]
}

@test "T8: _get_run_ordinal: corrupt jsonl skips invalid lines → ordinal 1" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir"
  local vpath="$state_dir/verdicts.jsonl"
  printf 'NOT_JSON\n' > "$vpath"

  run bash -c "
    $(_load_libs)
    sc_ensure_dir '$PLAN_FILE'
    _get_run_ordinal '$PLAN_FILE' '$vpath' 'implement' 'critic-code' '0'
  " 2>&1
  # Lenient jq skips invalid lines, treats file as empty → prior_ordinal=0 → ordinal=1
  [ "$status" -eq 0 ]
  [[ "$output" == "1" ]]
}

# ── _ceiling_block ────────────────────────────────────────────────────────────

@test "T8: _ceiling_block: ordinal <= ceiling → rc=0 (not blocked)" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir/convergence"
  local conv_path="$state_dir/convergence/implement__critic-code.json"
  local conv_state='{"phase":"implement","agent":"critic-code","first_turn":false,"streak":0,"converged":false,"ceiling_blocked":false,"ordinal":3,"milestone_seq":0}'

  run bash -c "
    $(_load_libs)
    set +e
    sc_ensure_dir '$PLAN_FILE'
    _ceiling_block '$PLAN_FILE' 'implement' 'critic-code' 'implement/critic-code' \
      3 5 '$conv_state' '$conv_path'
    echo rc=\$?
  " 2>&1
  [[ "$output" == *"rc=0"* ]]
}

@test "T8: _ceiling_block: ordinal > ceiling → rc=1 and plan.md has BLOCKED-CEILING" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir/convergence"
  local conv_path="$state_dir/convergence/implement__critic-code.json"
  local conv_state='{"phase":"implement","agent":"critic-code","first_turn":false,"streak":0,"converged":false,"ceiling_blocked":false,"ordinal":5,"milestone_seq":0}'

  run bash -c "
    $(_load_libs)
    set +e
    sc_ensure_dir '$PLAN_FILE'
    _ceiling_block '$PLAN_FILE' 'implement' 'critic-code' 'implement/critic-code' \
      6 5 '$conv_state' '$conv_path'
    echo rc=\$?
    grep '\[BLOCKED-CEILING\]' '$PLAN_FILE' && echo 'marker_found'
  " 2>&1
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"marker_found"* ]]
}

# ── _compute_streak ───────────────────────────────────────────────────────────

@test "T8: _compute_streak: PASS verdict on empty history → streak 1" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir"
  local vpath="$state_dir/verdicts.jsonl"

  run bash -c "
    $(_load_libs)
    sc_ensure_dir '$PLAN_FILE'
    _compute_streak '$PLAN_FILE' '$vpath' 'PASS' 'implement' 'critic-code' '0'
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == "1" ]]
}

@test "T8: _compute_streak: PASS+PASS → streak 3" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir"
  local vpath="$state_dir/verdicts.jsonl"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '{"ts":"%s","phase":"implement","agent":"critic-code","verdict":"PASS","category":"","ordinal":1,"milestone_seq":0}\n' "$ts" > "$vpath"
  printf '{"ts":"%s","phase":"implement","agent":"critic-code","verdict":"PASS","category":"","ordinal":2,"milestone_seq":0}\n' "$ts" >> "$vpath"

  run bash -c "
    $(_load_libs)
    sc_ensure_dir '$PLAN_FILE'
    _compute_streak '$PLAN_FILE' '$vpath' 'PASS' 'implement' 'critic-code' '0'
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == "3" ]]
}

@test "T8: _compute_streak: PASS then FAIL resets to 0 for FAIL verdict" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir"
  local vpath="$state_dir/verdicts.jsonl"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '{"ts":"%s","phase":"implement","agent":"critic-code","verdict":"PASS","category":"","ordinal":1,"milestone_seq":0}\n' "$ts" > "$vpath"

  run bash -c "
    $(_load_libs)
    sc_ensure_dir '$PLAN_FILE'
    _compute_streak '$PLAN_FILE' '$vpath' 'FAIL' 'implement' 'critic-code' '0'
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == "0" ]]
}
