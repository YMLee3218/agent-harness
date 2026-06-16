#!/usr/bin/env bash
# Task-lifecycle helpers for run-implement.sh — extracted to keep the orchestrator under 200 lines.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_IMPLEMENT_HELPERS_LOADED:-}" ]] && return 0
_IMPLEMENT_HELPERS_LOADED=1

_IMPL_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${_SANDBOX_LIB_LOADED:-}" ]] || . "$_IMPL_HELPERS_DIR/sandbox-lib.sh"

GIT_COMMON_DIR=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)

# All functions use globals set by run-implement.sh:
#   PLAN PF TASK_JSON WORK_DIR BASE_SHA TEST_CMD LINT_CMD TIMEOUT_CMD IMPLEMENT_TIMEOUT

# get_field ID FIELD — extracts a field from TASK_JSON for a given task id.
get_field() {
  printf '%s' "$TASK_JSON" | jq -r \
    --arg id "$1" --arg f "$2" \
    '.[] | select(.id == $id) | .[$f] | if type == "array" then join(" ") else (. // "") end'
}

# make_prompt ID — prints the full task prompt for a Codex worker.
make_prompt() {
  local id="$1" goal layer files spec failing_test failing_test_file code="" lint_constraint="" lint_cmd_line=""
  goal=$(get_field "$id" goal); layer=$(get_field "$id" layer)
  files=$(get_field "$id" files); spec=$(get_field "$id" spec)
  failing_test=$(get_field "$id" failing_test)
  failing_test_file="${failing_test%%::*}"
  if [[ -n "$failing_test_file" && -f "$failing_test_file" ]]; then
    if [[ "$failing_test" == *::* ]]; then
      _test_fn="${failing_test##*::}"
      _extractor="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/extract-test.py"
      if [[ -f "$_extractor" ]]; then
        code=$(python3 "$_extractor" "$failing_test_file" "$_test_fn" 2>/dev/null) || code=$(cat "$failing_test_file")
      else
        code=$(cat "$failing_test_file")
      fi
    else
      code=$(cat "$failing_test_file")
    fi
  fi
  if [[ -n "${LINT_CMD:-}" ]]; then
    lint_constraint=$'\n- Before emitting coder-status: complete, run the lint command and fix every violation it reports. Every violation must be in a file within your task scope — if lint reports a violation outside Files to modify, emit coder-status: abort with the detail.'
    lint_cmd_line=$'\nLint command: '"${LINT_CMD}"
  fi
  local test_cmd_display run_instruction implement_instruction failing_test_section
  if [[ -n "$failing_test" ]]; then
    test_cmd_display="${TEST_CMD} \"${failing_test_file}\""
    implement_instruction="Implement code to pass ALL tests in ${failing_test_file}. The inline test below is a representative sample only — the file contains additional tests you must also satisfy."
    run_instruction="Before writing any code, read ${failing_test_file} in full to understand every test you must pass. After each change, run the Test command below (the entire test file — this is identical to the gate). Iterate until ALL tests in the file pass. Do NOT run the full project suite — other task files are still red. NOTE: network and package managers are unavailable in this sandbox — use the Test command shown above."
    failing_test_section="Representative test (from ${failing_test_file} — read the full file for all tests):
${code}

"
  else
    test_cmd_display="(no per-task test gate for this runner — covered by smoke + critic-code)"
    run_instruction="Do NOT run the full test suite — in this TDD red phase it fails until all tasks land. Implement strictly to satisfy the Spec below. After all tasks complete, a smoke run (full suite) and critic-code (file-scoped review) verify the result."
    implement_instruction="Implement the minimum code to satisfy the Spec below. Nothing more."
    failing_test_section=""
  fi
  cat <<EOF
Task: ${goal}
Target layer: ${layer}
Files to modify: ${files}
${implement_instruction}
${run_instruction}
Do NOT run any git commands. Leave changes in the working tree. The harness performs the commit.

Hard constraints:
- Do NOT modify files matching: tests/* *_test.* test_*.* *.test.* *.spec.* *_spec.* spec.md
- Respect layer rules for ${layer}. If layer would be violated, STOP and emit "layer violation: {reason}".${lint_constraint}

${failing_test_section}Test command: ${test_cmd_display}${lint_cmd_line}
Spec: ${spec}

When complete, emit exactly: coder-status: complete
If unable to complete for any reason, emit: coder-status: abort
EOF
}

# launch_task ID BG — launch a task in a git worktree (BG=1 for background).
launch_task() {
  local id="$1" bg="$2"
  local branch="impl-${id}-$$" wt; wt=$(mktemp -d /tmp/wt-"${id}"-XXXXXX)
  local log="$WORK_DIR/log-${id}.txt" prompt="$WORK_DIR/prompt-${id}.txt"
  echo "$branch" > "$WORK_DIR/branch-${id}.txt"
  echo "$wt"     > "$WORK_DIR/wt-${id}.txt"
  bash "$PF" update-task "$PLAN" "$id" in_progress
  make_prompt "$id" > "$prompt"
  if ! git worktree add "$wt" -b "$branch"; then
    bash "$PF" update-task "$PLAN" "$id" blocked
    bash "$PF" append-note "$PLAN" "[BLOCKED:code] coder:${id}: worktree-add-failed — git worktree add failed (branch conflict or git error); resolve and re-run implementing"
    return 1
  fi
  (cd "$wt" && git rev-parse HEAD) > "$WORK_DIR/task-base-${id}.txt"
  [[ -n "${PROJECT_VENV:-}" ]] && ln -s "$PROJECT_VENV" "$wt/.venv" 2>/dev/null || true
  _sandbox_guard || {
    bash "$PF" update-task "$PLAN" "$id" blocked
    bash "$PF" append-note "$PLAN" "[BLOCKED:env] coder:${id}: sandbox-unavailable — tier1-sandbox inactive; set CLAUDE_ALLOW_UNSANDBOXED=1 to run unconfined"
    return 1
  }
  if [[ "$bg" == "1" ]]; then
    (cd "$wt" && ${TIMEOUT_CMD:+$TIMEOUT_CMD --kill-after=$TG_KILL_AFTER $IMPLEMENT_TIMEOUT} "${_WORKER_SANDBOX_ARGS[@]}" env -u CLAUDE_PLAN_CAPABILITY codex exec --full-auto ${GIT_COMMON_DIR:+--add-dir "$GIT_COMMON_DIR"} - < "$prompt") > "$log" 2>&1 &
    echo $! > "$WORK_DIR/pid-${id}.txt"
  else
    local _ec=0
    (cd "$wt" && ${TIMEOUT_CMD:+$TIMEOUT_CMD --kill-after=$TG_KILL_AFTER $IMPLEMENT_TIMEOUT} "${_WORKER_SANDBOX_ARGS[@]}" env -u CLAUDE_PLAN_CAPABILITY codex exec --full-auto ${GIT_COMMON_DIR:+--add-dir "$GIT_COMMON_DIR"} - < "$prompt") > "$log" 2>&1 || _ec=$?
    if [[ -n "${TIMEOUT_CMD:-}" && "$_ec" -eq 124 ]]; then
      echo "coder-status: abort (timeout after ${IMPLEMENT_TIMEOUT}s)" >> "$log"
    fi
  fi
}

# wait_task ID — wait for background task PID if present.
wait_task() {
  local id="$1"
  local pid_file="$WORK_DIR/pid-${id}.txt"
  if [[ -f "$pid_file" ]]; then
    local _ec=0
    wait "$(cat "$pid_file")" || _ec=$?
    rm -f "$pid_file"
    if [[ -n "${TIMEOUT_CMD:-}" && "$_ec" -eq 124 ]]; then
      echo "coder-status: abort (timeout after ${IMPLEMENT_TIMEOUT}s)" >> "$WORK_DIR/log-${id}.txt"
    fi
  fi
}

# _extract_test_paths BASE WD — prints modified/added test file paths relative to worktree.
_extract_test_paths() {
  local base="$1" wt="$2"
  (cd "$wt" && {
    git diff "${base}..HEAD" --name-only 2>/dev/null
    git diff HEAD --name-only 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  } | sort -u | grep -E '(^|/)tests/|(^|/)test_|_test\.|\.test\.|\.spec\.|_spec\.|(^|/)spec\.md$' \
    | grep -v '\.spec\.md$' || true)
}

# _restore_and_retry ID BASE WD TEST_FILES — restores test files and re-runs coder; sets restore_count.
# Returns 1 (with BLOCKED note) if retry fails or still modifies tests.
_restore_and_retry() {
  local id="$1" base="$2" wt="$3" test_files="$4"
  pre_restore_count=$(cd "$wt" && git rev-list --count "${base}..HEAD" 2>/dev/null || echo 0)
  (cd "$wt" && while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if git cat-file -e "${base}:${f}" 2>/dev/null; then git checkout "$base" -- "$f"
    else rm -f "$f"; fi
  done <<< "$test_files" && git add -A && git commit -m "chore: restore test files modified by Codex" 2>/dev/null || true)
  restore_count=$(cd "$wt" && git rev-list --count "${base}..HEAD" 2>/dev/null || echo 0)
  local retry_log="$WORK_DIR/retry-log-${id}.txt" retry_prompt="$WORK_DIR/retry-prompt-${id}.txt"
  make_prompt "$id" > "$retry_prompt"
  printf '\nRETRY: previous attempt modified test files (%s) — strictly read-only.\n' "$test_files" >> "$retry_prompt"
  local _ec=0
  _sandbox_guard || {
    bash "$PF" update-task "$PLAN" "$id" blocked
    bash "$PF" append-note "$PLAN" "[BLOCKED:env] coder:${id}: sandbox-unavailable — tier1-sandbox inactive; set CLAUDE_ALLOW_UNSANDBOXED=1 to run unconfined"
    return 1
  }
  (cd "$wt" && ${TIMEOUT_CMD:+$TIMEOUT_CMD --kill-after=$TG_KILL_AFTER $IMPLEMENT_TIMEOUT} "${_WORKER_SANDBOX_ARGS[@]}" env -u CLAUDE_PLAN_CAPABILITY codex exec --full-auto ${GIT_COMMON_DIR:+--add-dir "$GIT_COMMON_DIR"} - < "$retry_prompt") > "$retry_log" 2>&1 || _ec=$?
  if [[ -n "${TIMEOUT_CMD:-}" && "$_ec" -eq 124 ]]; then
    echo "coder-status: abort (timeout after ${IMPLEMENT_TIMEOUT}s)" >> "$retry_log"
    bash "$PF" update-task "$PLAN" "$id" blocked
    bash "$PF" append-note "$PLAN" "[BLOCKED:code] coder:${id}: aborted — retry timeout after ${IMPLEMENT_TIMEOUT}s"
    return 1
  fi
  if grep -qE 'coder-status: abort|^layer violation:' "$retry_log" 2>/dev/null || \
     ! grep -q 'coder-status: complete' "$retry_log" 2>/dev/null; then
    bash "$PF" update-task "$PLAN" "$id" blocked
    bash "$PF" append-note "$PLAN" "[BLOCKED:code] coder:${id}: test-files-touched — modified after retry: ${test_files}"
    return 1
  fi
  local still; still=$(_extract_test_paths "$base" "$wt")
  if [[ -n "$still" ]]; then
    bash "$PF" update-task "$PLAN" "$id" blocked
    bash "$PF" append-note "$PLAN" "[BLOCKED:code] coder:${id}: test-files-touched — retry still modified: ${still}"
    return 1
  fi
}

# _run_failing_test ID WD — runs all tests in the task's test file; returns 1 with BLOCKED on failure.
_run_failing_test() {
  local id="$1" wt="$2"
  local failing_test test_file
  failing_test=$(get_field "$id" failing_test)
  [[ -z "$failing_test" ]] && return 0
  test_file="${failing_test%%::*}"
  if [[ ! -f "$wt/$test_file" ]]; then
    bash "$PF" update-task "$PLAN" "$id" blocked
    bash "$PF" append-note "$PLAN" "[BLOCKED:code] coder:${id}: missing-test-file — failing_test path ${test_file} not in worktree (stale task definitions, likely a critic-test re-split changed test paths; re-run the implementing skill to regenerate task definitions)"
    return 1
  fi
  local _ec=0
  (cd "$wt" && ${TIMEOUT_CMD:+$TIMEOUT_CMD --kill-after=$TG_KILL_AFTER $IMPLEMENT_TIMEOUT} bash -c "$TEST_CMD \"\$1\"" -- "$test_file" 2>&1) || _ec=$?
  if [[ "$_ec" -ne 0 ]]; then
    bash "$PF" update-task "$PLAN" "$id" blocked
    if [[ -n "${TIMEOUT_CMD:-}" && "$_ec" -eq 124 ]]; then
      bash "$PF" append-note "$PLAN" "[BLOCKED:code] coder:${id}: tests-timeout — file-gate exceeded ${IMPLEMENT_TIMEOUT}s (possible infinite loop in generated code)"
    else
      bash "$PF" append-note "$PLAN" "[BLOCKED:code] coder:${id}: tests-failing — after implementation (file: ${test_file})"
    fi
    return 1
  fi
}

# _run_lint ID WD — runs LINT_CMD in the worktree; returns 1 with BLOCKED on failure.
_run_lint() {
  local id="$1" wt="$2"
  [[ -z "${LINT_CMD:-}" ]] && return 0
  local _ec=0
  (cd "$wt" && ${TIMEOUT_CMD:+$TIMEOUT_CMD --kill-after=$TG_KILL_AFTER $IMPLEMENT_TIMEOUT} bash -c "$LINT_CMD" 2>&1) || _ec=$?
  if [[ "$_ec" -ne 0 ]]; then
    bash "$PF" update-task "$PLAN" "$id" blocked
    if [[ -n "${TIMEOUT_CMD:-}" && "$_ec" -eq 124 ]]; then
      bash "$PF" append-note "$PLAN" "[BLOCKED:code] coder:${id}: lint-timeout — lint exceeded ${IMPLEMENT_TIMEOUT}s"
    else
      bash "$PF" append-note "$PLAN" "[BLOCKED:code] coder:${id}: lint-failing — after implementation"
    fi
    return 1
  fi
}

# verify_task ID — verify coder output, test files, and run tests. Returns 0 on success.
verify_task() {
  local id="$1"
  local branch wt log
  branch=$(cat "$WORK_DIR/branch-${id}.txt")
  wt=$(cat "$WORK_DIR/wt-${id}.txt")
  log="$WORK_DIR/log-${id}.txt"

  local last_status
  last_status=$(grep 'coder-status:' "$log" 2>/dev/null | tail -1) || true
  if grep -q '^layer violation:' "$log" 2>/dev/null; then
    bash "$PF" update-task "$PLAN" "$id" blocked
    bash "$PF" append-note "$PLAN" "[BLOCKED:code] coder:${id}: aborted — $(tail -3 "$log" 2>/dev/null | tr '\n' ' ')"
    return 1
  fi
  if [[ "$last_status" == *"coder-status: abort"* ]]; then
    local _ft_abort; _ft_abort=$(get_field "$id" failing_test)
    if [[ -z "$_ft_abort" ]]; then
      bash "$PF" update-task "$PLAN" "$id" blocked
      bash "$PF" append-note "$PLAN" "[BLOCKED:code] coder:${id}: aborted — $(tail -3 "$log" 2>/dev/null | tr '\n' ' ')"
      return 1
    fi
    # Has failing_test: fall through to the test gate — gate pass → harness commits; gate fail → blocked then.
  fi
  if [[ "$last_status" != *"coder-status: complete"* ]]; then
    _run_failing_test "$id" "$wt" || return 1
  fi

  local task_base restore_count=0 pre_restore_count=0
  task_base=$(cat "$WORK_DIR/task-base-${id}.txt" 2>/dev/null || echo "$BASE_SHA")
  local test_files; test_files=$(_extract_test_paths "$task_base" "$wt")
  if [[ -n "$test_files" ]]; then
    _restore_and_retry "$id" "$task_base" "$wt" "$test_files" || return 1
  fi

  local commit_count
  commit_count=$(cd "$wt" && git rev-list --count "${task_base}..HEAD" 2>/dev/null || echo 0)
  if [[ "$commit_count" -le "$restore_count" ]]; then
    local goal; goal=$(get_field "$id" goal)
    if ! (cd "$wt" && git add -A && git commit -m "feat: ${goal}" 2>/dev/null); then
      # Only block when original Codex also made no commits. If pre_restore_count > 0,
      # original had implementation commits; retry added none but implementation may be
      # complete — fall through to _run_failing_test to verify.
      if [[ "$pre_restore_count" -eq 0 ]]; then
        bash "$PF" update-task "$PLAN" "$id" blocked
        bash "$PF" append-note "$PLAN" "[BLOCKED:code] coder:${id}: no-commit — nothing to stage"
        return 1
      fi
    fi
  fi
  _run_failing_test "$id" "$wt" || return 1
  _run_lint "$id" "$wt" || return 1
  return 0
}

# cleanup_wt ID — remove worktree and branch for a task.
cleanup_wt() {
  local id="$1"
  local branch wt
  branch=$(cat "$WORK_DIR/branch-${id}.txt" 2>/dev/null || true)
  wt=$(cat "$WORK_DIR/wt-${id}.txt" 2>/dev/null || true)
  [[ -n "$wt" ]]     && git worktree remove --force "$wt" 2>/dev/null || true
  [[ -n "$branch" ]] && git branch -D "$branch" 2>/dev/null || true
}

# _run_regression_gate MERGED_ID — re-runs all completed tasks' test files after a merge; returns 1 on regression.
_run_regression_gate() {
  local merged_id="$1"
  [[ ! -s "$WORK_DIR/completed-test-files.txt" ]] && return 0
  mapfile -t _reg_files < "$WORK_DIR/completed-test-files.txt"
  local _ec=0
  (${TIMEOUT_CMD:+$TIMEOUT_CMD --kill-after=$TG_KILL_AFTER $SMOKE_TIMEOUT} bash -c "$TEST_CMD \"\$@\"" -- "${_reg_files[@]}" 2>&1) || _ec=$?
  if [[ -n "${TIMEOUT_CMD:-}" && "$_ec" -eq 124 ]]; then
    bash "$PF" append-note "$PLAN" "[BLOCKED:code] regression: tests-timeout — regression re-run after merge of ${merged_id} exceeded ${SMOKE_TIMEOUT}s (possible hang; set CLAUDE_SMOKE_TIMEOUT to adjust)"
    return 1
  fi
  if [[ "$_ec" -ne 0 ]]; then
    bash "$PF" append-note "$PLAN" "[BLOCKED:code] regression: tests-failing — merge of ${merged_id} broke previously-passing test files; resolve regression and re-run implementing"
    return 1
  fi
}

# merge_task ID — merge the task branch into HEAD and mark task completed.
merge_task() {
  local id="$1"
  local branch wt goal
  branch=$(cat "$WORK_DIR/branch-${id}.txt")
  wt=$(cat "$WORK_DIR/wt-${id}.txt")
  goal=$(get_field "$id" goal)
  git merge --no-ff "$branch" -m "merge(${id}): ${goal}" || return 1
  bash "$PF" update-task "$PLAN" "$id" completed "$(git rev-parse HEAD)"
  git worktree remove --force "$wt" 2>/dev/null || true
  git branch -d "$branch" 2>/dev/null || true
}
