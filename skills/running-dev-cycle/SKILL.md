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

**If the command exits 0 (`[BLOCKED]`)**: surface its exact output verbatim to the user and stop. Do not retry the dev cycle, do not predict outcomes ("this should pass", "a clean run is expected"), do not spawn a fresh `claude -p` invocation. A `HUMAN_MUST_CLEAR_MARKERS` entry means the human owns the next step — the orchestrator's role is to relay status, not to act past the marker.

**If the command exits 1 (`[OK]` / plan done)**: read `## Open Questions` for any `[BLOCKED:{kind}]` markers and report to the user. Exit 1 means no active block records. If the background `run-dev-cycle.sh` exited 0, the plan transitioned to `done` during the run (successful completion). All human-must kinds except `ceiling` (`envelope`, `docs`, `spec`, `code`, `env`, `harness`) require `plan-file.sh unblock` after fixing the root cause. Exception: for `[BLOCKED:ceiling]`, always use `reset-milestone {agent}` instead — `reset-milestone` both clears the marker and increments the milestone counter so the next run starts fresh. `unblock` alone does not increment the milestone counter and immediately re-triggers the ceiling block. See `@reference/markers.md §Clearing stop markers`.
