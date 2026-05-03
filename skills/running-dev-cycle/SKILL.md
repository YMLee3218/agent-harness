---
name: running-dev-cycle
description: >
  Run full dev cycle: brainstorming → writing-spec → writing-tests → implementing in order.
  Invoke only via `/running-dev-cycle` slash command.
  Feature-slice mode by default; use --batch flag to write all specs before any tests.
disable-model-invocation: true
argument-hint: "[--profile feature|greenfield] [--batch]"
---

# Development Cycle

Resolve the active plan file, then run:

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/run-dev-cycle.sh" {args} \
  --plan "$(bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" find-active 2>/dev/null || echo '')"
```

Use `run_in_background=true` (script may run for hours).

After the completion notification, read `## Open Questions` for any `[BLOCKED]` markers and report to the user.
