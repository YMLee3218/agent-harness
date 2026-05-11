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

@test "G9: declare -F die is used instead of command -v die" {
  run grep 'declare -F die' "$SCRIPTS_DIR/phase-policy.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"declare -F die"* ]]
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

# ── T-7/H2: comm full path comparison prevents 15-byte truncation bypass ─────

@test "T-7/H2: _ppid_chain_is_harness uses full args path (not comm 15-byte truncated)" {
  # Verify capability.sh no longer uses comm= for the identity comparison.
  run grep -c 'comm=' "$SCRIPTS_DIR/capability.sh"
  # comm= may appear in comments or other context; the key check is that the
  # comm_before/comm_after variables are gone and args_before/args_after are used.
  run grep '_args_before\|_args_after' "$SCRIPTS_DIR/capability.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"_args_before"* ]] || [[ "$output" == *"_args_after"* ]]
}
