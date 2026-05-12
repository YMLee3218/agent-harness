#!/usr/bin/env bats
# F27: cmd_migrate_to_sidecar — idempotency, convergence guard, [IMPLEMENTED:] parsing.

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

setup() {
  setup_plan_dir
}

teardown() {
  teardown_plan_dir
}

_run_migrate() {
  bash -c "
    source '$SCRIPTS_DIR/lib/active-plan.sh'
    source '$SCRIPTS_DIR/phase-policy.sh'
    source '$SCRIPTS_DIR/lib/sidecar.sh'
    export PLAN_FILE_SH='$SCRIPTS_DIR/plan-file.sh'
    source '$SCRIPTS_DIR/lib/plan-lib.sh'
    source '$SCRIPTS_DIR/lib/plan-loop-helpers.sh'
    source '$SCRIPTS_DIR/lib/plan-cmd-state.sh'
    source '$SCRIPTS_DIR/lib/plan-cmd-sidecar.sh'
    CLAUDE_PLAN_CAPABILITY=harness cmd_migrate_to_sidecar '$PLAN_FILE'
  " 2>&1
}

@test "cmd_migrate_to_sidecar is idempotent (second call is a no-op)" {
  _run_migrate
  local rc=0
  _run_migrate || rc=$?
  [ "$rc" -eq 0 ]
  local sentinel
  sentinel=$(bash -c "
    source '$SCRIPTS_DIR/lib/active-plan.sh'
    source '$SCRIPTS_DIR/phase-policy.sh'
    source '$SCRIPTS_DIR/lib/sidecar.sh'
    sc_path '$PLAN_FILE' '.migrated_from_v2.txt'
  " 2>/dev/null)
  [ -f "$sentinel" ]
}

@test "cmd_migrate_to_sidecar is refused when convergence files already exist" {
  local conv_dir
  conv_dir=$(bash -c "
    source '$SCRIPTS_DIR/lib/active-plan.sh'
    source '$SCRIPTS_DIR/phase-policy.sh'
    source '$SCRIPTS_DIR/lib/sidecar.sh'
    sc_path '$PLAN_FILE' 'convergence'
  " 2>/dev/null)
  mkdir -p "$conv_dir"
  echo '{}' > "$conv_dir/implement__critic-code.json"

  run bash -c "
    source '$SCRIPTS_DIR/lib/active-plan.sh'
    source '$SCRIPTS_DIR/phase-policy.sh'
    source '$SCRIPTS_DIR/lib/sidecar.sh'
    export PLAN_FILE_SH='$SCRIPTS_DIR/plan-file.sh'
    source '$SCRIPTS_DIR/lib/plan-lib.sh'
    source '$SCRIPTS_DIR/lib/plan-loop-helpers.sh'
    source '$SCRIPTS_DIR/lib/plan-cmd-state.sh'
    source '$SCRIPTS_DIR/lib/plan-cmd-sidecar.sh'
    CLAUDE_PLAN_CAPABILITY=harness cmd_migrate_to_sidecar '$PLAN_FILE'
  " 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "cmd_migrate_to_sidecar parses [IMPLEMENTED:] markers into implemented.json" {
  printf '\n[IMPLEMENTED: my-feature]\n[IMPLEMENTED: other-feature]\n' >> "$PLAN_FILE"
  _run_migrate

  local impl_path
  impl_path=$(bash -c "
    source '$SCRIPTS_DIR/lib/active-plan.sh'
    source '$SCRIPTS_DIR/phase-policy.sh'
    source '$SCRIPTS_DIR/lib/sidecar.sh'
    sc_path '$PLAN_FILE' 'implemented.json'
  " 2>/dev/null)

  [ -f "$impl_path" ]
  run jq -r '.features | length' "$impl_path"
  [ "$output" -eq 2 ]
}
