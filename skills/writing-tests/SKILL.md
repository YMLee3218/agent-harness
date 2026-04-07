---
name: writing-tests
description: >
  Writes failing tests (Red phase) for every scenario in an approved spec.md. Trigger after spec is
  approved and the user says "write the tests", "write failing tests", "Red phase", or "start TDD".
  Do not write any implementation code — tests must fail.
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

**Expected state:** every newly written test should fail (Red phase).

**Exception — existing implementation already satisfies a scenario:** if a test passes immediately and the scenario is already fully handled by existing code, do NOT force it to fail. Instead:
1. Mark it `GREEN (pre-existing)` in `## Test Manifest`
2. Note it in `## Open Questions` so the user can confirm the existing behaviour is intentional
3. Skip the Green phase for that test — it does not need implementing

Tests that pass due to incomplete test logic (e.g. empty assertions, wrong subject) must still be rewritten to fail properly.

Update plan file Phase to `red`. Update `## Test Manifest` with file:test_name → RED or GREEN (pre-existing) for each test.

After all tests are written, commit the red tests:
```
git add {test files}
git commit -m "test(red): {scenario summary}"
```
This preserves the Red state across session interruptions.

## Step 4 — Run critic-test (max 2 iterations)

Iteration protocol: @reference/critic-loop.md

```
Skill("critic-test", "Review tests at [paths] against spec at [path]. Test command: [command].")
```
