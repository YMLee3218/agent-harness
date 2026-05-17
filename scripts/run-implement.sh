#!/usr/bin/env bash
set -euo pipefail
if [[ "${CLAUDE_PLAN_CAPABILITY:-}" != "harness" ]]; then
  exec /usr/bin/env CLAUDE_PLAN_CAPABILITY=harness "$0" "$@"
fi
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

# shellcheck source=lib/implement-helpers.sh
source "$SCRIPTS_DIR/lib/implement-helpers.sh"
# prompt-builder.sh: wrap_user_data() utility — sourced for use if needed; not yet applied
# to Codex worker prompts (test file content comes from workspace and is considered trusted).
source "$SCRIPTS_DIR/lib/prompt-builder.sh" 2>/dev/null || true

while IFS=$'\t' read -r id layer _; do
  bash "$PF" add-task "$PLAN" "$id" "$layer" 2>/dev/null || true
done < <(printf '%s' "$TASK_JSON" | jq -r '.[] | [.id, .layer, "x"] | @tsv')

if [[ "$(bash "$PF" get-phase "$PLAN")" != "implement" ]]; then
  bash "$PF" transition "$PLAN" implement "task list registered — advancing to implement"
  bash "$PF" commit-phase "$PLAN" "chore(phase): advance to implement — task list registered"
fi

BASE_SHA=$(git rev-parse HEAD)
WORK_DIR=$(mktemp -d /tmp/run-impl-XXXXXX)
_cleanup_all_worktrees() {
  for wt_file in "$WORK_DIR"/wt-*.txt; do
    [[ -f "$wt_file" ]] || continue
    id="${wt_file##*/wt-}"; id="${id%.txt}"
    cleanup_wt "$id"
  done
  rm -rf "$WORK_DIR"
}
trap '_cleanup_all_worktrees' EXIT

OVERALL_BLOCKED=0

for tier in domain infrastructure features; do
  mapfile -t tier_ids < <(printf '%s' "$TASK_JSON" | jq -r --arg t "$tier" '.[] | select(.layer == $t) | .id')
  [[ ${#tier_ids[@]} -eq 0 ]] && continue

  parallel_ids=() sequential_ids=()
  for id in "${tier_ids[@]}"; do
    is_par=$(printf '%s' "$TASK_JSON" | jq -r --arg id "$id" '.[] | select(.id == $id) | .parallel | tostring')
    if [[ "$is_par" == "true" ]]; then parallel_ids+=("$id"); else sequential_ids+=("$id"); fi
  done

  tier_blocked=0

  # Sequential tasks: execute, verify, and merge one at a time so each sees prior tasks' output.
  for id in "${sequential_ids[@]:-}"; do
    [[ -n "$id" ]] || continue
    launch_task "$id" 0
    if ! verify_task "$id"; then
      cleanup_wt "$id"
      tier_blocked=1
      break
    fi
    if ! bash "$PF" tier-safe "$PLAN" "$id"; then
      echo "[BLOCKED] tier merge aborted — sequential task $id is blocked" >&2
      cleanup_wt "$id"
      OVERALL_BLOCKED=1
      break 2
    fi
    if ! merge_task "$id"; then
      bash "$PF" update-task "$PLAN" "$id" blocked
      bash "$PF" append-note "$PLAN" "[BLOCKED:code] coder:${id}: merge-conflict — resolve and re-run implementing"
      git merge --abort 2>/dev/null || true
      cleanup_wt "$id"
      OVERALL_BLOCKED=1
      break 2
    fi
  done

  if [[ $tier_blocked -eq 1 ]]; then
    OVERALL_BLOCKED=1
    break
  fi

  # Parallel tasks: launch all, wait, then batch verify and merge.
  for id in "${parallel_ids[@]:-}"; do [[ -n "$id" ]] && launch_task "$id" 1; done
  for id in "${parallel_ids[@]:-}"; do [[ -n "$id" ]] && wait_task "$id"; done

  verified_ids=()
  for id in "${parallel_ids[@]:-}"; do
    [[ -n "$id" ]] || continue
    if verify_task "$id"; then
      verified_ids+=("$id")
    else
      tier_blocked=1
      cleanup_wt "$id"
    fi
  done

  if [[ $tier_blocked -eq 1 ]]; then
    for id in "${verified_ids[@]:-}"; do cleanup_wt "$id"; done
    OVERALL_BLOCKED=1
    break
  fi

  if [[ ${#parallel_ids[@]} -gt 0 ]] && ! bash "$PF" tier-safe "$PLAN" "${parallel_ids[@]:-}"; then
    echo "[BLOCKED] tier merge aborted — at least one task is blocked" >&2
    for id in "${parallel_ids[@]:-}"; do [[ -n "$id" ]] && cleanup_wt "$id"; done
    OVERALL_BLOCKED=1
    break
  fi

  for id in "${parallel_ids[@]:-}"; do
    [[ -n "$id" ]] || continue
    if ! merge_task "$id"; then
      bash "$PF" update-task "$PLAN" "$id" blocked
      bash "$PF" append-note "$PLAN" "[BLOCKED:code] coder:${id}: merge-conflict — resolve and re-run implementing"
      git merge --abort 2>/dev/null || true
      for _remaining in "${parallel_ids[@]:-}"; do
        [[ -n "$_remaining" ]] || continue
        awk -v id="$_remaining" '/^## Task Ledger/{f=1;next} f&&/^## /{exit} f&&$0~id{print}' "$PLAN" \
          | grep -q 'completed' || cleanup_wt "$_remaining" 2>/dev/null || true
      done
      OVERALL_BLOCKED=1
      break 2
    fi
  done
done

if [[ $OVERALL_BLOCKED -eq 0 ]]; then
  if ! bash -c "$TEST_CMD" 2>&1; then
    bash "$PF" append-note "$PLAN" "[BLOCKED:code] smoke: tests-failing — full suite not passing after all tiers"
    OVERALL_BLOCKED=1
  fi
fi

exit $OVERALL_BLOCKED
