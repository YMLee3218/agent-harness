#!/usr/bin/env bats
# F29: meta-tests verifying dispatcher ↔ cmd_* function consistency.

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

@test "F29: no duplicate cmd_* function definitions in lib/" {
  local dups
  dups=$(grep -hE '^cmd_[a-z_]+\(\)' "$SCRIPTS_DIR/lib/"*.sh | sort | uniq -d)
  [[ -z "$dups" ]]
}

@test "F29: cmd_append_note has exactly one definition in plan-cmd.sh" {
  run grep -c '^cmd_append_note()' "$SCRIPTS_DIR/lib/plan-cmd.sh"
  [ "$status" -eq 0 ]
  [[ "$output" -eq 1 ]]
}

@test "F29: all cmd_* called in dispatcher are defined in lib/" {
  local failed=0
  while IFS= read -r fn; do
    [[ -z "$fn" ]] && continue
    if ! grep -qE "^${fn}\(\)" "$SCRIPTS_DIR/lib/"*.sh 2>/dev/null; then
      echo "MISSING: dispatcher calls $fn but no definition found in lib/" >&2
      failed=$((failed + 1))
    fi
  done < <(grep -oE 'cmd_[a-z_]+' "$SCRIPTS_DIR/plan-file.sh" | sort -u)
  [ "$failed" -eq 0 ]
}

@test "F29: dispatcher case block has no unknown-command entry that mentions cmd_" {
  # Verify the *)die catch-all doesn't accidentally call a cmd_ function
  run grep -E '^\s+\*\).*cmd_' "$SCRIPTS_DIR/plan-file.sh"
  [ "$status" -eq 1 ]
}

@test "F27: _record_blocked_runtime is defined and takes 4 params" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    declare -f _record_blocked_runtime
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"_record_blocked_runtime"* ]]
}

@test "F27: _require_phase is defined in plan-cmd.sh" {
  run grep -c '^_require_phase()' "$SCRIPTS_DIR/lib/plan-cmd.sh"
  [ "$status" -eq 0 ]
  [[ "$output" -ge 1 ]]
}

@test "F27: cmd_append_review_verdict is defined in plan-cmd.sh" {
  run grep -c '^cmd_append_review_verdict()' "$SCRIPTS_DIR/lib/plan-cmd.sh"
  [ "$status" -eq 0 ]
  [[ "$output" -ge 1 ]]
}

@test "F27: plan-cmd.sh has exactly one definition of cmd_append_review_verdict" {
  run grep -c '^cmd_append_review_verdict()' "$SCRIPTS_DIR/lib/plan-cmd.sh"
  [ "$status" -eq 0 ]
  [[ "$output" -eq 1 ]]
}
