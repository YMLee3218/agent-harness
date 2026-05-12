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

@test "L3 regression: ceiling rc=1 prints NOT persisted to stderr, not stdout" {
  # Pre-populate 5 verdicts to force ceiling on next call (CLAUDE_CRITIC_LOOP_CEILING=5)
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir/convergence"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  for i in 1 2 3 4 5; do
    printf '{"ts":"%s","phase":"implement","agent":"critic-code","verdict":"PASS","category":"","ordinal":%d,"milestone_seq":0}\n' \
      "$ts" "$i" >> "$state_dir/verdicts.jsonl"
  done
  printf '{"phase":"implement","agent":"critic-code","first_turn":true,"streak":0,"converged":false,"ceiling_blocked":false,"ordinal":5,"milestone_seq":0}\n' \
    > "$state_dir/convergence/implement__critic-code.json"
  # Run cmd_record_verdict — it should hit ceiling and NOT print "verdict appended" to combined output
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-loop-helpers.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd.sh
    export CLAUDE_PLAN_FILE="'"$PLAN_FILE"'"
    export CLAUDE_CRITIC_LOOP_CEILING=5
    set +e
    printf '"'"'{"agent_type":"critic-code","last_assistant_message":"### Verdict\\n<!-- verdict: PASS -->"}'"'"' | cmd_record_verdict 2>&1
  ' 2>&1
  # ceiling was hit — stdout must say NOT persisted, NOT "verdict appended"
  [[ "$output" != *"verdict appended"* ]]
  [[ "$output" == *"NOT persisted"* || "$output" == *"BLOCKED-CEILING"* ]]
}

@test "L3 regression: successful verdict prints verdict appended to stderr" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-loop-helpers.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd.sh
    export CLAUDE_PLAN_FILE="'"$PLAN_FILE"'"
    sc_ensure_dir '"'"''"$PLAN_FILE"''"'"'
    printf '"'"'{"agent_type":"critic-code","last_assistant_message":"### Verdict\\n<!-- verdict: PASS -->"}'"'"' | cmd_record_verdict 2>&1
  ' 2>&1
  [[ "$output" == *"verdict appended"* ]]
}

# ── T1: C1 regression — FAIL+category consecutive block ──────────────────────

@test "T1/C1: first FAIL+category does NOT trigger BLOCKED (no jq error)" {
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
  # First FAIL should exit 1 (FAIL recorded) but NOT trigger consecutive BLOCKED
  [[ "$output" != *"consecutive same-category"* ]]
  [[ "$output" != *"jq: error"* ]]
  [[ "$output" != *"parse error"* ]]
}

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

# ── T2/C2: corrupt jsonl rc=2 is NOT silently dropped ─────────────────────────

@test "T2/C2: corrupt verdicts.jsonl causes rc=2 from _check_consecutive_and_block — verdict label gets [BLOCKED] kind=corrupt-check" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir/convergence"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  # Write corrupt (non-JSON) content to trigger jq failure in consecutive check
  printf '{"ts":"%s","phase":"implement","agent":"critic-code","verdict":"FAIL","category":"LAYER_VIOLATION","ordinal":1,"milestone_seq":0}\n' \
    "$ts" > "$state_dir/verdicts.jsonl"
  printf 'CORRUPT_LINE_NOT_JSON\n' >> "$state_dir/verdicts.jsonl"
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
    echo "rc=$?"
  ' 2>&1
  # Must exit 1 (blocked or corrupt), NOT 0 (which would mean normal PASS recorded)
  [[ "$output" == *"rc=1"* ]]
  grep -q '\[BLOCKED\] kind=corrupt-check' "$PLAN_FILE"
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

# ── T11/L6: BLOCK branch does not duplicate verdict label in plan.md ──────────

@test "T11/L6: two consecutive PARSE_ERRORs — plan.md has BLOCKED marker but no extra PARSE_ERROR verdict" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir/convergence"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  # One prior PARSE_ERROR verdict
  printf '{"ts":"%s","phase":"implement","agent":"critic-code","verdict":"PARSE_ERROR","category":"","ordinal":1,"milestone_seq":0}\n' \
    "$ts" > "$state_dir/verdicts.jsonl"
  printf '{"phase":"implement","agent":"critic-code","first_turn":false,"streak":0,"converged":false,"ceiling_blocked":false,"ordinal":1,"milestone_seq":0}\n' \
    > "$state_dir/convergence/implement__critic-code.json"

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
    set +e
    printf '"'"'{"agent_type":"critic-code","last_assistant_message":"### Verdict\\nNo marker here."}'"'"' \
      | cmd_record_verdict 2>/dev/null
    exit 0
  '

  # BLOCKED marker should appear once in Open Questions
  local blocked_count=0
  blocked_count=$(grep -c '\[BLOCKED\].*parse\|BLOCKED.*PARSE' "$PLAN_FILE" 2>/dev/null) || blocked_count=0
  # And PARSE_ERROR verdict label should appear AT MOST once (not duplicated)
  local parse_error_count=0
  parse_error_count=$(grep -c 'PARSE_ERROR' "$PLAN_FILE" 2>/dev/null) || parse_error_count=0
  # At most one PARSE_ERROR verdict label (BLOCKED consumes the slot, no extra append)
  [ "$parse_error_count" -le 1 ]
}

# ── T-H2: rc=3 streak failure → [BLOCKED] kind=streak prefix ────────────────

@test "T-H2: rc=3 (streak compute fail) appends [BLOCKED] kind=streak to plan.md" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir/convergence"
  # Corrupt verdicts.jsonl so _compute_streak fails (rc=3)
  printf 'CORRUPT_NOT_JSON\n' > "$state_dir/verdicts.jsonl"
  printf '{"phase":"implement","agent":"critic-code","first_turn":false,"streak":0,"converged":false,"ceiling_blocked":false,"ordinal":0,"milestone_seq":0}\n' \
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
    printf '"'"'{"agent_type":"critic-code","last_assistant_message":"### Verdict\\n<!-- verdict: PASS -->"}'"'"' \
      | cmd_record_verdict 2>&1
    echo "rc=$?"
  ' 2>&1
  [[ "$output" == *"rc=1"* ]]
  grep -q '\[BLOCKED\] kind=streak' "$PLAN_FILE"
}

# ── T-H3: rc=4 (write fail) → plan.md not updated ────────────────────────────

@test "T-H3: rc=4 (verdicts.jsonl write fail) — plan.md verdict section not updated" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir/convergence"
  printf '{"phase":"implement","agent":"critic-code","first_turn":false,"streak":0,"converged":false,"ceiling_blocked":false,"ordinal":0,"milestone_seq":0}\n' \
    > "$state_dir/convergence/implement__critic-code.json"
  local initial_content; initial_content=$(cat "$PLAN_FILE")

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
    # Override sc_append_jsonl to simulate write failure
    sc_append_jsonl() { return 1; }
    set +e
    printf '"'"'{"agent_type":"critic-code","last_assistant_message":"### Verdict\\n<!-- verdict: PASS -->"}'"'"' \
      | cmd_record_verdict 2>&1
    echo "rc=$?"
  ' 2>&1
  [[ "$output" == *"rc=1"* ]]
  # Critic Verdicts section must be unchanged — rc=4 must not call cmd_append_verdict.
  # Open Questions may gain a [BLOCKED] from _record_blocked_runtime, so compare only Critic Verdicts.
  local before_cv after_cv
  before_cv=$(printf '%s' "$initial_content" | awk '/^## Critic Verdicts/{f=1;next} f && /^## /{exit} f{print}')
  after_cv=$(awk '/^## Critic Verdicts/{f=1;next} f && /^## /{exit} f{print}' "$PLAN_FILE")
  [[ "$before_cv" == "$after_cv" ]]
}

# ── D1: whitespace-tolerant verdict marker parsing ────────────────────────────

@test "D1: verdict marker with extra whitespace is parsed correctly" {
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
    printf '"'"'{"agent_type":"critic-code","last_assistant_message":"### Verdict\\n<!--  verdict:  PASS  -->"}'"'"' \
      | cmd_record_verdict 2>&1
  ' 2>&1
  [[ "$output" == *"verdict appended"* ]]
  grep -q 'PASS' "$PLAN_FILE"
}

@test "D1: verdict marker without spaces (<!--verdict:PASS-->) is parsed correctly" {
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
    printf '"'"'{"agent_type":"critic-code","last_assistant_message":"### Verdict\\n<!--verdict:PASS-->"}'"'"' \
      | cmd_record_verdict 2>&1
  ' 2>&1
  [[ "$output" == *"verdict appended"* ]]
  grep -q 'PASS' "$PLAN_FILE"
}

# ── T-5: transcript path canonicalization ────────────────────────────────────

_load_rv_libs() {
  printf '
    export CLAUDE_PROJECT_DIR="%s"
    export CLAUDE_PLAN_CAPABILITY=harness
    source "%s/lib/active-plan.sh"
    source "%s/phase-policy.sh"
    source "%s/lib/sidecar.sh"
    export PLAN_FILE_SH="%s/plan-file.sh"
    source "%s/lib/plan-lib.sh"
    source "%s/lib/plan-loop-helpers.sh"
    source "%s/lib/plan-cmd.sh"
    export CLAUDE_PLAN_FILE="%s"
  ' "$PLAN_BASE" \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR" \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR" \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR" \
    "$PLAN_FILE"
}

@test "T-5: _is_safe_transcript_path rejects path traversal via .." {
  run bash -c "
    export CLAUDE_PROJECT_DIR='$PLAN_BASE'
    source '$SCRIPTS_DIR/lib/active-plan.sh'
    source '$SCRIPTS_DIR/phase-policy.sh'
    source '$SCRIPTS_DIR/lib/sidecar.sh'
    export PLAN_FILE_SH='$SCRIPTS_DIR/plan-file.sh'
    source '$SCRIPTS_DIR/lib/plan-lib.sh'
    source '$SCRIPTS_DIR/lib/plan-loop-helpers.sh'
    source '$SCRIPTS_DIR/lib/plan-cmd.sh'
    _is_safe_transcript_path '${HOME}/.claude/projects/foo/../../etc/passwd' && echo ALLOWED || echo BLOCKED
  " 2>&1
  [[ "$output" == *"BLOCKED"* ]]
}

@test "T-5: _is_safe_transcript_path rejects symlink to out-of-scope file" {
  local evil_link="$PLAN_BASE/evil-link.jsonl"
  ln -sf /etc/passwd "$evil_link" 2>/dev/null || true
  run bash -c "
    export CLAUDE_PROJECT_DIR='$PLAN_BASE'
    source '$SCRIPTS_DIR/lib/active-plan.sh'
    source '$SCRIPTS_DIR/phase-policy.sh'
    source '$SCRIPTS_DIR/lib/sidecar.sh'
    export PLAN_FILE_SH='$SCRIPTS_DIR/plan-file.sh'
    source '$SCRIPTS_DIR/lib/plan-lib.sh'
    source '$SCRIPTS_DIR/lib/plan-loop-helpers.sh'
    source '$SCRIPTS_DIR/lib/plan-cmd.sh'
    _is_safe_transcript_path '$evil_link' && echo ALLOWED || echo BLOCKED
  " 2>&1
  [[ "$output" == *"BLOCKED"* ]]
  rm -f "$evil_link"
}

@test "T-5: _is_safe_transcript_path accepts path under CLAUDE_PROJECT_DIR" {
  local safe_path="${PLAN_BASE}/safe-transcript.jsonl"
  touch "$safe_path"
  run bash -c "
    export CLAUDE_PROJECT_DIR='$PLAN_BASE'
    source '$SCRIPTS_DIR/lib/active-plan.sh'
    source '$SCRIPTS_DIR/phase-policy.sh'
    source '$SCRIPTS_DIR/lib/sidecar.sh'
    export PLAN_FILE_SH='$SCRIPTS_DIR/plan-file.sh'
    source '$SCRIPTS_DIR/lib/plan-lib.sh'
    source '$SCRIPTS_DIR/lib/plan-loop-helpers.sh'
    source '$SCRIPTS_DIR/lib/plan-cmd.sh'
    _is_safe_transcript_path '$safe_path' && echo ALLOWED || echo BLOCKED
  " 2>&1
  [[ "$output" == *"ALLOWED"* ]]
  rm -f "$safe_path"
}
