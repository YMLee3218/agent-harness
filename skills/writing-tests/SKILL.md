---
name: writing-tests
description: >
  Writes failing tests (Red phase) for every scenario in an approved spec.md. Trigger after spec is
  approved and the user says "write the tests", "write failing tests", "Red phase", or "start TDD".
  Do not write any implementation code — tests must fail.
paths:
  - "tests/**"
  - "**/*_test.*"
  - "**/*.test.*"
  - "**/*.spec.*"
---

# Writing Failing Tests

Layer rules: @reference/layers.md

## Step 1 — Read plan file + spec

Read `plans/{slug}.md` (resume context after `/compact`). Confirm Phase is `spec`.

Use `EnterPlanMode`, then:
- `Read` the project `CLAUDE.md` to extract the test command
- `Read` the target `spec.md` in full
- `Glob` `src/` to find existing file structure and naming conventions
- `Grep` for existing test patterns to match project test style

Mocking levels per @reference/layers.md.

## Step 2 — Propose test plan

Write to plan file — one entry per `Scenario`:

```
Scenario: {name}
  File: {exact test file path}
  Mock: {what is mocked, or "none"}
  Name: "should {outcome} when {condition}"
```

Call `ExitPlanMode` to request approval.

## Step 3 — Write failing tests

Create tasks to track progress:

```
TaskCreate: "Write tests for {scenario 1}"
TaskCreate: "Write tests for {scenario 2}"
...
```

Mark each task `in_progress` before writing, `completed` after.

Each test must:
- Map directly to one `Scenario`
- Apply the correct mocking level
- Use the name form `"should {outcome} when {condition}"`
- Contain no implementation logic

After writing all tests, run the test command from project CLAUDE.md.

Every test must fail. Flag any that pass — rewrite them until they fail.

Update plan file Phase to `red`. Update `## Test Manifest` with file:test_name → RED for each test.

## Step 4 — Run critic-test (max 2 iterations)

```
Skill("critic-test", "Review tests at [paths] against spec at [path]. Test command: [command].")
```

**Iteration counter starts at 1.**

If Critic returns FAIL:
1. Output the full verdict
2. Write fix plan (tests to rewrite, missing scenarios, mocking issues)
3. Use `AskUserQuestion` to confirm fix plan
4. Apply fixes with `Edit`
5. If iteration < 2: increment counter, re-run Skill("critic-test"). Else: use `AskUserQuestion` — "critic-test has failed twice. Paste the latest verdict for manual review, or describe how to proceed."

Append verdict to plan file `## Critic Verdicts`.
