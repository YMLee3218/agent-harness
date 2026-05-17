---
name: running-dev-cycle
description: >
  Run full dev cycle: writes specs for all features first, then tests + implements each in sequence.
  Invoke only via `/running-dev-cycle` slash command.
disable-model-invocation: true
---

# Development Cycle

Resolve the active plan file, then run:

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/run-dev-cycle.sh" \
  --plan "$(bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" find-active 2>/dev/null || echo '')"
```

Use `run_in_background=true` (script may run for hours).

After the completion notification, read `## Open Questions` for any `[BLOCKED:{kind}]` markers and report to the user. All human-must kinds except `ceiling` (`envelope`, `docs`, `spec`, `code`, `env`, `harness`) require `plan-file.sh unblock` after fixing the root cause. Exception: for `[BLOCKED:ceiling]`, always use `reset-milestone {agent}` instead — `reset-milestone` both clears the marker and increments the milestone counter so the next run starts fresh. `unblock` alone does not increment the milestone counter and immediately re-triggers the ceiling block. See `@reference/markers.md §Clearing stop markers`.
