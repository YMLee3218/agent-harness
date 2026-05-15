#!/usr/bin/env bats
# Tests for the transient auto-handling mechanism (_record_transient, _clear_transient_for,
# _reset_all_transient_counters) implemented in scripts/lib/sidecar.sh.

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

setup() {
  setup_plan_dir
}

teardown() {
  teardown_plan_dir
}

# Helper: run _record_transient K-1 times and assert plan.md is unchanged.
_libs() {
  printf '
    source "%s/lib/active-plan.sh"
    source "%s/phase-policy.sh"
    source "%s/lib/sidecar.sh"
    export PLAN_FILE_SH="%s/plan-file.sh"
    source "%s/lib/plan-lib.sh"
    source "%s/lib/plan-loop-helpers.sh"
    source "%s/lib/plan-cmd.sh"
    export CLAUDE_PLAN_CAPABILITY=harness
    export CLAUDE_PLAN_FILE="%s"
    export CLAUDE_PROJECT_DIR="%s"
  ' "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR" \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR" \
    "$PLAN_FILE" "$PLAN_BASE"
}

@test "transient: K-1 occurrences do not write to plan.md; counter accumulates" {
  # Default threshold K=3 → 2 calls should not promote
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir"

  for i in 1 2; do
    run bash -c "
      $(_libs)
      _record_transient '$PLAN_FILE' 'critic-code' 'session-timeout' 'after 3600s' '$SCRIPTS_DIR/plan-file.sh'
    " 2>&1
    # _record_transient returns 1 (no promotion) for K-1 calls
    [ "$status" -ne 0 ] || [ "$i" -eq 1 ]  # allow 0 or 1 from first call
  done

  # plan.md must have NO [BLOCKED:env] from transient promotion
  ! grep -qF '[BLOCKED:env]' "$PLAN_FILE"
  # transient_counters.json must exist with counter == 2
  local cpath="$state_dir/transient_counters.json"
  [ -f "$cpath" ]
  local count; count=$(jq -r '."critic-code__session-timeout" // 0' "$cpath")
  [ "$count" -eq 2 ]
}

@test "transient: K-th occurrence promotes to [BLOCKED:env] and resets counter" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir"
  # Pre-seed counter at K-1=2
  printf '{"critic-code__session-timeout":2}\n' > "$state_dir/transient_counters.json"

  run bash -c "
    $(_libs)
    _record_transient '$PLAN_FILE' 'critic-code' 'session-timeout' 'after 3600s' '$SCRIPTS_DIR/plan-file.sh'
  " 2>&1
  # Promotion writes [BLOCKED:env] to plan.md
  grep -qF '[BLOCKED:env] critic-code: session-timeout' "$PLAN_FILE"

  # Counter must be reset (key removed or 0)
  local cpath="$state_dir/transient_counters.json"
  local count; count=$(jq -r '."critic-code__session-timeout" // 0' "$cpath" 2>/dev/null || echo 0)
  [ "$count" -eq 0 ]
}

@test "transient: K-th occurrence appends [BLOCKED:env] record to blocked.jsonl" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir"
  printf '{"critic-code__loop-lock":2}\n' > "$state_dir/transient_counters.json"

  bash -c "
    $(_libs)
    _record_transient '$PLAN_FILE' 'critic-code' 'loop-lock' 'already running' '$SCRIPTS_DIR/plan-file.sh'
  " 2>/dev/null || true

  local bpath="$state_dir/blocked.jsonl"
  [ -f "$bpath" ]
  # env record is written by append-note → _record_blocked (no sub_kind field — check by kind+agent)
  local env_record; env_record=$(jq -r 'select(.kind == "env" and .agent == "critic-code") | .agent' "$bpath" 2>/dev/null || true)
  [ "$env_record" = "critic-code" ]
}

@test "transient: blocked.jsonl transient records have cleared_at=null (own lifecycle)" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir"

  bash -c "
    $(_libs)
    _record_transient '$PLAN_FILE' 'critic-code' 'session-timeout' 'after 3600s' '$SCRIPTS_DIR/plan-file.sh'
  " 2>/dev/null || true

  local bpath="$state_dir/blocked.jsonl"
  [ -f "$bpath" ]
  local cleared; cleared=$(jq -r 'select(.kind == "transient") | .cleared_at' "$bpath" 2>/dev/null || true)
  # cleared_at must be "null" (JSON null), not a timestamp
  [ "$cleared" = "null" ]
}

@test "transient: CLAUDE_TRANSIENT_THRESHOLD env var controls promotion threshold" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir"
  # K=5 → 4 calls should not promote
  printf '{"critic-code__session-timeout":4}\n' > "$state_dir/transient_counters.json"

  # With threshold=5, 5th call promotes
  run bash -c "
    $(_libs)
    CLAUDE_TRANSIENT_THRESHOLD=5 _record_transient '$PLAN_FILE' 'critic-code' 'session-timeout' 'after 3600s' '$SCRIPTS_DIR/plan-file.sh'
  " 2>&1
  grep -qF '[BLOCKED:env] critic-code: session-timeout' "$PLAN_FILE"
  local cpath="$state_dir/transient_counters.json"
  local count; count=$(jq -r '."critic-code__session-timeout" // 0' "$cpath" 2>/dev/null || echo 0)
  [ "$count" -eq 0 ]
}

@test "transient: _clear_transient_for resets only the specified agent's counters" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir"
  printf '{"critic-code__session-timeout":2,"critic-spec__loop-lock":1}\n' > "$state_dir/transient_counters.json"

  bash -c "
    $(_libs)
    _clear_transient_for '$PLAN_FILE' 'critic-code'
  " 2>/dev/null

  local cpath="$state_dir/transient_counters.json"
  # critic-code entries gone
  local cc; cc=$(jq -r '."critic-code__session-timeout" // "absent"' "$cpath" 2>/dev/null || echo absent)
  [ "$cc" = "absent" ] || [ "$cc" = "0" ] || [ "$cc" = "null" ]
  # critic-spec entry preserved
  local cs; cs=$(jq -r '."critic-spec__loop-lock" // 0' "$cpath" 2>/dev/null || echo 0)
  [ "$cs" -eq 1 ]
}

@test "transient: _reset_all_transient_counters clears everything" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir"
  printf '{"critic-code__session-timeout":2,"critic-spec__loop-lock":1}\n' > "$state_dir/transient_counters.json"

  bash -c "
    $(_libs)
    _reset_all_transient_counters '$PLAN_FILE'
  " 2>/dev/null

  local cpath="$state_dir/transient_counters.json"
  [ -f "$cpath" ]
  local content; content=$(cat "$cpath")
  [ "$content" = "{}" ]
}

@test "transient: reset-milestone resets all transient counters" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir/convergence"
  printf '{"critic-code__session-timeout":2}\n' > "$state_dir/transient_counters.json"
  # Write a milestone boundary sentinel first so reset-milestone has something to clear
  printf '{"phase":"implement","agent":"critic-code","first_turn":false,"streak":0,"converged":false,"ceiling_blocked":false,"ordinal":1,"milestone_seq":0}\n' \
    > "$state_dir/convergence/implement__critic-code.json"

  bash -c "
    $(_libs)
    cmd_reset_milestone '$PLAN_FILE' 'critic-code'
  " 2>/dev/null || true

  local cpath="$state_dir/transient_counters.json"
  [ -f "$cpath" ]
  local count; count=$(jq -r '."critic-code__session-timeout" // 0' "$cpath" 2>/dev/null || echo 0)
  [ "$count" -eq 0 ]
}

@test "transient: reset-milestone clears only target agent's counters (B4 regression)" {
  # B4: cmd_reset_milestone must call _clear_transient_for (per-agent), not _reset_all_transient_counters.
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir/convergence"
  printf '{"critic-code__session-timeout":2,"critic-spec__loop-lock":1}\n' \
    > "$state_dir/transient_counters.json"
  printf '{"phase":"implement","agent":"critic-code","first_turn":false,"streak":0,"converged":false,"ceiling_blocked":false,"ordinal":1,"milestone_seq":0}\n' \
    > "$state_dir/convergence/implement__critic-code.json"

  bash -c "
    $(_libs)
    cmd_reset_milestone '$PLAN_FILE' 'critic-code'
  " 2>/dev/null || true

  local cpath="$state_dir/transient_counters.json"
  [ -f "$cpath" ]
  # critic-code counter must be cleared
  local cc; cc=$(jq -r '."critic-code__session-timeout" // 0' "$cpath" 2>/dev/null || echo 0)
  [ "$cc" -eq 0 ]
  # critic-spec counter must be preserved
  local cs; cs=$(jq -r '."critic-spec__loop-lock" // 0' "$cpath" 2>/dev/null || echo 0)
  [ "$cs" -eq 1 ]
}

@test "transient: unknown sub-kind is rejected" {
  run bash -c "
    $(_libs)
    _record_transient '$PLAN_FILE' 'critic-code' 'not-a-valid-sub-kind' 'detail' '$SCRIPTS_DIR/plan-file.sh'
  " 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown sub-kind"* ]]
  ! grep -qF '[BLOCKED' "$PLAN_FILE"
}

@test "transient: loop-lock is a valid sub-kind" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir"

  run bash -c "
    $(_libs)
    _record_transient '$PLAN_FILE' 'critic-spec' 'loop-lock' 'already running' '$SCRIPTS_DIR/plan-file.sh'
  " 2>&1
  # Should return 1 (no promotion at count=1), but NOT unknown-sub-kind error
  [[ "$output" != *"unknown sub-kind"* ]]
  local cpath="$state_dir/transient_counters.json"
  [ -f "$cpath" ]
  local count; count=$(jq -r '."critic-spec__loop-lock" // 0' "$cpath" 2>/dev/null || echo 0)
  [ "$count" -eq 1 ]
}

@test "B2 regression: is-blocked (no kind) returns false when only transient records exist" {
  # K=3 transient occurrences accumulate; before B2 fix, is-blocked would count them and return true.
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  for i in 1 2 3; do
    printf '{"ts":"%s","kind":"transient","agent":"critic-code","sub_kind":"session-timeout","detail":"after 3600s","cleared_at":null}\n' \
      "$ts" >> "$state_dir/blocked.jsonl"
  done

  run bash -c "
    $(_libs)
    export CLAUDE_PLAN_CAPABILITY=harness
    source '$SCRIPTS_DIR/lib/plan-cmd.sh'
    cmd_is_blocked '$PLAN_FILE'
  " 2>&1
  # is-blocked must return 1 (not blocked) when only transient records are open
  [ "$status" -ne 0 ]
}

@test "B4 regression: after promotion, exactly one open env record and all transient records cleared" {
  # B4: promotion must close all transient records for (agent, sub_kind) and write exactly one env record.
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir"
  # Pre-seed counter at K-1=2 so next call is the K-th (promoting) call
  printf '{"critic-code__session-timeout":2}\n' > "$state_dir/transient_counters.json"

  bash -c "
    $(_libs)
    _record_transient '$PLAN_FILE' 'critic-code' 'session-timeout' 'after 3600s' '$SCRIPTS_DIR/plan-file.sh'
  " 2>/dev/null || true

  local bpath="$state_dir/blocked.jsonl"
  [ -f "$bpath" ]

  # All transient records for this (agent, sub_kind) must have cleared_at set
  local open_transient
  open_transient=$(jq -r 'select(.kind=="transient" and .agent=="critic-code" and .sub_kind=="session-timeout" and .cleared_at==null) | 1' \
    "$bpath" 2>/dev/null | awk 'END{print NR}')
  [ "$open_transient" -eq 0 ]

  # Exactly one open env record for this agent (env records use kind+agent; sub_kind not written by _record_blocked)
  local open_env
  open_env=$(jq -r 'select(.kind=="env" and .agent=="critic-code" and .cleared_at==null) | 1' \
    "$bpath" 2>/dev/null | awk 'END{print NR}')
  [ "$open_env" -eq 1 ]
}
