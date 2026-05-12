#!/usr/bin/env bats
# T3: _extract_cp_mv_dest accuracy tests

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

_dest() {
  bash -c '
    source '"$SCRIPTS_DIR"'/pretooluse-blocks.sh
    _extract_cp_mv_dest "$1"
  ' -- "$1"
}

@test "T3: _extract_cp_mv_dest: -t DIR (short flag)" {
  run _dest "cp -t /dest/dir src/file"
  [ "$status" -eq 0 ]
  [[ "$output" == "/dest/dir" ]]
}

@test "T3: _extract_cp_mv_dest: --target-directory=DIR" {
  run _dest "cp --target-directory=/dest/dir src/file"
  [ "$status" -eq 0 ]
  [[ "$output" == "/dest/dir" ]]
}

@test "T3: _extract_cp_mv_dest: --target-directory DIR (space form)" {
  run _dest "cp --target-directory /dest/dir src/file"
  [ "$status" -eq 0 ]
  [[ "$output" == "/dest/dir" ]]
}

@test "T3: _extract_cp_mv_dest: positional last arg (no flag)" {
  run _dest "cp src/file /dest/dir"
  [ "$status" -eq 0 ]
  [[ "$output" == "/dest/dir" ]]
}

@test "T3: _extract_cp_mv_dest: multiple sources positional" {
  run _dest "cp src1 src2 /dest/dir"
  [ "$status" -eq 0 ]
  [[ "$output" == "/dest/dir" ]]
}

@test "T3: _extract_cp_mv_dest: -t=DIR (equals variant)" {
  run _dest "cp -t=/dest/dir src/file"
  [ "$status" -eq 0 ]
  [[ "$output" == "/dest/dir" ]]
}

@test "T3: _extract_cp_mv_dest: positional after -t flag" {
  run _dest "cp src1 src2 -t /dest/dir"
  [ "$status" -eq 0 ]
  [[ "$output" == "/dest/dir" ]]
}

@test "T3: M2 regression: cp -t plans/x.state/ is recognised as sidecar dest" {
  run bash -c '
    source '"$SCRIPTS_DIR"'/pretooluse-blocks.sh
    _extract_cp_mv_dest "cp -t plans/0001.state/ src/file"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"plans/"* && "$output" == *".state"* ]]
}

@test "M2 regression: cp -t=DIR src is blocked by write-guard" {
  run bash -c '
    cd "$(dirname '"$SCRIPTS_DIR"')"
    source '"$SCRIPTS_DIR"'/pretooluse-blocks.sh
    _extract_cp_mv_dest "cp -t=plans/0001.state/ src/file"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"plans/"* && "$output" == *".state"* ]]
}

@test "M2 regression: cp src1 src2 -t DIR is recognised as sidecar dest (mixed order)" {
  run _dest "cp src1 src2 -t plans/0001.state/"
  [ "$status" -eq 0 ]
  [[ "$output" == *"plans/"* && "$output" == *".state"* ]]
}

# ── B7: quote stripping in extracted dest paths ───────────────────────────────

@test "B7: double-quoted dest is stripped of quotes" {
  run _dest 'cp src "plans/0001.state/x.json"'
  [ "$status" -eq 0 ]
  [[ "$output" == "plans/0001.state/x.json" ]]
}

@test "B7: single-quoted dest is stripped of quotes" {
  run _dest "cp src 'plans/0001.state/x.json'"
  [ "$status" -eq 0 ]
  [[ "$output" == "plans/0001.state/x.json" ]]
}

@test "B7: double-quoted -t=DIR is stripped of quotes" {
  run _dest 'cp -t="plans/0001.state/" src'
  [ "$status" -eq 0 ]
  [[ "$output" == "plans/0001.state/" ]]
}

@test "B7: unquoted path is unchanged" {
  run _dest "cp src /dest/dir"
  [ "$status" -eq 0 ]
  [[ "$output" == "/dest/dir" ]]
}

@test "C1/T1: plain .state path still works (regression)" {
  run _dest "cp /tmp/x plans/foo.state/blocked.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == "plans/foo.state/blocked.jsonl" ]]
}

@test "C1/T1: normal non-sidecar path is unchanged by decode (false-positive guard)" {
  run _dest "cp src /tmp/safe"
  [ "$status" -eq 0 ]
  [[ "$output" == "/tmp/safe" ]]
}

