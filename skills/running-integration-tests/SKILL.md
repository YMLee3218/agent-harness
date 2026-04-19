---
name: running-integration-tests
description: >
  Run end-to-end integration tests (no mocks, real connections).
  Invoked by running-dev-cycle after all features complete, or manually via `/running-integration-tests`.
  Handles failures by auto-invoking writing-spec, writing-tests, or implementing as appropriate.
disable-model-invocation: true
---

**Non-interactive handling** (`CLAUDE_NONINTERACTIVE=1`): replace every `AskUserQuestion` per `@reference/non-interactive-mode.md §AskUserQuestion replacement`. `[BLOCKED] {description}` goes to `## Open Questions` when decision is required; `[AUTO-DECIDED] {decision}` when skill may proceed.

# Integration Testing

## Scope

Default test path: `tests/integration/**`. Override per project via `PHASE_GATE_TEST_GLOB` if your layout differs.

Invocable via `/running-integration-tests` or automatically by `running-dev-cycle`.

## When to run

- Major features completed (milestone boundary)
- Before deployment
- User explicitly requests

## Step 1 — Identify scope

@reference/non-interactive-mode.md §EnterPlanMode / ExitPlanMode

- `Read` `docs/requirements/*.md` to determine which features are in scope
- `Glob` `tests/integration/` to find existing integration tests
- `Read` project `CLAUDE.md` for the integration test command

Write scope summary to plan file.

- **Interactive**: call `ExitPlanMode` to request approval.
- Non-interactive: @reference/non-interactive-mode.md §ExitPlanMode replacement — proceed to Step 1.5.

## Step 1.5 — Verify unit tests pass

Before running integration tests, run the unit test command from project CLAUDE.md to confirm there are no pre-existing regressions.

If unit tests fail:
- **Interactive**: use `AskUserQuestion` — "Unit tests are failing before integration tests start. Resolve via `implementing` skill before proceeding? Failures: [{list}]". After confirmation:
  1. Roll back phase so `implementing` can enter with fresh task planning:
     ```bash
     # reset-for-rollback: sets phase to implement, clears critic-code and pr-review markers
     # across both implement and review scopes. See @reference/critics.md §Full rollback reset.
     bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-for-rollback "plans/{slug}.md" implement
     # Set to red so implementing Step 1 triggers fresh task planning (not Session Recovery)
     bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" red \
       "unit tests failing at integration entry — fresh task planning needed"
     ```
  2. Invoke `Skill("implementing")`, then return to Step 2.
- Non-interactive: `[BLOCKED] unit tests failing before integration tests — resolve via /implementing before re-running`. Do not proceed to Step 2.

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
2. Determine the failure category:

**docs conflict** — implementation contradicts documented domain rules:
→ Update `docs/*.md` (SOT) first
→ Automatically invoke `writing-spec` skill for the affected feature
→ Then invoke `writing-tests` and `implementing` as needed

**spec gap** — scenario not covered in existing specs:
→ Automatically invoke `writing-spec` skill for the affected feature
→ Then invoke `writing-tests` and `implementing` as needed

**implementation bug** — spec is correct but code does not match:
→ Automatically invoke `implementing` skill for the affected feature

3. Confirm the failure category:
   - **Interactive**: use `AskUserQuestion` — "Integration test failed: [{test name}]. Category: docs conflict / spec gap / implementation bug? I will invoke {skill name} automatically after you confirm."
   - Non-interactive: infer the category from failure evidence. If unambiguous, proceed and log `[AUTO-CATEGORIZED-INTEGRATION] {test name}: {category}` to `## Integration Failures`. If ambiguous, `[BLOCKED-INTEGRATION] {test name}: cannot determine category automatically — manual review required`.

4. After confirmation (or auto-categorization), set the rollback phase first, then reset convergence state, then invoke the fix skill:
   ```bash
   # transition records the audit entry (from → to + reason).
   # docs conflict or spec gap → rollback to spec; implementation bug → rollback to implement
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" {rollback-phase} \
     "{one sentence reason}"
   # reset-for-rollback: sets phase (idempotent after transition), resets critic-code + pr-review
   # markers, and clears stale review-scoped critic-code markers.
   # See @reference/critics.md §Full rollback reset.
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-for-rollback "plans/{slug}.md" {rollback-phase}
   ```
   Then invoke the appropriate skill via `Skill(...)`.

## Step 4 — Re-run after fix (max 2 re-run attempts)

After the fix skill completes, increment the **persistent** re-run counter and capture the new count:
```bash
attempt=$(bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" record-integration-attempt "plans/{slug}.md")
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
  - **Interactive**: use `AskUserQuestion` — "Integration tests failed after 2 fix attempts. Failures: [{list}]. How should we proceed?"
  - Non-interactive: `[BLOCKED] integration tests failed after 2 fix attempts — manual review required`. Do not set phase `done`.

The counter is stored in `plans/{slug}.state.json` and survives `/compact` and session restarts.
To read the current count without incrementing: `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" get-integration-attempts "plans/{slug}.md"`
