#!/usr/bin/env bats
# T2: _jq_compute_or_fail contract tests 

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
    source "%s/lib/active-plan.sh"
    source "%s/phase-policy.sh"
    source "%s/lib/sidecar.sh"
    export PLAN_FILE_SH="%s/plan-file.sh"
    source "%s/lib/plan-lib.sh"
  ' "$PLAN_BASE" \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR" \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR"
}

@test "T2: _jq_compute_or_fail returns output for valid jsonl" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir"
  local jsonl="$state_dir/verdicts.jsonl"
  printf '{"phase":"implement","agent":"critic-code","verdict":"PASS","ordinal":1,"milestone_seq":0}\n' > "$jsonl"

  run bash -c "
    $(_load_libs)
    sc_ensure_dir '$PLAN_FILE'
    _jq_compute_or_fail '$PLAN_FILE' '$jsonl' 'test-label' \
      'select(.phase == \$p) | .verdict' --arg p 'implement'
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == "PASS" ]]
}

@test "T2: _jq_compute_or_fail returns non-zero on corrupt jsonl (no BLOCKED side effect)" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir"
  local jsonl="$state_dir/verdicts.jsonl"
  printf 'CORRUPT_JSON\n' > "$jsonl"

  run bash -c "
    $(_load_libs)
    sc_ensure_dir '$PLAN_FILE'
    set +e
    _jq_compute_or_fail '$PLAN_FILE' '$jsonl' 'test-label' '.'
    echo rc=\$?
  " 2>&1
  [[ "$output" == *"rc=1"* ]]
}

@test "T2: _jq_compute_or_fail returns non-zero on corrupt jsonl" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir"
  local jsonl="$state_dir/verdicts.jsonl"
  printf 'CORRUPT_JSON\n' > "$jsonl"

  run bash -c "
    $(_load_libs)
    sc_ensure_dir '$PLAN_FILE'
    _jq_compute_or_fail '$PLAN_FILE' '$jsonl' 'test-label' '.'
  " 2>&1
  [ "$status" -ne 0 ]
}

@test "T2: _jq_compute_or_fail refuses symlink at lock path (B8 regression)" {
  # symlink guard only active when flock is available
  command -v flock >/dev/null 2>&1 || skip "flock not available — symlink guard only active with flock"
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir"
  local jsonl="$state_dir/verdicts.jsonl"
  printf '{"x":1}\n' > "$jsonl"
  # Place a symlink at the lock path
  ln -s /tmp/victim "${jsonl}.lock"

  run bash -c "
    $(_load_libs)
    sc_ensure_dir '$PLAN_FILE'
    _jq_compute_or_fail '$PLAN_FILE' '$jsonl' 'test' '.'
  " 2>&1
  # Should fail due to symlink at lock path
  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* || "$output" == *"FATAL"* ]]
}
