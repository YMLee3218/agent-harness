#!/usr/bin/env bats
# Regression tests for G12 (Ring B AND model).

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

@test "G12: CLAUDE_PLAN_CAPABILITY=harness alone is blocked without PPID match" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    CLAUDE_PLAN_CAPABILITY=harness
    require_capability test_cmd B
  ' </dev/null 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires CLAUDE_PLAN_CAPABILITY=harness"* ]]
}

@test "G12: Ring C requires CLAUDE_PLAN_CAPABILITY=human with exec-time ancestor" {
  # env sets human cap at exec-time on the wrapper bash; wrapper spawns a child that
  # calls require_capability; child's PPID is the wrapper (with exec-time human cap).
  local wrapper
  wrapper=$(mktemp /tmp/wrapper.XXXXXX.sh)
  printf '#!/usr/bin/env bash\nbash -c "source '"'"'%s/lib/active-plan.sh'"'"'; source '"'"'%s/phase-policy.sh'"'"'; require_capability test_cmd C && echo OK"\n' \
    "$SCRIPTS_DIR" "$SCRIPTS_DIR" > "$wrapper"
  chmod +x "$wrapper"
  run env CLAUDE_PLAN_CAPABILITY=human bash "$wrapper" </dev/null 2>&1
  rm -f "$wrapper"
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

@test "A3: Ring-C blocked when CLAUDE_PLAN_CAPABILITY=human set inline without ancestor" {
  # Inline env sets cap only on the child, not the parent — PPID chain check fails.
  run bash -c 'CLAUDE_PLAN_CAPABILITY=human bash -c "
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    require_capability test_cmd C && echo OK
  "' </dev/null 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" != *"OK"* ]]
}

@test "Ring-B: append-review-verdict is blocked when .critic.lock is absent" {
  local td plan wrapper
  td=$(mktemp -d)
  plan="$td/plans/test-feat.md"
  wrapper="$td/wrapper.sh"
  mkdir -p "$td/plans"
  cat > "$plan" <<EOF
---
feature: test-feat
phase: implement
schema: 2
---
## Phase
implement
## Critic Verdicts
## Open Questions
EOF
  # Write a wrapper script so plan-file.sh's direct parent process (this wrapper's bash)
  # has CLAUDE_PLAN_CAPABILITY=harness in its exec-time env, satisfying the PPID-chain check.
  printf '#!/usr/bin/env bash\nbash "%s/plan-file.sh" append-review-verdict "%s" pr-review PASS\n' \
    "$SCRIPTS_DIR" "$plan" > "$wrapper"
  chmod +x "$wrapper"
  run env CLAUDE_PLAN_CAPABILITY=harness CLAUDE_PROJECT_DIR="$td" bash "$wrapper" 2>&1
  rm -rf "$td"
  [ "$status" -ne 0 ]
  [[ "$output" == *"critic.lock"* || "$output" == *"BLOCKED"* ]]
}

