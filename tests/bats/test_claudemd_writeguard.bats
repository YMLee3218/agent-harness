#!/usr/bin/env bats
# C5/C6: CLAUDE.md Ring C write-guard — agent must not be able to modify CLAUDE.md or
# reference policy docs via any write vector. All assertions use exact exit code 2.

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

setup() {
  setup_plan_dir
  export CLAUDE_PLAN_CAPABILITY=harness
  cat > "$PLAN_BASE/CLAUDE.md" <<'EOF'
# Test CLAUDE.md
- Test: echo ok
EOF
}

teardown() {
  teardown_plan_dir
  # Verify no stray files were left by hook invocations
  local _stray
  _stray=$(ls -1 "$PLAN_BASE"/ 2>/dev/null | grep -cE '^\.[A-Za-z0-9]{6}$' || true)
  [ "${_stray:-0}" -eq 0 ]
}

_bash_block_input() {
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}\n' "$1"
}

_run_bash_hook() {
  local cmd="$1"
  run bash -c "
    export CLAUDE_PROJECT_DIR='$PLAN_BASE'
    export CLAUDE_PLAN_CAPABILITY=harness
    printf '%s' '$(_bash_block_input "$cmd")' | bash '$SCRIPTS_DIR/pretooluse-bash.sh'
  " 2>&1
}

# ── Original write vectors ────────────────────────────────────────────────────

@test "C5: bash hook blocks echo >> CLAUDE.md (harness)" {
  run bash -c "
    export CLAUDE_PROJECT_DIR='$PLAN_BASE'
    export CLAUDE_PLAN_CAPABILITY=harness
    printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x >> $PLAN_BASE/CLAUDE.md\"}}' \
      | bash '$SCRIPTS_DIR/pretooluse-bash.sh'
  " 2>&1
  [ "$status" -eq 2 ]
  [[ "$output" =~ Ring\ C ]]
}

@test "C5: bash hook blocks tee CLAUDE.md (harness)" {
  run bash -c "
    export CLAUDE_PROJECT_DIR='$PLAN_BASE'
    export CLAUDE_PLAN_CAPABILITY=harness
    printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x | tee $PLAN_BASE/CLAUDE.md\"}}' \
      | bash '$SCRIPTS_DIR/pretooluse-bash.sh'
  " 2>&1
  [ "$status" -eq 2 ]
  [[ "$output" =~ Ring\ C ]]
}

@test "C5: bash hook blocks sed -i CLAUDE.md (harness)" {
  run bash -c "
    export CLAUDE_PROJECT_DIR='$PLAN_BASE'
    export CLAUDE_PLAN_CAPABILITY=harness
    printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i.bak s/X/Y/ $PLAN_BASE/CLAUDE.md\"}}' \
      | bash '$SCRIPTS_DIR/pretooluse-bash.sh'
  " 2>&1
  [ "$status" -eq 2 ]
  [[ "$output" =~ Ring\ C ]]
}

@test "C5: bash hook blocks cat > CLAUDE.md (harness)" {
  run bash -c "
    export CLAUDE_PROJECT_DIR='$PLAN_BASE'
    export CLAUDE_PLAN_CAPABILITY=harness
    printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat > $PLAN_BASE/CLAUDE.md\"}}' \
      | bash '$SCRIPTS_DIR/pretooluse-bash.sh'
  " 2>&1
  [ "$status" -eq 2 ]
  [[ "$output" =~ Ring\ C ]]
}

@test "C5: bash hook blocks mv x CLAUDE.md (harness)" {
  run bash -c "
    export CLAUDE_PROJECT_DIR='$PLAN_BASE'
    export CLAUDE_PLAN_CAPABILITY=harness
    printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mv /tmp/x.tmp $PLAN_BASE/CLAUDE.md\"}}' \
      | bash '$SCRIPTS_DIR/pretooluse-bash.sh'
  " 2>&1
  [ "$status" -eq 2 ]
  [[ "$output" =~ Ring\ C ]]
}

# ── New bypass vectors (T-5) ──────────────────────────────────────────────────

@test "T-5/C5: bash hook blocks printf redirect to CLAUDE.md" {
  run bash -c "
    export CLAUDE_PROJECT_DIR='$PLAN_BASE'
    export CLAUDE_PLAN_CAPABILITY=harness
    printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"printf '\''%s'\'' evil > CLAUDE.md\"}}' \
      | bash '$SCRIPTS_DIR/pretooluse-bash.sh'
  " 2>&1
  [ "$status" -eq 2 ]
  [[ "$output" =~ Ring\ C ]]
}

@test "T-5/C5: bash hook blocks awk print > CLAUDE.md" {
  run bash -c "
    export CLAUDE_PROJECT_DIR='$PLAN_BASE'
    export CLAUDE_PLAN_CAPABILITY=harness
    printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"awk BEGIN{print x} input > CLAUDE.md\"}}' \
      | bash '$SCRIPTS_DIR/pretooluse-bash.sh'
  " 2>&1
  [ "$status" -eq 2 ]
  [[ "$output" =~ Ring\ C ]]
}

@test "T-5/C5: bash hook blocks relative path ../CLAUDE.md write" {
  run bash -c "
    export CLAUDE_PROJECT_DIR='$PLAN_BASE'
    export CLAUDE_PLAN_CAPABILITY=harness
    printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x > ../CLAUDE.md\"}}' \
      | bash '$SCRIPTS_DIR/pretooluse-bash.sh'
  " 2>&1
  [ "$status" -eq 2 ]
  [[ "$output" =~ Ring\ C ]]
}

@test "T-5/C5: bash hook blocks write to reference/markers.md" {
  run bash -c "
    export CLAUDE_PROJECT_DIR='$PLAN_BASE'
    export CLAUDE_PLAN_CAPABILITY=harness
    printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x > reference/markers.md\"}}' \
      | bash '$SCRIPTS_DIR/pretooluse-bash.sh'
  " 2>&1
  [ "$status" -eq 2 ]
  [[ "$output" =~ Ring\ C ]]
}

# ── Allowed operations ────────────────────────────────────────────────────────

@test "C5: bash hook allows CLAUDE.md write when capability=human" {
  run bash -c "
    export CLAUDE_PROJECT_DIR='$PLAN_BASE'
    export CLAUDE_PLAN_CAPABILITY=human
    printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x >> $PLAN_BASE/CLAUDE.md\"}}' \
      | bash '$SCRIPTS_DIR/pretooluse-bash.sh'
  " 2>&1
  [ "$status" -ne 2 ]
  [[ "$output" != *"Ring C"* ]]
}

@test "C5: bash hook allows read-only cat CLAUDE.md" {
  run bash -c "
    export CLAUDE_PROJECT_DIR='$PLAN_BASE'
    export CLAUDE_PLAN_CAPABILITY=harness
    printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat $PLAN_BASE/CLAUDE.md\"}}' \
      | bash '$SCRIPTS_DIR/pretooluse-bash.sh'
  " 2>&1
  [ "$status" -eq 0 ]
}

@test "C5: bash hook allows head CLAUDE.md" {
  run bash -c "
    export CLAUDE_PROJECT_DIR='$PLAN_BASE'
    export CLAUDE_PLAN_CAPABILITY=harness
    printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"head -5 $PLAN_BASE/CLAUDE.md\"}}' \
      | bash '$SCRIPTS_DIR/pretooluse-bash.sh'
  " 2>&1
  [ "$status" -eq 0 ]
}

# ── Phase-gate write tool guard ───────────────────────────────────────────────

_phase_gate_write_input() {
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":"evil"}}\n' "$1"
}

@test "C5: phase-gate blocks agent Write to CLAUDE.md" {
  local input
  input=$(_phase_gate_write_input "$PLAN_BASE/CLAUDE.md")
  run bash -c "
    export CLAUDE_PROJECT_DIR='$PLAN_BASE'
    export CLAUDE_PLAN_CAPABILITY=harness
    printf '%s' '$input' | bash '$SCRIPTS_DIR/phase-gate.sh' write
  " 2>&1
  [ "$status" -eq 2 ]
  [[ "$output" == *"Ring C"* ]]
}

@test "C5: phase-gate allows human Write to CLAUDE.md" {
  local input
  input=$(_phase_gate_write_input "$PLAN_BASE/CLAUDE.md")
  run bash -c "
    export CLAUDE_PROJECT_DIR='$PLAN_BASE'
    export CLAUDE_PLAN_CAPABILITY=human
    printf '%s' '$input' | bash '$SCRIPTS_DIR/phase-gate.sh' write
  " 2>&1
  [ "$status" -ne 2 ]
  [[ "$output" != *"Ring C"* ]]
}

@test "C5: phase-gate allows agent Write to other files" {
  local input
  input=$(_phase_gate_write_input "$PLAN_BASE/src/feature.py")
  run bash -c "
    export CLAUDE_PROJECT_DIR='$PLAN_BASE'
    export CLAUDE_PLAN_CAPABILITY=harness
    printf '%s' '$input' | bash '$SCRIPTS_DIR/phase-gate.sh' write
  " 2>&1
  [ "$status" -ne 2 ]
  [[ "$output" != *"Ring C"* ]]
}
