---
name: running-dev-cycle
description: >
  Run full dev cycle: writes specs for all features first, then tests + implements each in sequence.
  Invoke only via `/running-dev-cycle` slash command.
---

# Development Cycle

## Step 1 — Resolve active plan worktree

```bash
_boot=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null) || _boot="${CLAUDE_PROJECT_DIR:-$(pwd)}"
source "$_boot/.claude/scripts/lib/run-context.sh" && _resolve_project_dir
source "$PROJECT_DIR/.claude/scripts/lib/worktree-lib.sh"
_main_root=$(main_checkout_root "$PROJECT_DIR") || _main_root="$PROJECT_DIR"
_cur_branch=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [[ "$_cur_branch" == feature/* ]]; then
  _slug="${_cur_branch#feature/}"; _wt="$PROJECT_DIR"; _need_enter=0; _feat_count=1
else
  _slug="" _wt="" _wl_wt="" _need_enter=1 _feat_count=0
  while IFS= read -r _wl_line; do
    case "$_wl_line" in
      "worktree "*) _wl_wt="${_wl_line#worktree }" ;;
      "branch refs/heads/feature/"*)
        _feat_count=$(( _feat_count + 1 ))
        if [[ "$_feat_count" -eq 1 ]]; then
          _slug="${_wl_line#branch refs/heads/feature/}"; _wt="$_wl_wt"
        fi
        ;;
    esac
  done < <(git -C "$_main_root" worktree list --porcelain 2>/dev/null)
  if [[ -z "$_slug" ]]; then
    echo "[BLOCKED:env] running-dev-cycle: no-active-worktree — run /brainstorming first to create a plan, then re-run" >&2
    exit 1
  fi
fi
echo "SLUG=$_slug WT=$_wt NEED_ENTER=$_need_enter FEAT_COUNT=$_feat_count"
```

If `NEED_ENTER=1` and `FEAT_COUNT > 1` (multiple feature worktrees exist): show `git -C "$_main_root" worktree list` to the user and use `AskUserQuestion` to ask which feature to run. List each `feature/{slug}` as an option and update `_slug`/`_wt` to the user's selection before proceeding.
If `NEED_ENTER=1` and `FEAT_COUNT == 1`: call `EnterWorktree` with `path` set to the WT value printed above.
If `NEED_ENTER=0` (cwd is already the feature worktree — resume path), skip `EnterWorktree`.

## Step 2 — Run dev cycle

```bash
_boot=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null) || _boot="${CLAUDE_PROJECT_DIR:-$(pwd)}"
source "$_boot/.claude/scripts/lib/run-context.sh" && _resolve_project_dir
bash "$PROJECT_DIR/.claude/scripts/run-dev-cycle.sh"
```

Use `run_in_background=true` (script may run for hours). End the turn immediately after launching — the completion notification drives the next turn.

## Step 3 — Block check

After the completion notification:

```bash
_boot=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null) || _boot="${CLAUDE_PROJECT_DIR:-$(pwd)}"
source "$_boot/.claude/scripts/lib/run-context.sh" && _resolve_project_dir
bash "$PROJECT_DIR/.claude/scripts/plan-file.sh" is-blocked \
  "$(bash "$PROJECT_DIR/.claude/scripts/plan-file.sh" find-active 2>/dev/null || echo '')"
```

**If exits 0 (`[BLOCKED]`)**: follow `@reference/blocked-guidance.md` — present block in conversation language (Korean by default) with root-cause-first recommendations. (`is-blocked` produces no stdout — use `plan-file.sh context` to surface markers.) Do not retry the dev cycle, predict outcomes, or spawn a fresh `claude -p`. `HUMAN_MUST_CLEAR_MARKERS` means human owns the next step — relay status and guide resolution only.

**If exits 1 (`[OK]` — no blocks, plan still active)**: read `## Open Questions` for `[BLOCKED:{kind}]` markers and report to the user. All human-must kinds except `ceiling` require `plan-file.sh unblock` after root-cause fix; for `[BLOCKED:ceiling]` use `reset-milestone {agent}` instead (it clears the marker and increments the milestone counter — `unblock` alone would immediately re-trigger the ceiling). Follow `@reference/blocked-guidance.md`.

**If exits 2** (`find-active` found no active plan): two cases based on the dev-cycle script exit code visible in the completion notification:
- **Dev-cycle exited 0** (normal completion): plan reached `done` and was merged → report success.
- **Dev-cycle exited 3** (merge-approval pending): plan is in `done` phase but awaiting human merge — do NOT report success. Inform the user that the branch passed all gates and needs human review and merge: `CLAUDE_PLAN_CAPABILITY=human bash .claude/scripts/run-dev-cycle.sh --plan {plan}`.

If the notification showed other errors, run `plan-file.sh find-active` to diagnose (exit 0=active, 2=done/not-found, 3=ambiguous, 4=malformed).
