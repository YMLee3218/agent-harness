---
name: running-integration-tests
description: >
  Run end-to-end integration tests (no mocks, real connections).
  Invoked by running-dev-cycle after all features complete, or manually via `/running-integration-tests`.
  Do NOT trigger automatically — only on explicit user request or when called by running-dev-cycle.
---

# Integration Testing

## Scope

Default test path convention: `tests/integration/**`. The actual integration test command is defined in project `CLAUDE.md` (`- Integration test:` line) and may target any directory.

## Phase entry

Phase entry protocol: @reference/phase-ops.md §Skill phase entry — expected phases: `green`, `integration` (re-run after previous failure). For unexpected phases: `[BLOCKED] running-integration-tests entered from unexpected phase {phase} — expected green or integration`.

## When to run

- Major features completed (milestone boundary)
- Before deployment
- User explicitly requests

## Run

Read project `CLAUDE.md` for the unit test command and integration test command. Then:

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/run-integration.sh" \
  --plan "plans/{slug}.md" \
  --unit-cmd "{unit test command}" \
  --integration-cmd "{integration test command}"
```

Use `run_in_background=true` — this script may run for minutes.

`run-integration.sh` handles:
- Step 1.5: unit test pre-check with rollback on failure
- Phase transition to `integration` before running tests
- Pass → `done` transition
- Fail → LLM failure categorization (one B-session), rollback, fix skill invocation, re-run once (blocks on second failure)
- Blocked on ambiguous category → `[BLOCKED]` marker written to plan file

After the completion notification, read `## Open Questions` for any `[BLOCKED]` markers and report to user.
