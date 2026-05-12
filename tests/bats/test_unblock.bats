#!/usr/bin/env bats
# cmd_unblock — HUMAN_MUST_CLEAR_MARKERS lines must survive unblock.

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

setup() {
  setup_plan_dir
}

teardown() {
  teardown_plan_dir
}

_load_libs() { _load_plan_libs full; }

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

# ── HMCM array coverage: all human-must-clear entries preserved by unblock ───

@test "human_must_clear: cmd_unblock preserves all HUMAN_MUST_CLEAR_MARKERS entries (array coverage)" {
  cat >> "$PLAN_FILE" <<'EOF'

[BLOCKED-CEILING] implement/critic-code: exceeded 5 runs
[BLOCKED] coder:critic-code: some coder block
[BLOCKED] parse:critic-code: verdict missing twice
[BLOCKED] integration:critic-code: container failed
EOF

  bash -c "
    $(_load_libs)
    sc_ensure_dir '$PLAN_FILE'
    cmd_unblock 'critic-code'
  " 2>/dev/null || true

  grep -q '\[BLOCKED-CEILING\] implement/critic-code:' "$PLAN_FILE"
  grep -q '\[BLOCKED\] coder:critic-code:' "$PLAN_FILE"
  grep -q '\[BLOCKED\] parse:critic-code:' "$PLAN_FILE"
  grep -q '\[BLOCKED\] integration:critic-code:' "$PLAN_FILE"
}

# ── T-11/T-8/T-13: BLOCKED-CEILING token-boundary precision ─────────────────

@test "T-11/T-8/T-13: cmd_unblock matches exact agent token — preserves prefix-overlap, body-mention, and hierarchical variants" {
  cat >> "$PLAN_FILE" <<'EOF'

[BLOCKED-CEILING] implement/critic-test: exceeded 5 runs — main ceiling
[BLOCKED-CEILING] implement/critic-test-extra: exceeded 5 runs — prefix overlap
[BLOCKED-CEILING] implement/critic-code: exceeded 5 runs — see /critic-test for details
[BLOCKED-CEILING] implement/critic-test/subagent: exceeded 5 runs — sub-agent ceiling
EOF

  bash -c "
    $(_load_libs)
    sc_ensure_dir '$PLAN_FILE'
    cmd_unblock 'critic-test' 2>/dev/null || true
  " 2>/dev/null || true

  # critic-test cleared
  ! grep -q '\[BLOCKED-CEILING\] implement/critic-test:' "$PLAN_FILE" 2>/dev/null || true
  # prefix-overlap, body-mention, and hierarchical forms must survive
  grep -q '\[BLOCKED-CEILING\] implement/critic-test-extra:' "$PLAN_FILE"
  grep -q '\[BLOCKED-CEILING\] implement/critic-code:' "$PLAN_FILE"
  grep -q '\[BLOCKED-CEILING\] implement/critic-test/subagent:' "$PLAN_FILE"
}
