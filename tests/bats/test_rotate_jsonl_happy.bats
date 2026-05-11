#!/usr/bin/env bats
# F27: _sc_rotate_jsonl happy-path (G11 covered the failure path).

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

setup() {
  setup_plan_dir
}

teardown() {
  teardown_plan_dir
}

@test "_sc_rotate_jsonl keeps and archives correct records" {
  local state_dir="$PLAN_DIR/test-feature.state"
  local src="$state_dir/verdicts.jsonl"
  local archive="$state_dir/verdicts-archive.jsonl"

  for i in 1 2 3 4 5; do
    printf '{"ordinal":%d,"verdict":"PASS"}\n' "$i" >> "$src"
  done

  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    _sc_rotate_jsonl "'"$src"'" "'"$archive"'" \
      "select(.ordinal > 2)" "select(.ordinal <= 2)" "test-rotation"
    keep_count=$(wc -l < "'"$src"'" | tr -d " ")
    archive_count=$(wc -l < "'"$archive"'" | tr -d " ")
    echo "keep=${keep_count} archive=${archive_count}"
  ' 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == "keep=3 archive=2" ]]
}

@test "_sc_rotate_jsonl keeps correct ordinals in src after rotation" {
  local state_dir="$PLAN_DIR/test-feature.state"
  local src="$state_dir/verdicts.jsonl"
  local archive="$state_dir/verdicts-archive.jsonl"

  for i in 1 2 3; do
    printf '{"ordinal":%d,"verdict":"PASS"}\n' "$i" >> "$src"
  done

  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    _sc_rotate_jsonl "'"$src"'" "'"$archive"'" \
      "select(.ordinal == 3)" "select(.ordinal < 3)" "test-rotation"
    jq -r ".ordinal" "'"$src"'"
  ' 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == "3" ]]
}

@test "_sc_rotate_jsonl returns 0 on success" {
  local state_dir="$PLAN_DIR/test-feature.state"
  local src="$state_dir/verdicts.jsonl"
  local archive="$state_dir/verdicts-archive.jsonl"

  printf '{"ordinal":1,"verdict":"PASS"}\n' > "$src"

  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    _sc_rotate_jsonl "'"$src"'" "'"$archive"'" "." "empty" "test-rotation"
    echo "rc=$?"
  ' 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == "rc=0" ]]
}

# ── T-6: archive atomicity ────────────────────────────────────────────────────

@test "T-6: _sc_rotate_jsonl does not duplicate records in archive on mv failure" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir"
  local src="$state_dir/verdicts.jsonl"
  local archive="$state_dir/verdicts-archive.jsonl"

  # 3 records: ordinals 1,2,3. We keep >=3, archive <3.
  printf '{"ordinal":1}\n{"ordinal":2}\n{"ordinal":3}\n' > "$src"

  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    _sc_rotate_jsonl "'"$src"'" "'"$archive"'" \
      "select(.ordinal >= 3)" "select(.ordinal < 3)" "test-t6"
    echo "rc=$?"
  ' 2>&1
  [ "$status" -eq 0 ]

  # Archive should have exactly 2 lines (ordinal 1 and 2), not 4
  local count; count=$(wc -l < "$archive" | tr -d ' ')
  [[ "$count" -eq 2 ]]
  # Source should have only ordinal 3
  [[ "$(jq -r '.ordinal' "$src")" == "3" ]]
}

@test "T-6: _sc_rotate_jsonl does not corrupt archive when source has single record" {
  local state_dir="$PLAN_DIR/test-feature.state"
  mkdir -p "$state_dir"
  local src="$state_dir/v2.jsonl"
  local archive="$state_dir/v2-archive.jsonl"
  printf '{"ordinal":5}\n' > "$src"
  touch "$archive"

  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    _sc_rotate_jsonl "'"$src"'" "'"$archive"'" "." "empty" "test-t6b"
    echo "rc=$?"
  ' 2>&1
  [ "$status" -eq 0 ]
  # Nothing archived (empty filter), source unchanged
  [[ "$(wc -l < "$archive" | tr -d ' ')" -eq 0 ]]
}
