---
name: writing-tests
description: >
  Writes failing tests (Red phase) for every scenario in an approved spec.md. Trigger after spec is approved and the user says "write the tests", "write failing tests", "Red phase", or "start TDD". Do not write any implementation code — tests must fail.
---

# Writing Failing Tests

## Step 1 — Read Spec and Structure (plan mode)

Use `EnterPlanMode`, then:
- `Read` the project `CLAUDE.md` to extract the test command
- `Read` the target `spec.md` in full
- `Glob` `src/` to find existing file structure and naming conventions
- `Grep` for existing test patterns to match the project's test style

Mocking levels to apply:
- Domain test → no mocks, no external dependencies
- Small feature test → mock the domain layer only
- Large feature test → mock small features; domain not called directly
- Integration test (`tests/integration/`) → no mocks; run at milestones

## Step 2 — Propose Test Plan

Write to plan file — one entry per `Scenario`:

```
Scenario: {name}
  File: {exact test file path}
  Mock: {what is mocked, or "none"}
  Name: "should {outcome} when {condition}"
```

Call `ExitPlanMode` to request approval.

## Step 3 — Write Failing Tests

Use `TaskCreate` to track progress:

```
TaskCreate([
  { content: "Write tests for {scenario}", status: "pending" },
  ...
])
```

Write each test per the approved plan. Each test must:
- Map directly to one `Scenario`
- Apply the correct mocking level
- Use the name form `"should {outcome} when {condition}"`
- Contain no implementation logic

Mark each task `in_progress` before writing, `completed` after.

After writing all tests, run the test command read from project CLAUDE.md.

Every test must fail. Flag any that pass — rewrite them.

## Step 4 — Run critic-test

```
Task(
  subagent_type: "critic-test",
  prompt: "Review tests at [paths] against spec at [path].
           Test command: [command from project CLAUDE.md]."
)
```

If Critic returns FAIL:
1. Output the full verdict to the user
2. Write a fix plan (which tests to rewrite, which scenarios to add, which mocking to fix)
3. Use `AskUserQuestion` to confirm the fix plan before editing
4. Apply fixes with `Edit`
5. Re-run `critic-test` via `Task` with the same test paths, spec path, and test command
