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
    printf '"'"'{"agent_type":"critic-code","last_assistant_message":"[CRITICAL] boundary broken\\n### Verdict\\n<!-- verdict: FAIL -->\\n<!-- category: LAYER_VIOLATION -->"}'"'"' \
      | cmd_record_verdict 2>&1
  ' 2>&1
  # T10b: Second FAIL same category → BLOCKED fires (exact match, not generic glob)
  [[ "$output" == *"consecutive same-category FAIL"* || "$output" == *"consecutive same-category"* ]]
  # No jq parse errors in output
  [[ "$output" != *"jq: error"* ]]
  [[ "$output" != *"parse error (null"* ]]
  # Plan file should have [BLOCKED:code] category marker
  grep -q '\[BLOCKED:code\]' "$PLAN_FILE"
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
    printf '"'"'{"agent_type":"critic-code","last_assistant_message":"[CRITICAL] spec violation\\n### Verdict\\n<!-- verdict: FAIL -->\\n<!-- category: SPEC_COMPLIANCE -->"}'"'"' \
      | cmd_record_verdict
    echo "rc=$?"
  ' 2>/dev/null
  [[ "$output" == *"rc=1"* ]]
  # T16: explicit negative assertion (not trivially true)
  run grep -q 'category.*SPEC_COMPLIANCE.*failed twice\|\[BLOCKED:code\].*category' "$PLAN_FILE"
  [ "$status" -ne 0 ]
}

# ── T2: C1 fix — FAIL+PASS+FAIL does NOT block (PASS resets consecutiveness) ──

@test "T2/C1: FAIL then PASS then same-category FAIL does not trigger BLOCKED" {
  # Pre-populate verdicts.jsonl: FAIL(LAYER_VIOLATION) then PASS — simulates a temporary fix
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir/convergence"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '{"ts":"%s","phase":"implement","agent":"critic-code","verdict":"FAIL","category":"LAYER_VIOLATION","ordinal":1,"milestone_seq":0}\n' \
    "$ts" > "$state_dir/verdicts.jsonl"
  printf '{"ts":"%s","phase":"implement","agent":"critic-code","verdict":"PASS","category":"NONE","ordinal":2,"milestone_seq":0}\n' \
    "$ts" >> "$state_dir/verdicts.jsonl"
  # Convergence sidecar reflects state after PASS (streak=1, not converged yet)
  printf '{"phase":"implement","agent":"critic-code","first_turn":false,"streak":1,"converged":false,"ceiling_blocked":false,"ordinal":2,"milestone_seq":0}\n' \
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
    printf '"'"'{"agent_type":"critic-code","last_assistant_message":"[CRITICAL] boundary broken\\n### Verdict\\n<!-- verdict: FAIL -->\\n<!-- category: LAYER_VIOLATION -->"}'"'"' \
      | cmd_record_verdict 2>&1
    echo "rc=$?"
  ' 2>&1
  # FAIL exits 1 (correct — it is a failure)
  [[ "$output" == *"rc=1"* ]]
  # But the intervening PASS must prevent the ceiling block
  [[ "$output" != *"consecutive same-category FAIL"* ]]
  # No [BLOCKED:code] category marker in plan file
  run grep -q '\[BLOCKED:code\]' "$PLAN_FILE"
  [ "$status" -ne 0 ]
}

# ── T3: C1 fix — FAIL+PARSE_ERROR+FAIL DOES block (PARSE_ERROR transparent) ──

@test "T3/C1: FAIL then PARSE_ERROR then same-category FAIL triggers BLOCKED" {
  # Pre-populate verdicts.jsonl: FAIL(LAYER_VIOLATION) then PARSE_ERROR — PARSE_ERROR must be transparent
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir/convergence"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '{"ts":"%s","phase":"implement","agent":"critic-code","verdict":"FAIL","category":"LAYER_VIOLATION","ordinal":1,"milestone_seq":0}\n' \
    "$ts" > "$state_dir/verdicts.jsonl"
  printf '{"ts":"%s","phase":"implement","agent":"critic-code","verdict":"PARSE_ERROR","category":"","ordinal":2,"milestone_seq":0}\n' \
    "$ts" >> "$state_dir/verdicts.jsonl"
  printf '{"phase":"implement","agent":"critic-code","first_turn":true,"streak":0,"converged":false,"ceiling_blocked":false,"ordinal":2,"milestone_seq":0}\n' \
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
    printf '"'"'{"agent_type":"critic-code","last_assistant_message":"[CRITICAL] boundary broken\\n### Verdict\\n<!-- verdict: FAIL -->\\n<!-- category: LAYER_VIOLATION -->"}'"'"' \
      | cmd_record_verdict 2>&1
  ' 2>&1
  # PARSE_ERROR between two same-category FAILs is transparent — must still block
  [[ "$output" == *"consecutive same-category FAIL"* || "$output" == *"consecutive same-category"* ]]
  [[ "$output" != *"jq: error"* ]]
  grep -q '\[BLOCKED:code\]' "$PLAN_FILE"
}

# ── New guards: invalid category, FAIL-without-blocking-finding ───────────────

@test "G1: FAIL with invalid category (COMPLETENESS not in enum) → PARSE_ERROR rc=1 with 'invalid category'" {
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
    printf '"'"'{"agent_type":"critic-spec","last_assistant_message":"[CRITICAL] bad thing\\n### Verdict\\n<!-- verdict: FAIL -->\\n<!-- category: COMPLETENESS -->"}'"'"' \
      | cmd_record_verdict 2>&1
    echo "rc=$?"
  ' 2>&1
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"invalid category"* ]]
}

@test "G2: FAIL with no recognizable blocking label and valid category → PARSE_ERROR rc=1 with 'blocking finding'" {
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
    printf '"'"'{"agent_type":"critic-spec","last_assistant_message":"- some finding with no recognized label\\n### Verdict\\n<!-- verdict: FAIL -->\\n<!-- category: STRUCTURAL -->"}'"'"' \
      | cmd_record_verdict 2>&1
    echo "rc=$?"
  ' 2>&1
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"blocking finding"* ]]
}

@test "G3: regression — FAIL with [CRITICAL] finding and valid category is NOT treated as PARSE_ERROR" {
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
    printf '"'"'{"agent_type":"critic-code","last_assistant_message":"- [CRITICAL] layer boundary broken\\n### Verdict\\n<!-- verdict: FAIL -->\\n<!-- category: LAYER_VIOLATION -->"}'"'"' \
      | cmd_record_verdict 2>&1
    echo "rc=$?"
  ' 2>&1
  # Normal FAIL (rc=1) — NOT a PARSE_ERROR
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" != *"PARSE_ERROR"* || "$output" == *"verdict appended"* ]]
  # Plan file must have the FAIL verdict recorded (no invalid-category block)
  grep -q 'critic-code: FAIL' "$PLAN_FILE"
}


@test "G6: PASS with non-NONE category (CORRECTNESS) → PARSE_ERROR rc=1 with 'non-NONE category'" {
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
    printf '"'"'{"agent_type":"critic-code","last_assistant_message":"### Verdict\\n<!-- verdict: PASS -->\\n<!-- category: CORRECTNESS -->"}'"'"' \
      | cmd_record_verdict 2>&1
    echo "rc=$?"
  ' 2>&1
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"non-NONE category"* ]]
}

@test "G7: PASS with category NONE → rc=0 (regression guard)" {
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
    printf '"'"'{"agent_type":"critic-code","last_assistant_message":"### Verdict\\n<!-- verdict: PASS -->\\n<!-- category: NONE -->"}'"'"' \
      | cmd_record_verdict 2>&1
    echo "rc=$?"
  ' 2>&1
  [[ "$output" == *"rc=0"* ]]
}

@test "G8: PASS with no category marker → rc=0 (regression guard)" {
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
    printf '"'"'{"agent_type":"critic-code","last_assistant_message":"### Verdict\\n<!-- verdict: PASS -->"}'"'"' \
      | cmd_record_verdict 2>&1
    echo "rc=$?"
  ' 2>&1
  [[ "$output" == *"rc=0"* ]]
}

@test "G5: _severity_categories returns 11 values; _severity_blocking_labels returns 6 values" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-loop-helpers.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd.sh
    cats=$(_severity_categories)
    cat_count=$(echo "$cats" | tr " " "\n" | grep -c "." 2>/dev/null || echo 0)
    echo "cat_count=$cat_count"
    block_count=$(_severity_blocking_labels | grep -c "." 2>/dev/null || echo 0)
    echo "block_count=$block_count"
  ' 2>&1
  [[ "$output" == *"cat_count=11"* ]]
  [[ "$output" == *"block_count=6"* ]]
}

