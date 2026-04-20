---
name: running-integration-tests
description: >
  Run end-to-end integration tests (no mocks, real connections).
  Invoked by running-dev-cycle after all features complete, or manually via `/running-integration-tests`.
  Handles failures by auto-invoking writing-spec, writing-tests, or implementing as appropriate.
disable-model-invocation: true
---

# Integration Testing

## Scope

Default test path: `tests/integration/**`. Override per project via `PHASE_GATE_TEST_GLOB` if your layout differs.

Invocable via `/running-integration-tests` or automatically by `running-dev-cycle`.

## When to run

- Major features completed (milestone boundary)
- Before deployment
- User explicitly requests

## Step 1 — Identify scope

- `Read` `docs/requirements/*.md` to determine which features are in scope
- `Glob` `tests/integration/` to find existing integration tests
- `Read` project `CLAUDE.md` for the integration test command

Write scope summary to plan file. Proceed to Step 1.5.

## Step 1.5 — Verify unit tests pass

Before running integration tests, run the unit test command from project CLAUDE.md to confirm there are no pre-existing regressions.

If unit tests fail:
1. Roll back phase so `implementing` can enter with fresh task planning:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" implement \
     "unit tests failing at integration entry — clearing implement-phase markers"
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-for-rollback "plans/{slug}.md" implement
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" red \
     "unit tests failing at integration entry — fresh task planning needed"
   ```
2. Append `[BLOCKED] unit tests failing before integration tests — resolve via /implementing before re-running` to `## Open Questions` and stop.

Do not start integration tests with a broken unit test baseline.

## Step 2 — Run tests

Set phase to `integration` **before** executing tests so that the stop-check hook and any
mid-run Stop events record the correct phase:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" integration \
  "starting integration test run"
```

Execute the integration test command from project CLAUDE.md.

No mocks — real domain + feature + infrastructure connections.

## Step 3 — Handle failures

If tests pass:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" done \
  "integration tests passed"
```
Done.

If tests fail:

1. Record each failure in `plans/{slug}.md` under a `## Integration Failures` section (append; do not overwrite). Do **not** write failure logs into `docs/requirements/` — that directory is for business requirements, not incident records.
   ```
   ### {date} — {test name}
   Category: {docs conflict | spec gap | implementation bug}
   Description: {one sentence}
   ```
2. Determine the failure category by inferring from failure evidence:

| Category | Action | Rollback target |
|----------|--------|----------------|
| **docs conflict** | Update `docs/*.md` (SOT) first, then invoke `writing-spec` → `writing-tests` → `implementing` as needed | spec |
| **spec gap** | Invoke `writing-spec` → `writing-tests` → `implementing` as needed | spec |
| **implementation bug** | Invoke `implementing` | implement |

3. If the category is unambiguous, log `[AUTO-CATEGORIZED-INTEGRATION] {test name}: {category}` to `## Integration Failures` and proceed. If the category is ambiguous, append `[BLOCKED] integration:{test name}: cannot determine category automatically — manual review required` to `## Open Questions` and stop.

4. After categorization, set the rollback phase first, then reset convergence state, then invoke the fix skill:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" {rollback-phase} \
     "{one sentence reason}"
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-for-rollback "plans/{slug}.md" {rollback-phase}
   ```
   Then invoke the appropriate skill via `Skill(...)`.

## Step 4 — Re-run after fix (max 2 re-run attempts)

Count prior fix attempts by counting `### ` header entries in `## Integration Failures`:
```bash
attempt=$(awk '/^## Integration Failures$/{s=1;next} s&&/^## /{exit} s&&/^### /{count++} END{print count+0}' "plans/{slug}.md")
```

Return to Step 2 and re-run integration tests.

**If tests pass**:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" done \
  "integration tests passed after fix"
```
Stop.

**If tests still fail**:
- If `attempt < 2`: loop back to Step 3 to categorize the new failure.
- If `attempt >= 2`:
  Append `[BLOCKED] integration tests failed after 2 fix attempts — manual review required` to `## Open Questions`. Do not set phase `done`.
