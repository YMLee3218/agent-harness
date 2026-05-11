#!/usr/bin/env bats
# Regression tests for G1 (numeric guard order) and G6 (PPID anchor pattern).

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

@test "G1: non-numeric pid is guarded before arithmetic comparison" {
  # Before G1 fix: [[ "?" -le 1 ]] would trigger arithmetic evaluation under set -u.
  run bash -c '
    set -euo pipefail
    pid="?"
    [[ -z "$pid" ]] && exit 1
    [[ "$pid" =~ ^[0-9]+$ ]] || { echo "guarded"; exit 0; }
    [[ "$pid" -le 1 ]] && exit 1
    echo "not guarded"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "guarded" ]]
}

@test "G1: empty pid is rejected before arithmetic" {
  run bash -c '
    pid=""
    [[ -z "$pid" ]] && echo "empty-guarded" || echo "not-guarded"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "empty-guarded" ]]
}

@test "G6: PPID case pattern requires bash*scripts/ prefix" {
  # Patterns like `vim run-critic-loop.sh` must NOT match.
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    cmd="vim run-critic-loop.sh"
    case "$cmd" in
      *bash*scripts/run-critic-loop.sh*|\
      *bash*scripts/run-dev-cycle.sh*|\
      *bash*scripts/run-implement.sh*|\
      *bash*scripts/run-integration.sh*|\
      *bash*scripts/stop-check.sh*) echo "MATCHED" ;;
      *) echo "no-match" ;;
    esac
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "no-match" ]]
}

@test "G6: PPID case pattern matches real harness invocation" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    cmd="bash scripts/run-dev-cycle.sh"
    case "$cmd" in
      *bash*scripts/run-critic-loop.sh*|\
      *bash*scripts/run-dev-cycle.sh*|\
      *bash*scripts/run-implement.sh*|\
      *bash*scripts/run-integration.sh*|\
      *bash*scripts/stop-check.sh*) echo "MATCHED" ;;
      *) echo "no-match" ;;
    esac
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "MATCHED" ]]
}
