#!/usr/bin/env bats
# Regression tests for G12 (Ring B AND model).

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

@test "G12: CLAUDE_PLAN_CAPABILITY=harness alone is blocked without PPID match" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    CLAUDE_PLAN_CAPABILITY=harness
    require_capability test_cmd B
  ' </dev/null 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires CLAUDE_PLAN_CAPABILITY=harness"* ]]
}

@test "G12: TTY shortcut removed from Ring B (F5 regression)" {
  # F5 removed [[ -t 0 ]] && return 0 shortcuts to prevent </dev/tty bypass.
  run grep -c '\-t 0.*&&.*return 0' "$SCRIPTS_DIR/capability.sh"
  # grep exits 1 when no matches found; status 1 means shortcut is correctly absent
  [ "$status" -eq 1 ]
}

@test "G12: Ring C still allows CLAUDE_PLAN_CAPABILITY=human from non-TTY" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    CLAUDE_PLAN_CAPABILITY=human
    require_capability test_cmd C && echo OK
  ' </dev/null 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

# ── T-6/H1: macOS ps args truncation rejection ───────────────────────────────

@test "T-6/H1: _check_parent_env fails closed when ps args >= 8190 bytes" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/capability.sh
    # Mock ps to return a string longer than 8190 bytes
    ps() {
      if [[ "$*" == *"-o args="* ]] && [[ "$*" != *"eww"* ]]; then
        python3 -c "print('"'"'A'"'"' * 8200, end='"'"''"'"')"
      else
        command ps "$@"
      fi
    }
    export -f ps
    CLAUDE_DEBUG_PPID=1 _check_parent_env $$ 2>&1
    echo "rc=$?"
  ' 2>&1
  # Must fail-closed (rc != 0) when ps args output is truncated
  [[ "$output" == *"rc=1"* || "$status" -ne 0 ]]
  [[ "$output" == *"truncated"* || "$output" == *"rc=1"* ]]
}

# ── Ring B gate: clear-converged / record-verdict / append-review-verdict ─────

@test "Ring-B: clear-converged is rejected without CLAUDE_PLAN_CAPABILITY=harness" {
  run bash -c '
    unset CLAUDE_PLAN_CAPABILITY
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    require_capability clear-converged B
    echo ALLOWED
  ' </dev/null 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" != *"ALLOWED"* ]]
}

@test "Ring-B: record-verdict is rejected without CLAUDE_PLAN_CAPABILITY=harness" {
  run bash -c '
    unset CLAUDE_PLAN_CAPABILITY
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    require_capability record-verdict B
    echo ALLOWED
  ' </dev/null 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" != *"ALLOWED"* ]]
}

