#!/usr/bin/env bats
# T1: _record_blocked_runtime contract tests 

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

@test "T1: _record_blocked_runtime writes kind=runtime to blocked.jsonl" {
  run bash -c "
    $(_load_libs)
    sc_ensure_dir '$PLAN_FILE'
    _record_blocked_runtime '$PLAN_FILE' 'harness' 'test/scope' 'test message'
    bpath=\$(sc_path '$PLAN_FILE' 'blocked.jsonl')
    jq -r '.kind' \"\$bpath\"
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == "runtime" ]]
}

@test "T1: _record_blocked_runtime writes correct agent and scope" {
  run bash -c "
    $(_load_libs)
    sc_ensure_dir '$PLAN_FILE'
    _record_blocked_runtime '$PLAN_FILE' 'critic-code' 'implement/critic-code' 'blocked message'
    bpath=\$(sc_path '$PLAN_FILE' 'blocked.jsonl')
    jq -r '.agent + \" \" + .scope' \"\$bpath\"
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == "critic-code implement/critic-code" ]]
}

@test "T1: _record_blocked_runtime appends [BLOCKED] marker to Open Questions" {
  run bash -c "
    $(_load_libs)
    sc_ensure_dir '$PLAN_FILE'
    _record_blocked_runtime '$PLAN_FILE' 'harness' 'test/scope' 'my message'
    grep '\[BLOCKED\] test/scope:harness: my message' '$PLAN_FILE'
  " 2>&1
  [ "$status" -eq 0 ]
}

@test "T1: _record_blocked_runtime sets cleared_at null in blocked.jsonl" {
  run bash -c "
    $(_load_libs)
    sc_ensure_dir '$PLAN_FILE'
    _record_blocked_runtime '$PLAN_FILE' 'harness' 'verdicts' 'compute failed'
    bpath=\$(sc_path '$PLAN_FILE' 'blocked.jsonl')
    jq -r '.cleared_at' \"\$bpath\"
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == "null" ]]
}

@test "T1: _record_blocked_runtime without prior sc_ensure_dir still succeeds (L3 regression)" {
  run bash -c "
    $(_load_libs)
    # Remove existing sidecar dir to simulate missing dir
    rm -rf '${PLAN_DIR}/test-feature.state'
    _record_blocked_runtime '$PLAN_FILE' 'harness' 'test/scope' 'auto-created'
    bpath=\$(sc_path '$PLAN_FILE' 'blocked.jsonl')
    jq -r '.kind' \"\$bpath\"
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == "runtime" ]]
}

@test "T1: _record_blocked_runtime message appears in blocked.jsonl message field" {
  run bash -c "
    $(_load_libs)
    sc_ensure_dir '$PLAN_FILE'
    _record_blocked_runtime '$PLAN_FILE' 'harness' 'scope' 'the specific message'
    bpath=\$(sc_path '$PLAN_FILE' 'blocked.jsonl')
    jq -r '.message' \"\$bpath\"
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == "the specific message" ]]
}
