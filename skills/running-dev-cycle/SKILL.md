---
name: running-dev-cycle
description: >
  Run full dev cycle: writes specs for all features first, then tests + implements each in sequence.
  Invoke only via `/running-dev-cycle` slash command.
---

# Development Cycle

Resolve the active plan file, then run:

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/run-dev-cycle.sh" \
  --plan "$(bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" find-active 2>/dev/null || echo '')"
```

Use `run_in_background=true` (script may run for hours).

After the completion notification, run the block check:

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" is-blocked \
  "$(bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" find-active 2>/dev/null || echo '')"
```

**If the command exits 0 (`[BLOCKED]`)**: surface its exact output verbatim, then immediately follow `@reference/blocked-guidance.md` to present the block in Korean with root-cause-first recommendations. Do not retry the dev cycle, do not predict outcomes ("this should pass", "a clean run is expected"), do not spawn a fresh `claude -p` invocation. A `HUMAN_MUST_CLEAR_MARKERS` entry means the human owns the next step — the orchestrator's role is to relay status and guide resolution, not to act past the marker.

**If the command exits 1 (`[OK]` — plan still active, no blocks)**: read `## Open Questions` for any `[BLOCKED:{kind}]` markers and report to the user. Exit 1 means no active block records but the plan is still in a non-done phase. All human-must kinds except `ceiling` (`envelope`, `docs`, `spec`, `code`, `env`, `harness`) require `plan-file.sh unblock` after fixing the root cause. Exception: for `[BLOCKED:ceiling]`, always use `reset-milestone {agent}` instead — `reset-milestone` both clears the marker and increments the milestone counter so the next run starts fresh. `unblock` alone does not increment the milestone counter and immediately re-triggers the ceiling block. See `@reference/markers.md §Clearing stop markers`. Then follow `@reference/blocked-guidance.md` to present any markers in Korean with root-cause-first recommendations.

**If the command exits 2** (`find-active` found no usable plan, or jq unavailable): In the normal case — when `run-dev-cycle.sh` completed without error — `find-active` finds no active plan and `is-blocked ""` exits 2 via `require_file`; report success. If the dev-cycle notification showed errors, run `plan-file.sh find-active` directly to diagnose: exit 0=active, 2=not-found/done, 3=ambiguous, 4=malformed.
