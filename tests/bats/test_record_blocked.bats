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

# ── T-12: nested marker strip ─────────────────────────────────────────────────

@test "T-12: _record_blocked strips leading BLOCKED markers (locking and non-locking)" {
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

