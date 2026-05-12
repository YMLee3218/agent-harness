#!/usr/bin/env bats
# Regression tests for G3 (substring bypass) and G7 (agent validation).

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

setup() {
  setup_plan_dir
  # Add a HUMAN_MUST line to the plan Open Questions
  printf '\n[BLOCKED] parse:critic-code: verdict marker missing\n' >> "$PLAN_FILE"
}

teardown() {
  teardown_plan_dir
}

@test "G3: short-marker (missing '[') does not prefix-match — HUMAN_MUST line is preserved" {
  # "BLOCKED] pars" is missing the leading '[' — with prefix matching it does not match
  # "[BLOCKED] parse:..." so the HUMAN_MUST line is preserved intact (not cleared).
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-loop-helpers.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd.sh
    cmd_clear_marker "'"$PLAN_FILE"'" "BLOCKED] pars"
  ' </dev/null 2>&1
  [ "$status" -eq 0 ]
  grep -qF "[BLOCKED] parse:critic-code:" "$PLAN_FILE"
}

@test "G3: exact full marker is blocked by Ring C when invoked via plan-file.sh without human capability" {
  run bash -c '
    unset CLAUDE_PLAN_CAPABILITY
    bash "'"$SCRIPTS_DIR"'/plan-file.sh" clear-marker "'"$PLAN_FILE"'" "[BLOCKED] parse:critic-code:"
  ' </dev/null 2>&1
  [ "$status" -ne 0 ]
}

@test "G7: unblock with invalid agent name is rejected" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    _validate_critic_agent "garbage" "unblock"
  ' 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown agent"* ]]
}

@test "H2: cmd_clear_marker preserves BLOCKED-AMBIGUOUS when clearing unrelated marker (F8 regression)" {
  # F8 fixed TOCTOU by wrapping scan+delete in single flock subshell.
  # Verify clearing one marker does not accidentally delete BLOCKED-AMBIGUOUS.
  printf '\n[BLOCKED-AMBIGUOUS] something ambiguous\n' >> "$PLAN_FILE"
  bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-loop-helpers.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd.sh
    CLAUDE_PLAN_CAPABILITY=human cmd_clear_marker "'"$PLAN_FILE"'" "[BLOCKED] parse:critic-code:"
  ' 2>/dev/null || true
  grep -q 'BLOCKED-AMBIGUOUS.*something ambiguous' "$PLAN_FILE"
}

# ── Phase-mutation gate tests ─────────────────────────────────────────────────

@test "phase-mutation: Edit touching '## Phase' in plans/*.md is blocked when capability unset" {
  td=$(mktemp -d)
  plan="$td/plans/test-feat.md"
  mkdir -p "$td/plans"
  cat > "$plan" <<'EOF'
---
schema: 2
phase: brainstorm
---
## Phase
brainstorm

## Open Questions
EOF
  # Use \\n so printf outputs \n (JSON escape) not a real newline
  printf '{"tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"## Phase\\nbrainstorm","new_string":"## Phase\\ndone"}}' "$plan" > "$td/input.json"
  run env CLAUDE_PROJECT_DIR="$td" CLAUDE_PLAN_FILE="$plan" \
    bash -c "bash '$SCRIPTS_DIR/phase-gate.sh' write < '$td/input.json'" 2>&1
  rm -rf "$td"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "phase-mutation false-positive: Edit adding Vision text in plans/*.md is allowed" {
  td=$(mktemp -d)
  plan="$td/plans/test-feat.md"
  mkdir -p "$td/plans"
  cat > "$plan" <<'EOF'
---
schema: 2
phase: brainstorm
---
## Phase
brainstorm

## Vision

## Open Questions
EOF
  printf '{"tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"## Vision\\n","new_string":"## Vision\\nBuild a great feature.\\n"}}' "$plan" > "$td/input.json"
  run env CLAUDE_PROJECT_DIR="$td" CLAUDE_PLAN_FILE="$plan" \
    bash -c "bash '$SCRIPTS_DIR/phase-gate.sh' write < '$td/input.json'" 2>&1
  rm -rf "$td"
  [ "$status" -eq 0 ]
}

@test "sidecar-write: Write tool to convergence JSON is blocked by phase-gate" {
  td=$(mktemp -d)
  local plan conv
  plan="$td/plans/test-feat.md"
  conv="$td/plans/test-feat.state/convergence/implement__critic-code.json"
  mkdir -p "$td/plans/test-feat.state/convergence"
  cat > "$plan" <<'EOF'
---
schema: 2
phase: implement
---
## Phase
implement
## Open Questions
EOF
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":"x"}}' "$conv" > "$td/input.json"
  run env CLAUDE_PROJECT_DIR="$td" CLAUDE_PLAN_FILE="$plan" \
    bash -c "bash '$SCRIPTS_DIR/phase-gate.sh' write < '$td/input.json'" 2>&1
  rm -rf "$td"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "hmcm: clear-marker with CLAUDE_PLAN_CAPABILITY=harness is rejected (Ring C requires human)" {
  run bash -c '
    CLAUDE_PLAN_CAPABILITY=harness bash "'"$SCRIPTS_DIR"'/plan-file.sh" clear-marker "'"$PLAN_FILE"'" "[BLOCKED] parse:critic-code:"
  ' </dev/null 2>&1
  [ "$status" -ne 0 ]
}

@test "hmcm: clear-marker with CLAUDE_PLAN_CAPABILITY=human succeeds on HMCM marker" {
  run bash -c '
    CLAUDE_PLAN_CAPABILITY=human bash "'"$SCRIPTS_DIR"'/plan-file.sh" clear-marker "'"$PLAN_FILE"'" "[BLOCKED] parse:critic-code:"
  ' </dev/null 2>&1
  [ "$status" -eq 0 ]
  ! grep -qF "[BLOCKED] parse:critic-code:" "$PLAN_FILE"
}

@test "ring-c-extended: Edit of scripts/phase-policy.sh is blocked when capability unset" {
  td=$(mktemp -d)
  mkdir -p "$td/scripts"
  cp "$SCRIPTS_DIR/phase-policy.sh" "$td/scripts/phase-policy.sh"
  export CLAUDE_PROJECT_DIR="$td"
  unset CLAUDE_PLAN_CAPABILITY 2>/dev/null || true
  json=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/scripts/phase-policy.sh","old_string":"x","new_string":"y"}}' "$td")
  run bash -c "printf '%s' '$json' | bash '$SCRIPTS_DIR/phase-gate.sh' write" 2>&1
  rm -rf "$td"
  unset CLAUDE_PROJECT_DIR
  [ "$status" -eq 2 ]
  [[ "$output" == *"Ring C"* || "$output" == *"BLOCKED"* ]]
}

