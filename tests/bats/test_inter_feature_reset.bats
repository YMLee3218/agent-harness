#!/usr/bin/env bats
# F27: cmd_inter_feature_reset — task definitions and ledger awk filter accuracy.

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

setup() {
  setup_plan_dir
}

teardown() {
  teardown_plan_dir
}

@test "cmd_inter_feature_reset removes task-definitions block" {
  cat >> "$PLAN_FILE" <<'EOF'

<!-- task-definitions-start -->
- T1: do something
- T2: do another thing
<!-- task-definitions-end -->
EOF
  bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-loop-state.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd-state.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd-sidecar.sh
    export CLAUDE_PLAN_FILE="'"$PLAN_FILE"'"
    CLAUDE_PLAN_CAPABILITY=harness cmd_inter_feature_reset "'"$PLAN_FILE"'"
  ' 2>/dev/null
  ! grep -q 'task-definitions-start' "$PLAN_FILE"
  ! grep -q 'T1: do something' "$PLAN_FILE"
}

@test "cmd_inter_feature_reset removes ledger rows with pending/in_progress/completed/blocked status" {
  cat >> "$PLAN_FILE" <<'EOF'

## Task Ledger
| task | status | commit |
| T1   | pending | - |
| T2   | in_progress | abc123 |
| T3   | completed | def456 |
| T4   | blocked | - |
## Integration Failures
EOF
  bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-loop-state.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd-state.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd-sidecar.sh
    export CLAUDE_PLAN_FILE="'"$PLAN_FILE"'"
    CLAUDE_PLAN_CAPABILITY=harness cmd_inter_feature_reset "'"$PLAN_FILE"'"
  ' 2>/dev/null
  ! grep -q '| T1' "$PLAN_FILE"
  ! grep -q '| T2' "$PLAN_FILE"
  ! grep -q '| T3' "$PLAN_FILE"
  ! grep -q '| T4' "$PLAN_FILE"
}

@test "cmd_inter_feature_reset preserves content outside task-definitions and ledger" {
  cat >> "$PLAN_FILE" <<'EOF'

<!-- task-definitions-start -->
- T1: task one
<!-- task-definitions-end -->
EOF
  bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-loop-state.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd-state.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd-sidecar.sh
    export CLAUDE_PLAN_FILE="'"$PLAN_FILE"'"
    CLAUDE_PLAN_CAPABILITY=harness cmd_inter_feature_reset "'"$PLAN_FILE"'"
  ' 2>/dev/null
  grep -q '## Vision' "$PLAN_FILE"
  grep -q '## Phase' "$PLAN_FILE"
}
