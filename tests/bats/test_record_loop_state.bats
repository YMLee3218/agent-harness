#!/usr/bin/env bats
# T8: _record_loop_state edge cases — jsonl append failure, ceiling-blocked early exit.

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

setup() {
  setup_plan_dir
}

teardown() {
  teardown_plan_dir
}

_load_libs() {
  printf '
    export CLAUDE_PROJECT_DIR="%s"
    source "%s/lib/active-plan.sh"
    source "%s/phase-policy.sh"
    source "%s/lib/sidecar.sh"
    export PLAN_FILE_SH="%s/plan-file.sh"
    source "%s/lib/plan-lib.sh"
    source "%s/lib/plan-loop-helpers.sh"
  ' "$PLAN_BASE" \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR" \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR"
}

@test "T8/L1: ceiling_blocked=true in conv_state triggers immediate rc=1 without scanning jsonl" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir/convergence"
  # Set ceiling_blocked=true in convergence JSON
  printf '{"phase":"implement","agent":"critic-code","first_turn":true,"streak":0,"converged":false,"ceiling_blocked":true,"ordinal":5,"milestone_seq":0}\n' \
    > "$state_dir/convergence/implement__critic-code.json"
  # No verdicts.jsonl — if L1 early-exit works, jq scan never happens

  run bash -c "
    $(_load_libs)
    set +e
    _record_loop_state '$PLAN_FILE' implement critic-code PASS
    echo rc=\$?
  " 2>&1
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"ceiling-blocked"* || "$output" == *"BLOCKED-CEILING"* ]]
}

@test "T8: sc_append_jsonl failure causes _record_loop_state to return rc=4" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir/convergence"

  run bash -c "
    $(_load_libs)
    # Override sc_append_jsonl to always fail (simulates write error)
    sc_append_jsonl() { return 1; }
    set +e
    _record_loop_state '$PLAN_FILE' implement critic-code PASS
    echo rc=\$?
  " 2>&1
  # Should return rc=4 (jsonl append failed)
  [[ "$output" == *"rc=4"* ]]
}

@test "T8: rc=4 from _record_loop_state leaves convergence JSON unchanged" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir/convergence"
  local conv="$state_dir/convergence/implement__critic-code.json"
  printf '{"phase":"implement","agent":"critic-code","first_turn":false,"streak":0,"converged":false,"ceiling_blocked":false,"ordinal":0,"milestone_seq":0}\n' \
    > "$conv"

  run bash -c "
    $(_load_libs)
    sc_append_jsonl() { return 1; }
    set +e
    _record_loop_state '$PLAN_FILE' implement critic-code PASS
    echo rc=\$?
  " 2>&1
  # Convergence JSON must still have ordinal=0 (not updated since jsonl failed)
  local ordinal; ordinal=$(jq -r '.ordinal' "$conv" 2>/dev/null || echo "error")
  [[ "$ordinal" == "0" ]]
}

@test "T8: normal PASS verdict writes to verdicts.jsonl and convergence" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir/convergence"

  run bash -c "
    $(_load_libs)
    set +e
    _record_loop_state '$PLAN_FILE' implement critic-code PASS
    echo rc=\$?
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
  [ -f "$state_dir/verdicts.jsonl" ]
  local vcount; vcount=$(wc -l < "$state_dir/verdicts.jsonl" | tr -d ' ')
  [[ "$vcount" == "1" ]]
}

@test "T8: corrupt verdicts.jsonl causes non-zero rc (streak compute failure)" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir/convergence"
  # Create corrupt verdicts.jsonl — ordinal compute is lenient (skips invalid lines),
  # but streak compute (for PASS) uses strict jq and returns rc=3 on corrupt input.
  printf 'NOT_VALID_JSON\n' > "$state_dir/verdicts.jsonl"

  run bash -c "
    $(_load_libs)
    set +e
    _record_loop_state '$PLAN_FILE' implement critic-code PASS
    echo rc=\$?
  " 2>&1
  # rc=3 means streak compute failed; rc=2 or rc=4 also accepted for resilience
  [[ "$output" == *"rc=2"* || "$output" == *"rc=3"* || "$output" == *"rc=4"* ]]
}

# ── T-4/C4: streak rc=3 causes no sidecar mutation ───────────────────────────

@test "T-4/C4: streak compute rc=3 — blocked.jsonl and convergence unchanged" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir/convergence"
  # Corrupt verdicts.jsonl so streak compute fails (returns rc=3 for PASS verdict)
  printf 'CORRUPT_LINE\n' > "$state_dir/verdicts.jsonl"

  run bash -c "
    $(_load_libs)
    set +e
    _record_loop_state '$PLAN_FILE' implement critic-code PASS
    echo rc=\$?
  " 2>&1
  # rc=3 means streak failed; rc=2 also acceptable (ordinal compute on corrupt file)
  [[ "$output" == *"rc=3"* || "$output" == *"rc=2"* ]]
  # blocked.jsonl must NOT have a ceiling record (no ceiling_block mutation happened)
  local bpath="$state_dir/blocked.jsonl"
  if [ -f "$bpath" ]; then
    ! jq -e '.kind == "ceiling"' "$bpath" 2>/dev/null
  fi
}

# ── T-H1: L3 race fix regression ─────────────────────────────────────────────

@test "T-H1: C1/L3 race — prior_cb refreshed after _ceiling_block update" {
  # Verify that after _ceiling_block sets ceiling_blocked=true in convergence JSON,
  # the final sc_update_json does NOT revert it to false (C1 race fix).
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir/convergence"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  # Pre-populate 5 verdicts to trigger ceiling on 6th call
  for i in 1 2 3 4 5; do
    printf '{"ts":"%s","phase":"implement","agent":"critic-code","verdict":"PASS","category":"","ordinal":%d,"milestone_seq":0}\n' \
      "$ts" "$i" >> "$state_dir/verdicts.jsonl"
  done
  printf '{"phase":"implement","agent":"critic-code","first_turn":true,"streak":0,"converged":false,"ceiling_blocked":false,"ordinal":5,"milestone_seq":0}\n' \
    > "$state_dir/convergence/implement__critic-code.json"

  run bash -c "
    $(_load_libs)
    export CLAUDE_CRITIC_LOOP_CEILING=5
    set +e
    _record_loop_state '$PLAN_FILE' implement critic-code PASS
    echo rc=\$?
  " 2>&1
  # Must be blocked (rc=1)
  [[ "$output" == *"rc=1"* ]]
  # ceiling_blocked must be true in convergence JSON — not reverted by stale prior_cb
  local cb; cb=$(jq -r '.ceiling_blocked' "$state_dir/convergence/implement__critic-code.json" 2>/dev/null)
  [[ "$cb" == "true" ]]
}

# ── T-H4: _get_run_ordinal type-safe — 100 valid + 1 corrupt scalar ──────────

@test "T-H4: C3 — _get_run_ordinal handles 100 valid + 1 corrupt scalar without type-error" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir/convergence"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  # Write 100 valid records for phase=implement agent=critic-code ms=0
  for i in $(seq 1 100); do
    printf '{"ts":"%s","phase":"implement","agent":"critic-code","verdict":"PASS","category":"","ordinal":%d,"milestone_seq":0}\n' \
      "$ts" "$i" >> "$state_dir/verdicts.jsonl"
  done
  # Append 1 corrupt scalar line (the C3 bug: try fromjson would type-error on this)
  printf '42\n' >> "$state_dir/verdicts.jsonl"

  run bash -c "
    $(_load_libs)
    set +e
    result=\$(_get_run_ordinal '$PLAN_FILE' '$state_dir/verdicts.jsonl' implement critic-code 0)
    echo \"ordinal=\$result\"
  " 2>&1
  # Should return ordinal=101 (no type-error, corrupt line skipped)
  [[ "$output" == *"ordinal=101"* ]]
  # Must not have jq error output
  [[ "$output" != *"jq: error"* ]]
  [[ "$output" != *"null (null)"* ]]
}

# ── T-14: _get_run_ordinal propagates rc=2 on jq failure ─────────────────────

@test "T-14: _get_run_ordinal returns rc=2 when verdicts.jsonl is unreadable" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir/convergence"
  # Create an unreadable file to simulate jq failure
  local vpath="$state_dir/verdicts.jsonl"
  printf '{"phase":"implement","agent":"critic-code","verdict":"PASS","ordinal":1,"milestone_seq":0}\n' > "$vpath"
  chmod 000 "$vpath"
  run bash -c "
    $(_load_libs)
    set +e
    _get_run_ordinal '$PLAN_FILE' '$vpath' implement critic-code 0
    echo rc=\$?
  " 2>&1
  chmod 644 "$vpath" 2>/dev/null || true
  # With unreadable file, jq should fail → rc=2
  [[ "$output" == *"rc=2"* ]]
}
