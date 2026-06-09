#!/usr/bin/env bash
# Task-lifecycle helpers for run-implement.sh — extracted to keep the orchestrator under 200 lines.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_IMPLEMENT_HELPERS_LOADED:-}" ]] && return 0
_IMPLEMENT_HELPERS_LOADED=1

# All functions use globals set by run-implement.sh:
#   PLAN PF TASK_JSON WORK_DIR BASE_SHA TEST_CMD LINT_CMD

# get_field ID FIELD — extracts a field from TASK_JSON for a given task id.
get_field() {
  printf '%s' "$TASK_JSON" | jq -r \
    --arg id "$1" --arg f "$2" \
    '.[] | select(.id == $id) | .[$f] | if type == "array" then join(" ") else (. // "") end'
}

# make_prompt ID — prints the full task prompt for a Codex worker.
make_prompt() {
  local id="$1" goal layer files spec failing_test code="" lint_constraint="" lint_cmd_line=""
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
  local contracts=""
  if [[ -n "${PLAN:-}" && -f "${PLAN:-}" ]]; then
    contracts=$(awk '/^## Open Questions$/{f=1;next} f&&/^## /{f=0} f&&/\[AUTO-DECIDED\]/{
      sub(/.*\[AUTO-DECIDED\][^:]*: /,""); print "- "$0
    }' "$PLAN" 2>/dev/null || true)
  fi
  cat <<EOF
Task: ${goal}
Target layer: ${layer}
Files to modify: ${files}
Implement the minimum code needed to pass the failing test. Nothing more.
After the failing test passes, refactor within the code you wrote. Run tests after every change.
Commit once after refactor. Format: {type}({scope}): {description}

Hard constraints:
- Do NOT modify files matching: tests/* *_test.* test_*.* *.test.* *.spec.* *_spec.* spec.md
- Respect layer rules for ${layer}. If layer would be violated, STOP and emit "layer violation: {reason}".${lint_constraint}

Failing test: ${failing_test}
${code}

Test command: ${TEST_CMD}${lint_cmd_line}
Spec: ${spec}
${contracts:+
Implementation decisions (made during planning — follow exactly):
${contracts}}
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
  if [[ "$bg" == "1" ]]; then
    (cd "$wt" && env -u CLAUDE_PLAN_CAPABILITY codex exec --full-auto - < "$prompt") > "$log" 2>&1 &
    echo $! > "$WORK_DIR/pid-${id}.txt"
  else
    (cd "$wt" && env -u CLAUDE_PLAN_CAPABILITY codex exec --full-auto - < "$prompt") > "$log" 2>&1 || true
  fi
}

# wait_task ID — wait for background task PID if present.
wait_task() {
  local id="$1"
  local pid_file="$WORK_DIR/pid-${id}.txt"
  [[ -f "$pid_file" ]] && { wait "$(cat "$pid_file")" || true; rm -f "$pid_file"; }
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
  if ! (cd "$wt" && while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if git cat-file -e "${base}:${f}" 2>/dev/null; then git checkout "$base" -- "$f"
    else rm -f "$f"; fi
  done <<< "$test_files" && git add -A && \
    { git diff --cached --quiet || git commit -m "chore: restore test files modified by Codex" 2>/dev/null; }); then
    bash "$PF" update-task "$PLAN" "$id" blocked
    bash "$PF" append-note "$PLAN" "[BLOCKED:code] coder:${id}: restore-failed — could not restore test files: ${test_files}"
    return 1
  fi
  restore_count=$(cd "$wt" && git rev-list --count "${base}..HEAD" 2>/dev/null || echo 0)
  local retry_log="$WORK_DIR/retry-log-${id}.txt" retry_prompt="$WORK_DIR/retry-prompt-${id}.txt"
  make_prompt "$id" > "$retry_prompt"
  printf '\nRETRY: previous attempt modified test files (%s) — strictly read-only.\n' "$test_files" >> "$retry_prompt"
  (cd "$wt" && env -u CLAUDE_PLAN_CAPABILITY codex exec --full-auto - < "$retry_prompt") > "$retry_log" 2>&1 || true
  local last_status
  last_status=$(grep 'coder-status:' "$retry_log" 2>/dev/null | tail -1 || true)
  if [[ "$last_status" != *"coder-status: complete"* ]] || grep -q '^layer violation:' "$retry_log" 2>/dev/null; then
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

# _run_failing_test ID WD — runs the task's designated failing test; returns 1 with BLOCKED on failure.
_run_failing_test() {
  local id="$1" wt="$2"
  local failing_test
  failing_test=$(get_field "$id" failing_test)
  if [[ -n "$failing_test" ]]; then
    local test_out
    if ! test_out=$(cd "$wt" && bash -c "$TEST_CMD \"\$1\"" -- "$failing_test" 2>&1); then
      local summary; summary=$(printf '%s' "$test_out" | tail -20 | tr '\n' '↵')
      bash "$PF" update-task "$PLAN" "$id" blocked
      bash "$PF" append-note "$PLAN" "[BLOCKED:code] coder:${id}: tests-failing — ${summary}"
      return 1
    fi
  fi
}

# _run_lint ID WD — runs LINT_CMD in the worktree; returns 1 with BLOCKED on failure.
_run_lint() {
  local id="$1" wt="$2"
  [[ -z "${LINT_CMD:-}" ]] && return 0
  local lint_out
  if ! lint_out=$(cd "$wt" && bash -c "$LINT_CMD" 2>&1); then
    local summary; summary=$(printf '%s' "$lint_out" | head -20 | tr '\n' '↵')
    bash "$PF" update-task "$PLAN" "$id" blocked
    bash "$PF" append-note "$PLAN" "[BLOCKED:code] coder:${id}: lint-failing — ${summary}"
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
  last_status=$(grep 'coder-status:' "$log" 2>/dev/null | tail -1 || true)
  if [[ "$last_status" != *"coder-status: complete"* ]] || grep -q '^layer violation:' "$log" 2>/dev/null; then
    bash "$PF" update-task "$PLAN" "$id" blocked
    bash "$PF" append-note "$PLAN" "[BLOCKED:code] coder:${id}: aborted — $(tail -3 "$log" 2>/dev/null | tr '\n' ' ')"
    return 1
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
    if ! (cd "$wt" && git add -A && git commit -m "feat: ${goal}"); then
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
