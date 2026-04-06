---
name: running-integration-tests
description: >
  Runs end-to-end integration tests with real domain + feature + infrastructure connections. Trigger on "integration test", "e2e test", "end-to-end", or before deployment milestones. Run at milestone boundaries when major features are completed.
disable-model-invocation: true
---

# Integration Testing

## When to Run

- Major features completed (milestone boundary)
- Before deployment
- User explicitly requests

## Step 1 — Identify Scope

Use `EnterPlanMode`, then:
- `Read` `docs/requirements/*.md` to determine which features are in scope
- `Glob` `tests/integration/` to find existing integration tests
- `Read` project `CLAUDE.md` for the test command

Write scope summary to plan file. Call `ExitPlanMode` to request approval.

## Step 2 — Run Tests

Execute the integration test command from project CLAUDE.md.

No mocks — real domain + feature + infrastructure connections.

## Step 3 — Handle Failures

If tests fail:

1. Record the failure in the relevant `docs/requirements/` document
2. Determine the failure category:

**docs conflict** — implementation contradicts documented domain rules
  → Update `docs/*.md` first, then re-enter work cycle at `writing-spec`

**spec gap** — scenario not covered in existing specs
  → Re-enter work cycle at `writing-spec` for the affected feature

**implementation bug** — spec is correct but code does not match
  → Re-enter work cycle at `implementing` for the affected feature

3. Use `AskUserQuestion` to confirm the failure category and re-entry point
4. Direct the user to the appropriate skill
