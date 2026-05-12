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

@test "cmd_record_verdict exits 0 for non-critic agent (skipped gracefully)" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-loop-helpers.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd.sh
    export CLAUDE_PLAN_FILE="'"$PLAN_FILE"'"
    printf '"'"'{"agent_type":"general-purpose","last_assistant_message":""}'"'"' | cmd_record_verdict
    echo "rc=$?"
  ' 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
}

@test "cmd_record_verdict records PASS verdict in ## Critic Verdicts" {
  bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-loop-helpers.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd.sh
    export CLAUDE_PLAN_FILE="'"$PLAN_FILE"'"
    export CLAUDE_PLAN_CAPABILITY=harness
    printf '"'"'{"agent_type":"critic-code","last_assistant_message":"### Verdict\\n<!-- verdict: PASS -->"}'"'"' | cmd_record_verdict
  ' 2>/dev/null || true
  grep -q 'PASS' "$PLAN_FILE"
}

@test "cmd_record_verdict treats missing verdict marker as PARSE_ERROR (exits 1)" {
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
}

@test "cmd_record_verdict treats FAIL without category as PARSE_ERROR (exits 1)" {
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

@test "cmd_record_verdict exits 0 when no active plan found" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-loop-helpers.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd.sh
    unset CLAUDE_PLAN_FILE
    set +e
    printf '"'"'{"agent_type":"critic-code","last_assistant_message":""}'"'"' | cmd_record_verdict
    echo "rc=$?"
  ' 2>&1
  [[ "$output" == *"rc=0"* ]]
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
    printf '"'"'{"agent_type":"critic-code","last_assistant_message":"### Verdict\\n<!-- verdict: FAIL -->\\n<!-- category: MISSING_TEST -->"}'"'"' \
      | cmd_record_verdict
    echo "rc=$?"
  ' 2>/dev/null
  [[ "$output" == *"rc=1"* ]]
  # T16: explicit negative assertion (not trivially true)
  run grep -q 'category.*MISSING_TEST.*failed twice\|\[BLOCKED\].*category' "$PLAN_FILE"
  [ "$status" -ne 0 ]
}

# ── T9/L4: PARSE_ERROR ceiling rc=1 gets [BLOCKED-CEILING] prefix ─────────────

@test "T9/L4: parse-error at ceiling gets [BLOCKED-CEILING] prefix in plan.md verdict" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir/convergence"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  # 5 parse errors to hit ceiling=5
  for i in 1 2 3 4 5; do
    printf '{"ts":"%s","phase":"implement","agent":"critic-code","verdict":"PARSE_ERROR","category":"","ordinal":%d,"milestone_seq":0}\n' \
      "$ts" "$i" >> "$state_dir/verdicts.jsonl"
  done
  printf '{"phase":"implement","agent":"critic-code","first_turn":false,"streak":0,"converged":false,"ceiling_blocked":false,"ordinal":5,"milestone_seq":0}\n' \
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
    export CLAUDE_CRITIC_LOOP_CEILING=5
    set +e
    printf '"'"'{"agent_type":"critic-code","last_assistant_message":"### Verdict\\nNo marker here."}'"'"' \
      | cmd_record_verdict 2>&1
    echo "rc=$?"
  ' 2>&1
  [[ "$output" == *"rc=1"* ]]
  # T9: verdict label must contain [BLOCKED-CEILING] prefix
  grep -q '\[BLOCKED-CEILING\]' "$PLAN_FILE"
}

