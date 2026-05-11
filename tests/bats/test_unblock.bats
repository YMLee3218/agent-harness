#!/usr/bin/env bats
# cmd_unblock — BLOCKED-AMBIGUOUS lines must survive unblock.

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
    export CLAUDE_PLAN_CAPABILITY=harness
    source "%s/lib/active-plan.sh"
    source "%s/phase-policy.sh"
    source "%s/lib/sidecar.sh"
    export PLAN_FILE_SH="%s/plan-file.sh"
    source "%s/lib/plan-lib.sh"
    source "%s/lib/plan-loop-state.sh"
    source "%s/lib/plan-cmd-state.sh"
    source "%s/lib/plan-cmd-notes.sh"
    source "%s/lib/plan-cmd-verdicts.sh"
    source "%s/lib/plan-cmd-markers.sh"
  ' "$PLAN_BASE" \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR" \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR" \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR" "$SCRIPTS_DIR"
}

@test "T7/L5: cmd_unblock preserves BLOCKED-AMBIGUOUS lines for the named agent" {
  # Pre-populate an ambiguous block and a regular block for critic-code
  cat >> "$PLAN_FILE" <<'EOF'

[BLOCKED-AMBIGUOUS] implement:critic-code: interpreter inline execution prohibited
[BLOCKED] implement:critic-code: some regular block
EOF

  run bash -c "
    $(_load_libs)
    sc_ensure_dir '$PLAN_FILE'
    cmd_unblock 'critic-code'
    grep '\[BLOCKED-AMBIGUOUS\]' '$PLAN_FILE' && echo 'ambiguous_preserved'
  " 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"ambiguous_preserved"* ]]
}

@test "T7/L5: cmd_unblock removes regular BLOCKED lines for the named agent" {
  # Append both ambiguous and regular blocks
  cat >> "$PLAN_FILE" <<'EOF'

[BLOCKED-AMBIGUOUS] implement:critic-code: interpreter inline execution prohibited
[BLOCKED] implement:critic-code: some issue to clear
EOF

  bash -c "
    $(_load_libs)
    sc_ensure_dir '$PLAN_FILE'
    cmd_unblock 'critic-code'
  " 2>/dev/null || true

  # Regular [BLOCKED] should be gone
  ! grep -q '\[BLOCKED\] implement:critic-code: some issue' "$PLAN_FILE"
}

@test "T7/L5: cmd_unblock preserves BLOCKED-AMBIGUOUS for a different agent too" {
  # Ambiguous block for critic-code, unblock critic-test
  cat >> "$PLAN_FILE" <<'EOF'

[BLOCKED-AMBIGUOUS] implement:critic-code: interpreter inline execution prohibited
[BLOCKED] implement:critic-test: some test block
EOF

  bash -c "
    $(_load_libs)
    sc_ensure_dir '$PLAN_FILE'
    cmd_unblock 'critic-test'
  " 2>/dev/null || true

  # BLOCKED-AMBIGUOUS for critic-code untouched
  grep -q '\[BLOCKED-AMBIGUOUS\] implement:critic-code' "$PLAN_FILE"
}

# ── T-11: BLOCKED-CEILING agent prefix overlap ────────────────────────────────

@test "T-11: cmd_unblock critic-test-extra does not clear critic-test ceiling line" {
  cat >> "$PLAN_FILE" <<'EOF'

[BLOCKED-CEILING] implement/critic-test: exceeded 5 runs — manual review required
EOF

  bash -c "
    $(_load_libs)
    sc_ensure_dir '$PLAN_FILE'
    cmd_unblock 'critic-test-extra' 2>/dev/null || true
  " 2>/dev/null || true

  # critic-test ceiling line must survive the unblock of critic-test-extra
  grep -q '\[BLOCKED-CEILING\] implement/critic-test: exceeded' "$PLAN_FILE"
}

@test "T-11: cmd_unblock critic-test clears only critic-test ceiling line" {
  cat >> "$PLAN_FILE" <<'EOF'

[BLOCKED-CEILING] implement/critic-test: exceeded 5 runs — manual review required
[BLOCKED-CEILING] implement/critic-test-extra: exceeded 5 runs — manual review required
EOF

  bash -c "
    $(_load_libs)
    sc_ensure_dir '$PLAN_FILE'
    cmd_unblock 'critic-test' 2>/dev/null || true
  " 2>/dev/null || true

  # critic-test line cleared, critic-test-extra preserved
  ! grep -q '\[BLOCKED-CEILING\] implement/critic-test:' "$PLAN_FILE" 2>/dev/null || true
  grep -q '\[BLOCKED-CEILING\] implement/critic-test-extra:' "$PLAN_FILE"
}

# ── T-8/H3: BLOCKED-CEILING body false-match prevention ─────────────────────

@test "T-8/H3: cmd_unblock critic-test does not clear ceiling line whose body mentions /critic-test" {
  cat >> "$PLAN_FILE" <<'EOF'

[BLOCKED-CEILING] implement/critic-code: exceeded 5 runs — see /critic-test for details
EOF

  bash -c "
    $(_load_libs)
    sc_ensure_dir '$PLAN_FILE'
    cmd_unblock 'critic-test' 2>/dev/null || true
  " 2>/dev/null || true

  # critic-code ceiling must survive — only the body mentions /critic-test
  grep -q '\[BLOCKED-CEILING\] implement/critic-code:' "$PLAN_FILE"
}

# ── T-13/H5: BLOCKED-CEILING hierarchical token boundary ─────────────────────

@test "T-13/H5: cmd_unblock critic-test does not clear hierarchical critic-test/sub ceiling" {
  cat >> "$PLAN_FILE" <<'EOF'

[BLOCKED-CEILING] implement/critic-test/subagent: exceeded 5 runs — sub-agent ceiling
[BLOCKED-CEILING] implement/critic-test: exceeded 5 runs — main ceiling
EOF

  bash -c "
    $(_load_libs)
    sc_ensure_dir '$PLAN_FILE'
    cmd_unblock 'critic-test' 2>/dev/null || true
  " 2>/dev/null || true

  # hierarchical form must survive (different scope)
  grep -q '\[BLOCKED-CEILING\] implement/critic-test/subagent:' "$PLAN_FILE"
  # non-hierarchical form must be cleared
  ! grep -q '\[BLOCKED-CEILING\] implement/critic-test:' "$PLAN_FILE" 2>/dev/null || true
}
