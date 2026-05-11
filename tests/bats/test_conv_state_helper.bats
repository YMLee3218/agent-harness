#!/usr/bin/env bats
# T-4/C4: sc_make_conv_state helper — all conv-state JSON must go through the helper.

load setup

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/scripts"

_load_sidecar() {
  cat <<SH
source '$SCRIPTS_DIR/lib/sidecar.sh'
SH
}

@test "T-4/C4: sc_make_conv_state emits canonical JSON with defaults" {
  run bash -c "
    $(_load_sidecar)
    sc_make_conv_state 'implement' 'critic-code'
  " 2>&1
  [[ "$output" == *'"phase":"implement"'* ]]
  [[ "$output" == *'"agent":"critic-code"'* ]]
  [[ "$output" == *'"first_turn":false'* ]]
  [[ "$output" == *'"streak":0'* ]]
  [[ "$output" == *'"converged":false'* ]]
  [[ "$output" == *'"ceiling_blocked":false'* ]]
  [[ "$output" == *'"ordinal":0'* ]]
  [[ "$output" == *'"milestone_seq":0'* ]]
}

@test "T-4/C4: sc_make_conv_state accepts explicit values" {
  run bash -c "
    $(_load_sidecar)
    sc_make_conv_state 'green' 'critic-test' true 3 true false 5 2
  " 2>&1
  [[ "$output" == *'"phase":"green"'* ]]
  [[ "$output" == *'"agent":"critic-test"'* ]]
  [[ "$output" == *'"first_turn":true'* ]]
  [[ "$output" == *'"streak":3'* ]]
  [[ "$output" == *'"converged":true'* ]]
  [[ "$output" == *'"ordinal":5'* ]]
  [[ "$output" == *'"milestone_seq":2'* ]]
}

@test "T-4/C4: no inline phase/agent JSON builders outside sidecar.sh" {
  local _count
  _count=$(grep -rE '"phase":"[^"]+"' "$SCRIPTS_DIR/" | grep -v sidecar.sh | wc -l || true)
  [ "$_count" -eq 0 ]
}

@test "T-4/C4: sc_make_conv_state output is valid JSON" {
  run bash -c "
    $(_load_sidecar)
    sc_make_conv_state 'implement' 'critic-spec' | jq . >/dev/null && echo valid
  " 2>&1
  [[ "$output" == *"valid"* ]]
}
