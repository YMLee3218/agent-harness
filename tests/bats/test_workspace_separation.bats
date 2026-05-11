#!/usr/bin/env bats
# T-21/H13: workspace separation — design-only docs must not exist in workspace/reference/.

WORKSPACE_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

@test "T-21/H13: launcher-token design doc not in workspace reference/" {
  [ ! -f "$WORKSPACE_DIR/reference/launcher-token.md" ]
}

@test "T-21/H13: hook-input-ast design doc not in workspace reference/" {
  [ ! -f "$WORKSPACE_DIR/reference/hook-input-ast.md" ]
}

@test "T-21/H13: prompt-injection design doc not in workspace reference/" {
  [ ! -f "$WORKSPACE_DIR/reference/prompt-injection.md" ]
}

@test "T-21/H13: trap-lint design doc not in workspace reference/" {
  [ ! -f "$WORKSPACE_DIR/reference/trap-lint.md" ]
}

@test "T-21/H13: bash-ast-detection design doc not in workspace reference/" {
  [ ! -f "$WORKSPACE_DIR/reference/bash-ast-detection.md" ]
}

@test "T-21/H13: workspace reference/ contains only runtime policy and agent contract docs" {
  local _design_count=0
  for _doc in launcher-token hook-input-ast prompt-injection trap-lint bash-ast-detection; do
    [ ! -f "$WORKSPACE_DIR/reference/${_doc}.md" ] || _design_count=$((_design_count + 1))
  done
  [ "$_design_count" -eq 0 ]
}
