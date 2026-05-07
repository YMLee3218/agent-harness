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
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/run-dev-cycle.sh" {args} \
  --plan "$(bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" find-active 2>/dev/null || echo '')"
```

Use `run_in_background=true` (script may run for hours).

After the completion notification, read `## Open Questions` for any `[BLOCKED]` markers and report to the user.
