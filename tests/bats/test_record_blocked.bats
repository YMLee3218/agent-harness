#!/usr/bin/env bats
# Tests for G10 _record_blocked helper contract.

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

setup() {
  setup_plan_dir
}

teardown() {
  teardown_plan_dir
}

@test "G10: _record_blocked writes a valid JSON record to blocked.jsonl" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    sc_ensure_dir "'"$PLAN_FILE"'"
    _record_blocked "'"$PLAN_FILE"'" "runtime" "harness" "test/scope" "test message"
    bpath=$(sc_path "'"$PLAN_FILE"'" "blocked.jsonl")
    jq -r ".kind" "$bpath"
  ' 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == "runtime" ]]
}

@test "G10: _record_blocked sets cleared_at null" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    sc_ensure_dir "'"$PLAN_FILE"'"
    _record_blocked "'"$PLAN_FILE"'" "ceiling" "critic-code" "implement/critic-code" "exceeded runs"
    bpath=$(sc_path "'"$PLAN_FILE"'" "blocked.jsonl")
    jq -r ".cleared_at" "$bpath"
  ' 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == "null" ]]
}

@test "G10: _record_blocked NOLCK=1 writes without locking (caller holds lock)" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    sc_ensure_dir "'"$PLAN_FILE"'"
    _record_blocked "'"$PLAN_FILE"'" "runtime" "harness" "test/scope" "fallback test" 1
    bpath=$(sc_path "'"$PLAN_FILE"'" "blocked.jsonl")
    jq -r ".message" "$bpath"
  ' 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == "fallback test" ]]
}

@test "H6: sc_dir dies on path traversal outside plans/ tree (F6 regression)" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    sc_dir "/tmp/../etc/cron.d/evil.md"
  ' 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside plans/"* || "$output" == *"FATAL"* ]]
}

@test "H6: sc_dir accepts a valid plans/ path" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    sc_dir "'"$PLAN_FILE"'"
  ' 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *".state" ]]
}

@test "B1 regression: _with_lock uses mkdir-based locking (acquires and releases cleanly)" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir"
  # B1: lockdir approach — mkdir is atomic and TOCTOU-safe by design.
  # Verify positive case: lock acquired, body executed, lockdir cleaned up.
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    _noop() { echo "ran"; }
    _with_lock "'"$state_dir"'/planfile.md" "_noop"
  ' 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"ran"* ]]
  # Lockdir must be cleaned up after successful execution
  [ ! -d "${state_dir}/planfile.md.lockdir" ]
}

@test "B1 regression: _with_lock lockdir is removed even on body failure" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir"
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    _fail() { return 1; }
    _with_lock "'"$state_dir"'/planfile.md" "_fail" || true
  ' 2>&1
  # Lockdir must be cleaned up even on failure
  [ ! -d "${state_dir}/planfile.md.lockdir" ]
}

@test "C2 regression: sc_dir dies when plan is outside CLAUDE_PROJECT_DIR/plans/" {
  run bash -c '
    export CLAUDE_PROJECT_DIR=/nonexistent/project
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    sc_dir "'"$PLAN_FILE"'"
  ' 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside"* || "$output" == *"FATAL"* || "$output" == *"not a valid directory"* ]]
}

@test "B2 regression: sc_dir fails closed when CLAUDE_PROJECT_DIR is unset" {
  run bash -c '
    unset CLAUDE_PROJECT_DIR
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    sc_dir "'"$PLAN_FILE"'"
  ' 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"required"* || "$output" == *"FATAL"* || "$output" == *"unset"* ]]
}

# ── T-12: nested marker strip ─────────────────────────────────────────────────

@test "T-12: _record_blocked strips leading BLOCKED marker from message" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    sc_ensure_dir "'"$PLAN_FILE"'"
    _record_blocked "'"$PLAN_FILE"'" "runtime" "critic-code" "implement/critic-code" \
      "[BLOCKED] foo: [BLOCKED-CEILING] x"
    cat "$(sc_path "'"$PLAN_FILE"'" blocked.jsonl)"
  ' 2>&1
  # The stored message must NOT start with [BLOCKED...]
  [[ "$output" != *'"message":"[BLOCKED'* ]]
}

@test "T-12: _record_blocked NOLCK=1 strips nested BLOCKED markers" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    sc_ensure_dir "'"$PLAN_FILE"'"
    _bpath=$(sc_path "'"$PLAN_FILE"'" blocked.jsonl)
    _record_blocked "'"$PLAN_FILE"'" "runtime" "critic-code" "implement/critic-code" \
      "[BLOCKED-CEILING] some ceiling message" 1
    cat "$_bpath"
  ' 2>&1
  [[ "$output" != *'"message":"[BLOCKED'* ]]
  [ "$status" -eq 0 ]
  [[ "$output" == *'"message":"some ceiling message"'* ]]
}

@test "L2 regression: sc_path propagates sc_dir exit code (no empty path)" {
  run bash -c '
    export CLAUDE_PROJECT_DIR=/nonexistent/project
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    result=$(sc_path "'"$PLAN_FILE"'" "blocked.jsonl" 2>/dev/null)
    echo "exit=$? result=${result:-EMPTY}"
  ' 2>&1
  # sc_path should fail (non-zero) and stdout should be empty or contain the error
  # The bash -c itself exits non-zero when sc_path propagates the error
  [[ "$output" != *"result=/blocked.jsonl"* ]]
}
