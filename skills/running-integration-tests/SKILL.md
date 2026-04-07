---
name: running-integration-tests
description: >
  Run end-to-end integration tests (no mocks, real connections).
  Trigger: "integration test", "e2e test", "end-to-end", before deployment, at major feature milestones.
  Handles failures by auto-invoking writing-spec, writing-tests, or implementing as appropriate.
disable-model-invocation: true
paths:
  - "tests/integration/**"
---

# Integration Testing

User-invocable only via `/running-integration-tests`.

## When to run

- Major features completed (milestone boundary)
- Before deployment
- User explicitly requests

## Step 1 — Identify scope

Use `EnterPlanMode`, then:
- `Read` `docs/requirements/*.md` to determine which features are in scope
- `Glob` `tests/integration/` to find existing integration tests
- `Read` project `CLAUDE.md` for the integration test command

Write scope summary to plan file. Call `ExitPlanMode` to request approval.

## Step 2 — Run tests

Execute the integration test command from project CLAUDE.md.

No mocks — real domain + feature + infrastructure connections.

Update plan file Phase to `integration`.

## Step 3 — Handle failures

If tests pass: update plan file Phase to `done`. Done.

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

3. Use `AskUserQuestion` to confirm the failure category before auto-invoking the skill:
   "Integration test failed: [{test name}]. Category: docs conflict / spec gap / implementation bug?
   I will invoke {skill name} automatically after you confirm."

4. After confirmation, invoke the appropriate skill via `Skill(...)`.

5. Append to `## Phase Transitions` in the plan file:
   ```
   - integration → {rollback-phase} (reason: {one sentence})
   ```
