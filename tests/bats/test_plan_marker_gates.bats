#!/usr/bin/env bats
# Regression tests for G3 (substring bypass) and unblock behaviour.

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"
WS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  setup_plan_dir
  # Add a HUMAN_MUST marker to the plan Open Questions (new format)
  printf '\n[BLOCKED:code] critic-code: parse — verdict marker missing\n' >> "$PLAN_FILE"
}

teardown() {
  teardown_plan_dir
}

@test "G3: short-marker does not clear HMCM line; cmd_clear_marker is an internal helper" {
  # Short marker (missing '[') must not clear the HMCM line.
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-loop-helpers.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd.sh
    cmd_clear_marker "'"$PLAN_FILE"'" "BLOCKED:code] criti"
  ' </dev/null 2>&1
  [ "$status" -eq 0 ]
  grep -qF "[BLOCKED:code] critic-code: parse" "$PLAN_FILE"
}

@test "H2: cmd_clear_marker preserves [BLOCKED:spec] when clearing unrelated marker (F8 regression)" {
  # F8 fixed TOCTOU by wrapping scan+delete in single flock subshell.
  # Verify clearing one marker does not accidentally delete a [BLOCKED:spec] marker.
  printf '\n[BLOCKED:spec] critic-spec: ambiguous — something ambiguous\n' >> "$PLAN_FILE"
  bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-loop-helpers.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd.sh
    CLAUDE_PLAN_CAPABILITY=human cmd_clear_marker "'"$PLAN_FILE"'" "[BLOCKED:code] critic-code: parse"
  ' 2>/dev/null || true
  grep -q '\[BLOCKED:spec\].*something ambiguous' "$PLAN_FILE"
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

@test "ring_c: Write tool to Ring C files is blocked without human capability" {
  for path in scripts/run-critic-loop.sh scripts/lib/dev-cycle-phases.sh; do
    local json="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$WS_DIR/$path\",\"content\":\"evil\"}}"
    run bash -c "printf '%s' '$json' | CLAUDE_PROJECT_DIR='$WS_DIR' bash '$SCRIPTS_DIR/phase-gate.sh' write" 2>&1
    [ "$status" -eq 2 ]
    [[ "$output" == *"BLOCKED"* ]]
  done
}

# ── unblock: clears 7 human-must prefixes in one pass ────────────────────────

@test "unblock: clears all 7 human-must prefix markers in one pass" {
  # Write one of each human-must kind to ## Open Questions
  cat >> "$PLAN_FILE" <<'EOF'

[BLOCKED:envelope] critic-code: ENVELOPE_MISMATCH — fix spec
[BLOCKED:docs] critic-spec: contradiction — docs stale
[BLOCKED:spec] critic-code: ambiguous — which encoding?
[BLOCKED:harness] sidecar: corrupt-check — repair needed
[BLOCKED:env] preflight:jq: not-installed — brew install jq
[BLOCKED:ceiling] critic-code: spec/critic-code exceeded 20 runs — manual review required
EOF
  # Also add a marker that must NOT be cleared
  printf '[UNVERIFIED CLAIM] some assumption\n' >> "$PLAN_FILE"
  printf '[INFO] informational log\n' >> "$PLAN_FILE"

  local wrapper
  wrapper=$(mktemp /tmp/wrapper.XXXXXX.sh)
  printf '#!/usr/bin/env bash\nexport CLAUDE_PROJECT_DIR="%s"\nbash "%s/plan-file.sh" unblock "%s"\n' \
    "$PLAN_BASE" "$SCRIPTS_DIR" "$PLAN_FILE" > "$wrapper"
  chmod +x "$wrapper"
  run env CLAUDE_PLAN_CAPABILITY=human bash "$wrapper" </dev/null 2>&1
  rm -f "$wrapper"
  [ "$status" -eq 0 ]

  # All 7 human-must prefix markers must be gone
  ! grep -qF '[BLOCKED:envelope]' "$PLAN_FILE"
  ! grep -qF '[BLOCKED:docs]'     "$PLAN_FILE"
  ! grep -qF '[BLOCKED:spec]'     "$PLAN_FILE"
  ! grep -qF '[BLOCKED:code]'     "$PLAN_FILE"
  ! grep -qF '[BLOCKED:harness]'  "$PLAN_FILE"
  ! grep -qF '[BLOCKED:env]'      "$PLAN_FILE"
  ! grep -qF '[BLOCKED:ceiling]'  "$PLAN_FILE"

  # Non-stop markers must survive
  grep -qF '[UNVERIFIED CLAIM]' "$PLAN_FILE"
  grep -qF '[INFO]'             "$PLAN_FILE"
}

@test "unblock: [BLOCKED:transient] left in plan (incorrectly) is NOT cleared by unblock" {
  # [BLOCKED:transient] should never appear in plan.md; but if it does, unblock ignores it.
  printf '\n[BLOCKED:transient] critic-code: session-timeout — after 3600s\n' >> "$PLAN_FILE"

  local wrapper
  wrapper=$(mktemp /tmp/wrapper.XXXXXX.sh)
  printf '#!/usr/bin/env bash\nexport CLAUDE_PROJECT_DIR="%s"\nbash "%s/plan-file.sh" unblock "%s"\n' \
    "$PLAN_BASE" "$SCRIPTS_DIR" "$PLAN_FILE" > "$wrapper"
  chmod +x "$wrapper"
  run env CLAUDE_PLAN_CAPABILITY=human bash "$wrapper" </dev/null 2>&1
  rm -f "$wrapper"
  # unblock succeeds overall, but the transient line remains
  grep -qF '[BLOCKED:transient]' "$PLAN_FILE"
}

@test "unblock: no agent argument required — argument-less call succeeds" {
  local wrapper
  wrapper=$(mktemp /tmp/wrapper.XXXXXX.sh)
  printf '#!/usr/bin/env bash\nexport CLAUDE_PROJECT_DIR="%s"\nbash "%s/plan-file.sh" unblock "%s"\n' \
    "$PLAN_BASE" "$SCRIPTS_DIR" "$PLAN_FILE" > "$wrapper"
  chmod +x "$wrapper"
  run env CLAUDE_PLAN_CAPABILITY=human bash "$wrapper" </dev/null 2>&1
  rm -f "$wrapper"
  [ "$status" -eq 0 ]
  # The [BLOCKED:code] marker from setup must be cleared
  ! grep -qF '[BLOCKED:code] critic-code: parse' "$PLAN_FILE"
}

@test "unblock: sidecar blocked.jsonl open records for 7 kinds get cleared_at stamped" {
  # Seed blocked.jsonl with one open record for each of the 7 human-must kinds
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local kinds=("envelope" "docs" "spec" "code" "env" "harness" "ceiling")
  for k in "${kinds[@]}"; do
    printf '{"kind":"%s","agent":"critic-code","sub_kind":"test","detail":"d","ts":"%s","cleared_at":null}\n' \
      "$k" "$ts" >> "$state_dir/blocked.jsonl"
  done
  # Also seed a transient record — must NOT get cleared_at
  printf '{"kind":"transient","agent":"critic-code","sub_kind":"session-timeout","detail":"d","ts":"%s","cleared_at":null}\n' \
    "$ts" >> "$state_dir/blocked.jsonl"

  local wrapper
  wrapper=$(mktemp /tmp/wrapper.XXXXXX.sh)
  printf '#!/usr/bin/env bash\nexport CLAUDE_PROJECT_DIR="%s"\nbash "%s/plan-file.sh" unblock "%s"\n' \
    "$PLAN_BASE" "$SCRIPTS_DIR" "$PLAN_FILE" > "$wrapper"
  chmod +x "$wrapper"
  run env CLAUDE_PLAN_CAPABILITY=human bash "$wrapper" </dev/null 2>&1
  rm -f "$wrapper"
  [ "$status" -eq 0 ]

  # All 7 human-must records should have cleared_at set
  local uncleaned
  uncleaned=$(jq -r 'select(.kind != "transient" and .cleared_at == null) | .kind' "$state_dir/blocked.jsonl" 2>/dev/null || true)
  [ -z "$uncleaned" ]

  # transient record must still have cleared_at=null
  local transient_cleared
  transient_cleared=$(jq -r 'select(.kind == "transient") | .cleared_at' "$state_dir/blocked.jsonl" 2>/dev/null || true)
  [ "$transient_cleared" = "null" ]
}

@test "unblock: jq null-guard — transient record with no .message field does not crash cmd_clear_marker" {
  # Regression: plan-cmd.sh:567-569 uses (.message // "") so transient records
  # (which have .detail but no .message) must not cause jq type errors.
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  # Transient record — no .message field
  printf '{"ts":"%s","kind":"transient","agent":"critic-code","sub_kind":"session-timeout","detail":"after 3600s","cleared_at":null}\n' \
    "$ts" > "$state_dir/blocked.jsonl"
  # Code record — has .message field; should get cleared_at stamped
  printf '{"ts":"%s","kind":"code","agent":"critic-code","scope":"implement/critic-code","message":"tests-failing — needs fix","cleared_at":null}\n' \
    "$ts" >> "$state_dir/blocked.jsonl"
  printf '\n[BLOCKED:code] critic-code: tests-failing — needs fix\n' >> "$PLAN_FILE"

  local wrapper
  wrapper=$(mktemp /tmp/wrapper.XXXXXX.sh)
  printf '#!/usr/bin/env bash\nexport CLAUDE_PROJECT_DIR="%s"\nbash "%s/plan-file.sh" unblock "%s"\n' \
    "$PLAN_BASE" "$SCRIPTS_DIR" "$PLAN_FILE" > "$wrapper"
  chmod +x "$wrapper"
  run env CLAUDE_PLAN_CAPABILITY=human bash "$wrapper" </dev/null 2>&1
  rm -f "$wrapper"
  [ "$status" -eq 0 ]

  # code record must have cleared_at set; transient must remain null
  local code_cleared
  code_cleared=$(jq -r 'select(.kind == "code") | .cleared_at' "$state_dir/blocked.jsonl" 2>/dev/null || echo "FAIL")
  [ "$code_cleared" != "null" ]
  local transient_still_null
  transient_still_null=$(jq -r 'select(.kind == "transient") | .cleared_at' "$state_dir/blocked.jsonl" 2>/dev/null || echo "FAIL")
  [ "$transient_still_null" = "null" ]
}

@test "awk-inplace: awk -i inplace targeting HMCM-active plan is blocked" {
  local tf
  tf=$(mktemp)
  printf '{"tool_name":"Bash","tool_input":{"command":"awk -i inplace '"'"'/BLOCKED/d'"'"' %s"}}' "$PLAN_FILE" > "$tf"
  run bash -c "bash '$SCRIPTS_DIR/pretooluse-bash.sh' < '$tf'"
  rm -f "$tf"
  [ "$status" -ne 0 ]
}

@test "hmcm-anchor: historical prose with BLOCKED:code (no brackets) does not trigger marker detection" {
  # Regression for substring false-positive: audit log entries use bare marker text
  # without brackets; only bracketed markers at line-start should trigger detection.
  local tf
  tf=$(mktemp)
  printf '## Verdict Audits\n- 2026-05-02T critic-spec BLOCKED:spec ambiguous: reason here\n' > "$tf"
  run bash --norc -c '
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    set +e
    out=$(marker_present_human_must_clear "'"$tf"'" 2>/dev/null)
    rc=$?
    echo "out=$out rc=$rc"
  ' </dev/null 2>&1
  rm -f "$tf"
  [[ "$output" == *"rc=1"* ]]
}

@test "hmcm-anchor: active [BLOCKED:spec] marker at line start is detected" {
  local tf
  tf=$(mktemp)
  printf '[BLOCKED:spec] critic-code: ambiguous — which encoding?\n' > "$tf"
  run bash --norc -c '
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    set +e
    out=$(marker_present_human_must_clear "'"$tf"'" 2>/dev/null)
    rc=$?
    echo "out=$out rc=$rc"
  ' </dev/null 2>&1
  rm -f "$tf"
  [[ "$output" == *"rc=0"* ]]
  [[ "$output" == *"[BLOCKED:spec]"* ]]
}

@test "hmcm-anchor: all 7 human-must prefix kinds are individually detected" {
  local kinds=("envelope" "docs" "spec" "code" "env" "harness" "ceiling")
  for k in "${kinds[@]}"; do
    local tf
    tf=$(mktemp)
    printf '[BLOCKED:%s] test-agent: sub-kind — detail\n' "$k" > "$tf"
    run bash --norc -c '
      source '"$SCRIPTS_DIR"'/phase-policy.sh
      set +e
      out=$(marker_present_human_must_clear "'"$tf"'" 2>/dev/null)
      rc=$?
      echo "rc=$rc kind='"$k"'"
    ' </dev/null 2>&1
    rm -f "$tf"
    [[ "$output" == *"rc=0"* ]] || { echo "FAIL: [BLOCKED:$k] not detected"; return 1; }
  done
}

@test "hmcm-anchor: [BLOCKED:transient] at line start is NOT detected as human-must" {
  local tf
  tf=$(mktemp)
  printf '[BLOCKED:transient] critic-code: session-timeout — after 3600s\n' > "$tf"
  run bash --norc -c '
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    set +e
    out=$(marker_present_human_must_clear "'"$tf"'" 2>/dev/null)
    rc=$?
    echo "rc=$rc"
  ' </dev/null 2>&1
  rm -f "$tf"
  [[ "$output" == *"rc=1"* ]]
}

@test "clear-marker is no longer a public dispatcher command" {
  # clear-marker was removed from the public Ring C dispatcher.
  # Calling it should fail with a non-zero exit code.
  local wrapper
  wrapper=$(mktemp /tmp/wrapper.XXXXXX.sh)
  printf '#!/usr/bin/env bash\nexport CLAUDE_PROJECT_DIR="%s"\nbash "%s/plan-file.sh" clear-marker "%s" "[BLOCKED:code] critic-code: parse"\n' \
    "$PLAN_BASE" "$SCRIPTS_DIR" "$PLAN_FILE" > "$wrapper"
  chmod +x "$wrapper"
  run env CLAUDE_PLAN_CAPABILITY=human bash "$wrapper" </dev/null 2>&1
  rm -f "$wrapper"
  [ "$status" -ne 0 ]
}
