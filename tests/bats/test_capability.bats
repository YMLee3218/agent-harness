#!/usr/bin/env bats
# Regression tests for G12 (Ring B AND model).

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

@test "G12: CLAUDE_PLAN_CAPABILITY=harness satisfies Ring B; absent causes die" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    CLAUDE_PLAN_CAPABILITY=harness
    require_capability test_cmd B && echo OK
  ' </dev/null 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    require_capability test_cmd B
  ' </dev/null 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires CLAUDE_PLAN_CAPABILITY=harness"* ]]
}

@test "G12: Ring C passes with CLAUDE_PLAN_CAPABILITY=human" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    CLAUDE_PLAN_CAPABILITY=human
    require_capability test_cmd C && echo OK
  ' </dev/null 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]]
}

@test "lock-gate: append-audit succeeds with .critic.lock present and no CLAUDE_PLAN_CAPABILITY" {
  local td plan
  td=$(mktemp -d)
  plan="$td/plans/test-feat.md"
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
## Verdict Audits
## Open Questions
EOF
  touch "${plan}.critic.lock"
  run env -u CLAUDE_PLAN_CAPABILITY CLAUDE_PROJECT_DIR="$td" \
    bash "$SCRIPTS_DIR/plan-file.sh" append-audit "$plan" "critic-spec" "ACCEPT" "all findings verified" 2>&1
  rm -rf "$td"
  [ "$status" -eq 0 ]
}

@test "lock-gate: append-audit is blocked when .critic.lock is absent" {
  local td plan
  td=$(mktemp -d)
  plan="$td/plans/test-feat.md"
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
## Verdict Audits
## Open Questions
EOF
  run env -u CLAUDE_PLAN_CAPABILITY CLAUDE_PROJECT_DIR="$td" \
    bash "$SCRIPTS_DIR/plan-file.sh" append-audit "$plan" "critic-spec" "ACCEPT" "all findings verified" 2>&1
  rm -rf "$td"
  [ "$status" -ne 0 ]
  [[ "$output" == *"critic.lock absent"* ]]
}

@test "lock-gate: clear-converged succeeds with .critic.lock present and no CLAUDE_PLAN_CAPABILITY" {
  local td plan
  td=$(mktemp -d)
  plan="$td/plans/test-feat.md"
  mkdir -p "$td/plans/test-feat.state/convergence"
  cat > "$plan" <<EOF
---
feature: test-feat
phase: implement
schema: 2
---
## Phase
implement
## Critic Verdicts
## Verdict Audits
## Open Questions
EOF
  touch "${plan}.critic.lock"
  printf '{"phase":"implement","agent":"critic-spec","first_turn":true,"streak":2,"converged":true,"ceiling_blocked":false,"ordinal":3,"milestone_seq":0}\n' \
    > "$td/plans/test-feat.state/convergence/implement__critic-spec.json"
  run env -u CLAUDE_PLAN_CAPABILITY CLAUDE_PROJECT_DIR="$td" \
    bash "$SCRIPTS_DIR/plan-file.sh" clear-converged "$plan" "critic-spec" 2>&1
  rm -rf "$td"
  [ "$status" -eq 0 ]
}

@test "lock-gate: clear-converged is blocked when .critic.lock is absent" {
  local td plan
  td=$(mktemp -d)
  plan="$td/plans/test-feat.md"
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
## Verdict Audits
## Open Questions
EOF
  run env -u CLAUDE_PLAN_CAPABILITY CLAUDE_PROJECT_DIR="$td" \
    bash "$SCRIPTS_DIR/plan-file.sh" clear-converged "$plan" "critic-spec" 2>&1
  rm -rf "$td"
  [ "$status" -ne 0 ]
  [[ "$output" == *"critic.lock absent"* ]]
}

@test "lock-gate: record-verdict (Ring B) still requires CLAUDE_PLAN_CAPABILITY — lock alone is insufficient" {
  local td plan
  td=$(mktemp -d)
  plan="$td/plans/test-feat.md"
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
  touch "${plan}.critic.lock"
  run env -u CLAUDE_PLAN_CAPABILITY CLAUDE_PROJECT_DIR="$td" \
    bash "$SCRIPTS_DIR/plan-file.sh" record-verdict 2>&1
  rm -rf "$td"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CLAUDE_PLAN_CAPABILITY"* || "$output" == *"capability"* || "$output" == *"BLOCKED"* ]]
}

@test "Ring-B: append-review-verdict is blocked when .critic.lock is absent" {
  local td plan
  td=$(mktemp -d)
  plan="$td/plans/test-feat.md"
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
  run env CLAUDE_PLAN_CAPABILITY=harness CLAUDE_PROJECT_DIR="$td" \
    bash "$SCRIPTS_DIR/plan-file.sh" append-review-verdict "$plan" pr-review PASS 2>&1
  rm -rf "$td"
  [ "$status" -ne 0 ]
  [[ "$output" == *"critic.lock"* || "$output" == *"BLOCKED"* ]]
}

