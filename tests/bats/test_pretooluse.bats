#!/usr/bin/env bats
# Smoke tests — one or two representative cases per block_* category.

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"
WS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

run_hook() {
  local cmd="$1"
  local json="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$cmd\"}}"
  printf '%s' "$json" | bash "$SCRIPTS_DIR/pretooluse-bash.sh" 2>/dev/null
}

# ── 1. block_sidecar_writes ───────────────────────────────────────────────────

@test "critic-lock: agent write to plans/*.critic.lock is blocked" {
  cd "$WS_DIR"
  run run_hook 'echo $$ > plans/feat.critic.lock'
  [ "$status" -ne 0 ]
}

@test "sidecar: cp -r to .state/ is blocked" {
  cd "$WS_DIR"
  run run_hook "cp -r src/ plans/0001.state/"
  [ "$status" -ne 0 ]
}

@test "sidecar: cp -t plans/feat.state/ is blocked" {
  cd "$WS_DIR"
  run run_hook "cp -t plans/feat.state/ src/foo.py"
  [ "$status" -ne 0 ]
}

# ── 2. block_capability ───────────────────────────────────────────────────────

@test "capability: assignment of CLAUDE_PLAN_CAPABILITY/PROJECT_DIR/PLAN_FILE is blocked" {
  cd "$WS_DIR"
  for var in CLAUDE_PLAN_CAPABILITY CLAUDE_PROJECT_DIR CLAUDE_PLAN_FILE; do
    run run_hook "${var}=evil bash -c true"
    [ "$status" -ne 0 ] || { echo "FAIL: ${var} not blocked"; return 1; }
  done
}

# ── 3. block_execution ────────────────────────────────────────────────────────

@test "execution: awk-redirect to sidecar is blocked" {
  cd "$WS_DIR"
  run run_hook "awk '{print > plans/feat.state/convergence/spec__critic-spec.json}'"
  [ "$status" -ne 0 ]
}

@test "execution: awk -i inplace targeting sidecar is blocked" {
  cd "$WS_DIR"
  run run_hook "awk -i inplace 'NR>0' plans/feat.state/convergence/spec__critic-spec.json"
  [ "$status" -ne 0 ]
}

@test "execution: python heredoc is blocked" {
  cd "$WS_DIR"
  run run_hook "python <<EOF
open('plans/x.md','w').write('evil')
EOF"
  [ "$status" -ne 0 ]
}

run_hook_with_plan() {
  local cmd="$1" plan_file="$2"
  local json="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$cmd\"}}"
  printf '%s' "$json" | CLAUDE_PLAN_FILE="$plan_file" bash "$SCRIPTS_DIR/pretooluse-bash.sh" 2>/dev/null
}

@test "block_ambiguous: sed -i to delete any HMCM marker is blocked when marker present" {
  local markers=(
    "BLOCKED-CEILING] implement/critic-code: exceeded 5 runs"
    "BLOCKED-AMBIGUOUS] critic-code: should we use approach A or B?"
    "BLOCKED] category:critic-code: FAIL_TYPE failed twice"
  )
  local td plan_file m
  for m in "${markers[@]}"; do
    td=$(mktemp -d)
    plan_file="$td/plans/test-plan.md"
    mkdir -p "$td/plans"
    cat > "$plan_file" <<EOF
---
feature: test
phase: implement
schema: 2
---
## Phase
implement
## Open Questions
[$m
EOF
    export CLAUDE_PROJECT_DIR="$td"
    run run_hook_with_plan "sed -i '/BLOCKED/d' $plan_file" "$plan_file"
    rm -rf "$td"
    [ "$status" -ne 0 ] || { echo "FAIL: '$m' was not blocked"; return 1; }
  done
  unset CLAUDE_PROJECT_DIR
}

# ── read-only: no-destination commands allowed in ambiguous state ────────────

@test "read-only: no destination commands are allowed in ambiguous state" {
  cd "$WS_DIR"
  for cmd in \
    "echo test" \
    "git status" \
    "git status && git branch" \
    "ls plans/" \
    "grep foo bar.txt" \
    "cat foo.txt | head"
  do
    run run_hook "$cmd"
    [ "$status" -eq 0 ] || { echo "FAIL: '$cmd' was blocked"; return 1; }
  done
}

# ── git branch escape: allowed in ambiguous state ────────────────────────────

@test "git-escape: git checkout and git switch are allowed in ambiguous state" {
  cd "$WS_DIR"
  for cmd in \
    "git checkout main" \
    "git checkout -b feature/autonomous-bug-fixer" \
    "git switch feature/autonomous-bug-fixer" \
    "git switch -c new-branch"
  do
    run run_hook "$cmd"
    [ "$status" -eq 0 ] || { echo "FAIL: '$cmd' was blocked"; return 1; }
  done
}

# ── plan rename / git revert guards ──────────────────────────────────────────

@test "block_plan_revert: git checkout/restore blocked when human-must-clear marker active" {
  local td plan_file cmd
  for cmd in \
    "git checkout HEAD~1 -- plans/test-plan.md" \
    "git restore plans/test-plan.md"
  do
    td=$(mktemp -d)
    plan_file="$td/plans/test-plan.md"
    mkdir -p "$td/plans"
    cat > "$plan_file" <<'EOF'
---
feature: test
phase: implement
schema: 2
---
## Phase
implement
## Open Questions
[BLOCKED-AMBIGUOUS] critic-code: some question
EOF
    export CLAUDE_PROJECT_DIR="$td"
    run run_hook_with_plan "$cmd" "$plan_file"
    rm -rf "$td"
    unset CLAUDE_PROJECT_DIR
    [ "$status" -ne 0 ]
  done
}


# ── 6. B5: variable-expansion bypass ─────────────────────────────────────────

@test "B5: variable-expansion in redirect target is fail-closed as sidecar" {
  cd "$WS_DIR"
  run run_hook 'S=test.state; echo evil > plans/foo$S/x.json'
  [ "$status" -ne 0 ]
  [[ "${output:-}${stderr:-}" == *"sidecar"* || "$status" -eq 2 ]]
}

# ── Phase A bypass regression tests ──────────────────────────────────────────

@test "A2: Write tool cannot inject [CONVERGED] marker into plan file" {
  local td plan_file
  td=$(mktemp -d)
  plan_file="$td/plans/test-plan.md"
  mkdir -p "$td/plans"
  cat > "$plan_file" <<'EOF'
---
feature: test
phase: implement
schema: 2
---
## Phase
implement
## Open Questions
EOF
  local json="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$plan_file\",\"content\":\"[CONVERGED] implement/critic-code\"}}"
  run bash -c "printf '%s' '$json' | CLAUDE_PLAN_FILE='$plan_file' CLAUDE_PROJECT_DIR='$td' bash '$SCRIPTS_DIR/phase-gate.sh' write" 2>/dev/null
  rm -rf "$td"
  [ "$status" -eq 2 ]
}

@test "A4: mv plans/ directory rename variants are blocked" {
  cd "$WS_DIR"
  for cmd in "mv plans/ backup_plans/" "mv ./plans ./backup_plans"; do
    run run_hook "$cmd"
    [ "$status" -ne 0 ]
  done
}

@test "A5: CLAUDE_PLAN_FILE outside plans/ is rejected" {
  local td
  td=$(mktemp -d)
  cat > "$td/evil-plan.md" <<'EOF'
---
feature: evil
phase: implement
schema: 2
---
## Phase
implement
EOF
  local json="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$td/src/foo.py\",\"content\":\"x=1\"}}"
  run bash -c "printf '%s' '$json' | CLAUDE_PLAN_FILE='$td/evil-plan.md' CLAUDE_PROJECT_DIR='$td' bash '$SCRIPTS_DIR/phase-gate.sh' write" 2>/dev/null
  rm -rf "$td"
  [ "$status" -eq 2 ]
}
