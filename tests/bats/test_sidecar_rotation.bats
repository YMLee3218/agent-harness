#!/usr/bin/env bats
# Tests for G11 (_sc_rotate_jsonl failure writes to blocked.jsonl).

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

setup() {
  setup_plan_dir
}

teardown() {
  teardown_plan_dir
}

@test "T-3/C3: rotation order — mv source before archive append (no duplicate on interruption)" {
  local state_dir="$PLAN_DIR/test-feature.state"
  local src="$state_dir/verdicts.jsonl"
  local archive="$state_dir/verdicts-archive.jsonl"
  mkdir -p "$state_dir"
  printf '{"ms":0,"v":"PASS"}\n{"ms":1,"v":"FAIL"}\n' > "$src"

  local script
  script=$(mktemp /tmp/bats_rot_XXXXXX.sh)
  cat > "$script" <<SCRIPT
source '$SCRIPTS_DIR/lib/active-plan.sh'
source '$SCRIPTS_DIR/phase-policy.sh'
source '$SCRIPTS_DIR/lib/sidecar.sh'
source '$SCRIPTS_DIR/lib/plan-lib.sh'
_sc_rotate_jsonl '$src' '$archive' 'select((.ms // 0) >= 1)' 'select((.ms // 0) < 1)' 'test-tag'
src_count=\$(wc -l < '$src' | xargs)
arch_count=\$(wc -l < '$archive' 2>/dev/null | xargs)
echo "src_count=\$src_count"
echo "arch_count=\$arch_count"
SCRIPT

  run bash "$script" 2>&1
  rm -f "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"src_count=1"* ]]
  [[ "$output" == *"arch_count=1"* ]]
}

@test "T-9/H4: gc-sidecars max_ms=0 is no-op (no rotation when only one milestone)" {
  local state_dir="$PLAN_DIR/test-feature.state"
  local vpath="$state_dir/verdicts.jsonl"
  mkdir -p "$state_dir/convergence"
  printf '{"ts":"2025-01-01T00:00:00Z","phase":"implement","agent":"critic-code","verdict":"PASS","milestone_seq":0}\n' > "$vpath"
  local orig_content; orig_content=$(cat "$vpath")

  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd-sidecar.sh
    cmd_gc_sidecars "'"$PLAN_FILE"'"
    echo "ok"
  ' 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
  # Verdicts file unchanged — nothing rotated
  [[ "$(cat "$vpath")" == "$orig_content" ]]
  # No archive created
  [ ! -f "$state_dir/verdicts-archive.jsonl" ]
}

@test "G11: _sc_rotate_jsonl failure writes runtime record to blocked.jsonl" {
  local state_dir="$PLAN_DIR/test-feature.state"
  local src="$state_dir/verdicts.jsonl"
  local archive="$state_dir/verdicts-archive.jsonl"

  # Create a source file that will fail to rotate (bad jq filter)
  echo '{"ts":"2024-01-01T00:00:00Z","phase":"implement","agent":"critic-code","verdict":"PASS"}' > "$src"

  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    # Use an invalid jq filter to force rotation failure
    _sc_rotate_jsonl "'"$src"'" "'"$archive"'" "INVALID_FILTER[[[" "INVALID[[[" "test-tag" || true
    blocked="'"$state_dir"'/blocked.jsonl"
    [ -f "$blocked" ] && jq -r ".kind" "$blocked" || echo "no-blocked"
  ' 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"runtime"* ]]
}

@test "L6: gc-sidecars max_ms=-1 (negative milestone_seq) is no-op" {
  local state_dir="$PLAN_DIR/test-feature.state"
  local vpath="$state_dir/verdicts.jsonl"
  mkdir -p "$state_dir/convergence"
  # Corrupt milestone_seq=-1 should be treated as ≤0 — no rotation
  printf '{"ts":"2025-01-01T00:00:00Z","phase":"implement","agent":"critic-code","verdict":"PASS","milestone_seq":-1}\n' > "$vpath"
  local orig_content; orig_content=$(cat "$vpath")

  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    export PLAN_FILE_SH="'"$SCRIPTS_DIR"'/plan-file.sh"
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    source '"$SCRIPTS_DIR"'/lib/plan-cmd-sidecar.sh
    cmd_gc_sidecars "'"$PLAN_FILE"'"
    echo "ok"
  ' 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
  [[ "$(cat "$vpath")" == "$orig_content" ]]
  [ ! -f "$state_dir/verdicts-archive.jsonl" ]
}

@test "L5: _sc_rotate_jsonl is safe under SIGINT during lock" {
  local state_dir="$PLAN_DIR/test-feature.state"
  local src="$state_dir/verdicts.jsonl"
  local archive="$state_dir/verdicts-archive.jsonl"
  mkdir -p "$state_dir"
  printf '{"ms":0,"v":"PASS"}\n{"ms":1,"v":"FAIL"}\n' > "$src"
  local orig_src; orig_src=$(cat "$src")

  # Fire SIGINT inside _sc_rotate_jsonl; source file must remain consistent (either original or rotated, not half-written)
  run bash -c '
    source '"$SCRIPTS_DIR"'/lib/active-plan.sh
    source '"$SCRIPTS_DIR"'/phase-policy.sh
    source '"$SCRIPTS_DIR"'/lib/sidecar.sh
    source '"$SCRIPTS_DIR"'/lib/plan-lib.sh
    (
      sleep 0.05 && kill -INT $$ 2>/dev/null
    ) &
    set +e
    _sc_rotate_jsonl "'"$src"'" "'"$archive"'" "select((.ms // 0) >= 1)" "select((.ms // 0) < 1)" "test-sigint" || true
    # File must be valid JSONL (each line is valid JSON) or empty
    if [ -s "'"$src"'" ]; then
      jq -c . "'"$src"'" >/dev/null 2>&1 && echo "src_valid" || echo "src_corrupt"
    else
      echo "src_empty"
    fi
  ' 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" != *"src_corrupt"* ]]
}
