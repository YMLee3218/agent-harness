#!/usr/bin/env bash
set -euo pipefail
export CLAUDE_PLAN_CAPABILITY=harness
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PF="$SCRIPTS_DIR/plan-file.sh"
PLAN="" TEST_CMD=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --plan)     PLAN="$2";     shift 2 ;;
    --test-cmd) TEST_CMD="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ -z "$PLAN" || -z "$TEST_CMD" ]] && { echo "Usage: run-implement.sh --plan PATH --test-cmd CMD" >&2; exit 1; }
[[ -f "$PLAN" ]] || { echo "Plan file not found: $PLAN" >&2; exit 1; }

TASK_JSON=$(awk '/<!-- task-definitions-start -->/{f=1;next} /<!-- task-definitions-end -->/{f=0} f' "$PLAN")
[[ -z "$TASK_JSON" ]] && { echo "ERROR: Task Definitions block missing in $PLAN" >&2; exit 1; }

# Register all tasks in plan ledger
while IFS=$'\t' read -r id layer _; do
  bash "$PF" add-task "$PLAN" "$id" "$layer" 2>/dev/null || true
done < <(printf '%s' "$TASK_JSON" | jq -r '.[] | [.id, .layer, "x"] | @tsv')

bash "$PF" transition "$PLAN" implement "task list registered — advancing to implement"
bash "$PF" commit-phase "$PLAN" "chore(phase): advance to implement — task list registered"

BASE_SHA=$(git rev-parse HEAD)
WORK_DIR=$(mktemp -d /tmp/run-impl-XXXXXX)
_cleanup_all_worktrees() {
  for wt_file in "$WORK_DIR"/wt-*.txt; do
    [[ -f "$wt_file" ]] || continue
    wt=$(cat "$wt_file")
    id="${wt_file##*/wt-}"; id="${id%.txt}"
    branch=$(cat "$WORK_DIR/branch-${id}.txt" 2>/dev/null || true)
    [[ -n "$wt" ]]     && git worktree remove --force "$wt" 2>/dev/null || true
    [[ -n "$branch" ]] && git branch -D "$branch" 2>/dev/null || true
  done
  rm -rf "$WORK_DIR"
}
trap '_cleanup_all_worktrees' EXIT

# Extract a field from TASK_JSON for a given task id; arrays are space-joined
get_field() {
  printf '%s' "$TASK_JSON" | jq -r \
    --arg id "$1" --arg f "$2" \
    '.[] | select(.id == $id) | .[$f] | if type == "array" then join(" ") else (. // "") end'
}

make_prompt() {
  local id="$1" goal layer files spec failing_test code=""
  goal=$(get_field "$id" goal); layer=$(get_field "$id" layer)
  files=$(get_field "$id" files); spec=$(get_field "$id" spec)
  failing_test=$(get_field "$id" failing_test)
  failing_test_file="${failing_test%%::*}"
  [[ -n "$failing_test_file" && -f "$failing_test_file" ]] && code=$(cat "$failing_test_file")
  cat <<EOF
Task: ${goal}
Target layer: ${layer}
Files to modify: ${files}
Implement the minimum code needed to pass the failing test. Nothing more.
After the failing test passes, refactor within the code you wrote. Run tests after every change.
Commit once after refactor. Format: {type}({scope}): {description}

Hard constraints:
- Do NOT modify files matching: tests/* *_test.* test_*.* *.test.* *.spec.* *_spec.* spec.md
- Respect layer rules for ${layer}. If layer would be violated, STOP and emit "layer violation: {reason}".

Failing test: ${failing_test}
${code}

Test command: ${TEST_CMD}
Spec: ${spec}

When complete, emit exactly: coder-status: complete
If unable to complete for any reason, emit: coder-status: abort
EOF
}

launch_task() {
  local id="$1" bg="$2"
  local branch="impl-${id}-$$" wt="/tmp/wt-${id}-$$"
  local log="$WORK_DIR/log-${id}.txt" prompt="$WORK_DIR/prompt-${id}.txt"
  echo "$branch" > "$WORK_DIR/branch-${id}.txt"
  echo "$wt"     > "$WORK_DIR/wt-${id}.txt"
  bash "$PF" update-task "$PLAN" "$id" in_progress
  make_prompt "$id" > "$prompt"
  git worktree add "$wt" -b "$branch" 2>/dev/null
  (cd "$wt" && git rev-parse HEAD) > "$WORK_DIR/task-base-${id}.txt"
  if [[ "$bg" == "1" ]]; then
    (cd "$wt" && env -u CLAUDE_PLAN_CAPABILITY codex exec --full-auto - < "$prompt") > "$log" 2>&1 &
    echo $! > "$WORK_DIR/pid-${id}.txt"
  else
    (cd "$wt" && env -u CLAUDE_PLAN_CAPABILITY codex exec --full-auto - < "$prompt") > "$log" 2>&1 || true
  fi
}

wait_task() {
  local id="$1"
  local pid_file="$WORK_DIR/pid-${id}.txt"
  [[ -f "$pid_file" ]] && { wait "$(cat "$pid_file")" || true; rm -f "$pid_file"; }
}

verify_task() {
  local id="$1"
  local branch wt log
  branch=$(cat "$WORK_DIR/branch-${id}.txt")
  wt=$(cat "$WORK_DIR/wt-${id}.txt")
  log="$WORK_DIR/log-${id}.txt"

  # Abort detection
  if grep -qE 'coder-status: abort|^layer violation:' "$log" 2>/dev/null || \
     ! grep -q 'coder-status: complete' "$log" 2>/dev/null; then
    bash "$PF" update-task "$PLAN" "$id" blocked
    bash "$PF" append-note "$PLAN" "[BLOCKED] coder:${id} — coder aborted: $(tail -3 "$log" 2>/dev/null | tr '\n' ' ')"
    return 1
  fi

  # Test-file modification check (use per-task base SHA so tier-N+1 inherited commits are excluded)
  local task_base restore_count=0
  task_base=$(cat "$WORK_DIR/task-base-${id}.txt" 2>/dev/null || echo "$BASE_SHA")
  local test_files
  test_files=$(cd "$wt" && {
    git diff "${task_base}..HEAD" --name-only 2>/dev/null
    git diff HEAD --name-only 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  } | sort -u | grep -E '(^|/)tests/|(^|/)test_|_test\.|\.test\.|\.spec\.|_spec\.' | grep -v '\.spec\.md$' || true)
  if [[ -n "$test_files" ]]; then
    (cd "$wt" && for f in $test_files; do
      if git cat-file -e "${task_base}:${f}" 2>/dev/null; then git checkout "$task_base" -- "$f"
      else rm -f "$f"; fi
    done && git add -A && git commit -m "chore: restore test files modified by Codex" 2>/dev/null || true)
    restore_count=$(cd "$wt" && git rev-list --count "${task_base}..HEAD" 2>/dev/null || echo 0)

    local retry_log retry_prompt
    retry_log="$WORK_DIR/retry-log-${id}.txt"
    retry_prompt="$WORK_DIR/retry-prompt-${id}.txt"
    make_prompt "$id" > "$retry_prompt"
    printf '\nRETRY: previous attempt modified test files (%s) — strictly read-only.\n' "$test_files" >> "$retry_prompt"
    (cd "$wt" && env -u CLAUDE_PLAN_CAPABILITY codex exec --full-auto - < "$retry_prompt") > "$retry_log" 2>&1 || true

    if grep -qE 'coder-status: abort|^layer violation:' "$retry_log" 2>/dev/null || \
       ! grep -q 'coder-status: complete' "$retry_log" 2>/dev/null; then
      bash "$PF" update-task "$PLAN" "$id" blocked
      bash "$PF" append-note "$PLAN" "[BLOCKED] coder:${id} — test files modified after retry: ${test_files}"
      return 1
    fi
    # Re-check test files after retry to catch a second modification
    test_files=$(cd "$wt" && {
      git diff "${task_base}..HEAD" --name-only 2>/dev/null
      git diff HEAD --name-only 2>/dev/null
      git ls-files --others --exclude-standard 2>/dev/null
    } | sort -u | grep -E '(^|/)tests/|(^|/)test_|_test\.|\.test\.|\.spec\.|_spec\.' | grep -v '\.spec\.md$' || true)
    if [[ -n "$test_files" ]]; then
      bash "$PF" update-task "$PLAN" "$id" blocked
      bash "$PF" append-note "$PLAN" "[BLOCKED] coder:${id} — retry still modified test files: ${test_files}"
      return 1
    fi
  fi

  # Commit fallback: restore_count is 0 (no retry) or 1 (restore commit); any new Codex commit puts count above it
  local commit_count
  commit_count=$(cd "$wt" && git rev-list --count "${task_base}..HEAD" 2>/dev/null || echo 0)
  if [[ "$commit_count" -le "$restore_count" ]]; then
    local goal
    goal=$(get_field "$id" goal)
    (cd "$wt" && git add -A && git commit -m "feat: ${goal}" 2>/dev/null) || {
      bash "$PF" update-task "$PLAN" "$id" blocked
      bash "$PF" append-note "$PLAN" "[BLOCKED] coder:${id} — no commit and nothing to stage"
      return 1
    }
  fi

  # Run only the task's specific failing test — not the full suite, which would fail on other-tier
  # tests that haven't been implemented yet (domain tasks run before feature tasks)
  local failing_test test_file
  failing_test=$(get_field "$id" failing_test)
  test_file="${failing_test%%::*}"
  if [[ -n "$test_file" ]] && ! (cd "$wt" && bash -c "$TEST_CMD $test_file" 2>&1); then
    bash "$PF" update-task "$PLAN" "$id" blocked
    bash "$PF" append-note "$PLAN" "[BLOCKED] coder:${id} — tests failing after implementation"
    return 1
  fi

  return 0
}

cleanup_wt() {
  local id="$1"
  local branch wt
  branch=$(cat "$WORK_DIR/branch-${id}.txt" 2>/dev/null || true)
  wt=$(cat "$WORK_DIR/wt-${id}.txt" 2>/dev/null || true)
  [[ -n "$wt" ]]     && git worktree remove --force "$wt" 2>/dev/null || true
  [[ -n "$branch" ]] && git branch -D "$branch" 2>/dev/null || true
}

merge_task() {
  local id="$1"
  local branch wt goal
  branch=$(cat "$WORK_DIR/branch-${id}.txt")
  wt=$(cat "$WORK_DIR/wt-${id}.txt")
  goal=$(get_field "$id" goal)
  git merge --no-ff "$branch" -m "merge(${id}): ${goal}"
  bash "$PF" update-task "$PLAN" "$id" completed "$(git rev-parse HEAD)"
  git worktree remove --force "$wt" 2>/dev/null || true
  git branch -d "$branch" 2>/dev/null || true
}

OVERALL_BLOCKED=0

for tier in domain infrastructure features; do
  mapfile -t tier_ids < <(printf '%s' "$TASK_JSON" | jq -r --arg t "$tier" '.[] | select(.layer == $t) | .id')
  [[ ${#tier_ids[@]} -eq 0 ]] && continue

  # Separate parallel and sequential task ids
  parallel_ids=() sequential_ids=()
  for id in "${tier_ids[@]}"; do
    is_par=$(printf '%s' "$TASK_JSON" | jq -r --arg id "$id" '.[] | select(.id == $id) | .parallel | tostring')
    if [[ "$is_par" == "true" ]]; then parallel_ids+=("$id"); else sequential_ids+=("$id"); fi
  done

  tier_blocked=0

  # Launch parallel tasks as background jobs
  for id in "${parallel_ids[@]:-}"; do
    [[ -n "$id" ]] && launch_task "$id" 1
  done

  # Run sequential tasks (each waits for itself)
  for id in "${sequential_ids[@]:-}"; do
    [[ -n "$id" ]] && launch_task "$id" 0
  done

  # Wait for all parallel background jobs
  for id in "${parallel_ids[@]:-}"; do
    [[ -n "$id" ]] && wait_task "$id"
  done

  # Verify all tier tasks
  verified_ids=()
  for id in "${tier_ids[@]}"; do
    if verify_task "$id"; then
      verified_ids+=("$id")
    else
      tier_blocked=1
      cleanup_wt "$id"
    fi
  done

  if [[ $tier_blocked -eq 1 ]]; then
    # Cleanup remaining verified worktrees too
    for id in "${verified_ids[@]:-}"; do cleanup_wt "$id"; done
    OVERALL_BLOCKED=1
    break
  fi

  # Atomic tier-safe check before any merge
  if ! bash "$PF" tier-safe "$PLAN" "${tier_ids[@]}"; then
    echo "[BLOCKED] tier merge aborted — at least one task is blocked" >&2
    for id in "${tier_ids[@]}"; do cleanup_wt "$id"; done
    OVERALL_BLOCKED=1
    break
  fi

  # Merge all verified tasks in sequence
  for id in "${tier_ids[@]}"; do
    if ! merge_task "$id"; then
      bash "$PF" update-task "$PLAN" "$id" blocked
      bash "$PF" append-note "$PLAN" "[BLOCKED] coder:${id} merge conflict — resolve then re-run implementing"
      git merge --abort 2>/dev/null || true
      for _remaining in "${tier_ids[@]}"; do
        awk -v id="$_remaining" '/^## Task Ledger/{f=1;next} f&&/^## /{exit} f&&$0~id{print}' "$PLAN" \
          | grep -q 'completed' || cleanup_wt "$_remaining" 2>/dev/null || true
      done
      OVERALL_BLOCKED=1
      break 2
    fi
  done

done

# Final smoke test after all tiers are merged — validates full suite passes once all layers are implemented
if [[ $OVERALL_BLOCKED -eq 0 ]]; then
  if ! bash -c "$TEST_CMD" 2>&1; then
    bash "$PF" append-note "$PLAN" "[BLOCKED] post-implement smoke test failed — full test suite not passing after all tiers"
    OVERALL_BLOCKED=1
  fi
fi

exit $OVERALL_BLOCKED
