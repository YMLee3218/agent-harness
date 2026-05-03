#!/usr/bin/env bash
set -euo pipefail
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
trap 'rm -rf "$WORK_DIR"' EXIT

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
- Do NOT modify files matching: tests/* *_test.* test_*.* *.test.* *.spec.* *_spec.*
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
  if [[ "$bg" == "1" ]]; then
    (cd "$wt" && codex exec --full-auto - < "$prompt") > "$log" 2>&1 &
    echo $! > "$WORK_DIR/pid-${id}.txt"
  else
    (cd "$wt" && codex exec --full-auto - < "$prompt") > "$log" 2>&1 || true
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
    bash "$PF" append-note "$PLAN" "[BLOCKED] coder:${id} aborted — $(tail -3 "$log" 2>/dev/null | tr '\n' ' ')"
    return 1
  fi

  # Test-file modification check
  local test_files
  test_files=$(cd "$wt" && {
    git diff "${BASE_SHA}..HEAD" --name-only 2>/dev/null
    git diff HEAD --name-only 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  } | sort -u | grep -E '(^|/)tests/|(^|/)test_|_test\.|\.test\.|\.spec\.|_spec\.' | grep -v '\.spec\.md$' || true)

  if [[ -n "$test_files" ]]; then
    (cd "$wt" && for f in $test_files; do
      if git cat-file -e "${BASE_SHA}:${f}" 2>/dev/null; then git checkout "$BASE_SHA" -- "$f"
      else rm -f "$f"; fi
    done && git add -A && git commit -m "chore: restore test files modified by Codex" 2>/dev/null || true)

    local retry_log retry_prompt
    retry_log="$WORK_DIR/retry-log-${id}.txt"
    retry_prompt="$WORK_DIR/retry-prompt-${id}.txt"
    make_prompt "$id" > "$retry_prompt"
    printf '\nRETRY: previous attempt modified test files (%s) — strictly read-only.\n' "$test_files" >> "$retry_prompt"
    (cd "$wt" && codex exec --full-auto - < "$retry_prompt") > "$retry_log" 2>&1 || true

    if grep -qE 'coder-status: abort|^layer violation:' "$retry_log" 2>/dev/null || \
       ! grep -q 'coder-status: complete' "$retry_log" 2>/dev/null; then
      bash "$PF" update-task "$PLAN" "$id" blocked
      bash "$PF" append-note "$PLAN" "[BLOCKED] coder:${id} — test files modified after retry: ${test_files}"
      return 1
    fi
    # Re-check test files after retry to catch a second modification
    test_files=$(cd "$wt" && {
      git diff "${BASE_SHA}..HEAD" --name-only 2>/dev/null
      git diff HEAD --name-only 2>/dev/null
      git ls-files --others --exclude-standard 2>/dev/null
    } | sort -u | grep -E '(^|/)tests/|(^|/)test_|_test\.|\.test\.|\.spec\.|_spec\.' | grep -v '\.spec\.md$' || true)
    if [[ -n "$test_files" ]]; then
      bash "$PF" update-task "$PLAN" "$id" blocked
      bash "$PF" append-note "$PLAN" "[BLOCKED] coder:${id} — retry still modified test files: ${test_files}"
      return 1
    fi
  fi

  # Commit fallback if Codex didn't commit
  local commit_count
  commit_count=$(cd "$wt" && git rev-list --count "${BASE_SHA}..HEAD" 2>/dev/null || echo 0)
  if [[ "$commit_count" -eq 0 ]]; then
    local goal
    goal=$(get_field "$id" goal)
    (cd "$wt" && git add -A && git commit -m "feat: ${goal}" 2>/dev/null) || {
      bash "$PF" update-task "$PLAN" "$id" blocked
      bash "$PF" append-note "$PLAN" "[BLOCKED] coder:${id} — no commit and nothing to stage"
      return 1
    }
  fi

  # Run tests in worktree
  if ! (cd "$wt" && bash -c "$TEST_CMD" 2>&1); then
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
      OVERALL_BLOCKED=1
      break 2
    fi
  done

  # Post-tier smoke test
  if ! bash -c "$TEST_CMD" 2>&1; then
    bash "$PF" append-note "$PLAN" "[BLOCKED] post-tier smoke test failed after merging ${tier} tasks"
    OVERALL_BLOCKED=1
    break
  fi
done

exit $OVERALL_BLOCKED
