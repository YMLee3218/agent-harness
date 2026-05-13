#!/usr/bin/env bats
# F27: cmd_record_verdict — core paths, PARSE_ERROR branches, exit codes.

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

setup() {
  setup_plan_dir
}

teardown() {
  teardown_plan_dir
}

@test "cmd_record_verdict treats missing verdict marker and FAIL-without-category both as PARSE_ERROR (exits 1)" {
  # Case 1: missing verdict marker
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-loop-helpers.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd.sh
    export CLAUDE_PLAN_FILE="'"$PLAN_FILE"'"
    export CLAUDE_PLAN_CAPABILITY=harness
    set +e
    printf '"'"'{"agent_type":"critic-code","last_assistant_message":"### Verdict\\nNo marker here."}'"'"' | cmd_record_verdict
    echo "rc=$?"
  ' 2>&1
  [[ "$output" == *"rc=1"* ]]
  # Case 2: FAIL without category
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-loop-helpers.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd.sh
    export CLAUDE_PLAN_FILE="'"$PLAN_FILE"'"
    export CLAUDE_PLAN_CAPABILITY=harness
    set +e
    printf '"'"'{"agent_type":"critic-code","last_assistant_message":"### Verdict\\n<!-- verdict: FAIL -->"}'"'"' | cmd_record_verdict
    echo "rc=$?"
  ' 2>&1
  [[ "$output" == *"rc=1"* ]]
}


@test "cmd_record_verdict treats unknown verdict token (e.g. FIAL) as PARSE_ERROR (exits 1)" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-loop-helpers.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd.sh
    export CLAUDE_PLAN_FILE="'"$PLAN_FILE"'"
    export CLAUDE_PLAN_CAPABILITY=harness
    set +e
    printf '"'"'{"agent_type":"critic-code","last_assistant_message":"### Verdict\\n<!-- verdict: FIAL -->"}'"'"' | cmd_record_verdict
    echo "rc=$?"
  ' 2>&1
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"unknown verdict token"* ]]
}

# ── T1: C1 regression — FAIL+category consecutive block ──────────────────────

@test "T1/C1: second FAIL same category triggers BLOCKED (jq filter works)" {
  # Pre-populate one FAIL with category=LAYER_VIOLATION for this milestone
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir/convergence"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '{"ts":"%s","phase":"implement","agent":"critic-code","verdict":"FAIL","category":"LAYER_VIOLATION","ordinal":1,"milestone_seq":0}\n' \
    "$ts" > "$state_dir/verdicts.jsonl"
  printf '{"phase":"implement","agent":"critic-code","first_turn":true,"streak":0,"converged":false,"ceiling_blocked":false,"ordinal":1,"milestone_seq":0}\n' \
    > "$state_dir/convergence/implement__critic-code.json"

  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-loop-helpers.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd.sh
    export CLAUDE_PLAN_FILE="'"$PLAN_FILE"'"
    export CLAUDE_PLAN_CAPABILITY=harness
    set +e
    printf '"'"'{"agent_type":"critic-code","last_assistant_message":"### Verdict\\n<!-- verdict: FAIL -->\\n<!-- category: LAYER_VIOLATION -->"}'"'"' \
      | cmd_record_verdict 2>&1
  ' 2>&1
  # T10b: Second FAIL same category → BLOCKED fires (exact match, not generic glob)
  [[ "$output" == *"consecutive same-category FAIL"* || "$output" == *"consecutive same-category"* ]]
  # No jq parse errors in output
  [[ "$output" != *"jq: error"* ]]
  [[ "$output" != *"parse error (null"* ]]
  # Plan file should have [BLOCKED] category marker
  grep -q '\[BLOCKED\]' "$PLAN_FILE"
}

# ── T4: L1 — first-FAIL non-blocking regression ───────────────────────────────

@test "T4/L1: first FAIL+category exits 1 but plan.md has no BLOCKED category marker" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-loop-helpers.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd.sh
    export CLAUDE_PLAN_FILE="'"$PLAN_FILE"'"
    export CLAUDE_PLAN_CAPABILITY=harness
    set +e
    printf '"'"'{"agent_type":"critic-code","last_assistant_message":"### Verdict\\n<!-- verdict: FAIL -->\\n<!-- category: SPEC_COMPLIANCE -->"}'"'"' \
      | cmd_record_verdict
    echo "rc=$?"
  ' 2>/dev/null
  [[ "$output" == *"rc=1"* ]]
  # T16: explicit negative assertion (not trivially true)
  run grep -q 'category.*SPEC_COMPLIANCE.*failed twice\|\[BLOCKED\].*category' "$PLAN_FILE"
  [ "$status" -ne 0 ]
}


