---
name: writing-tests
description: >
  Write failing Red-phase tests for every Scenario in an approved spec.md.
  Trigger: "write the tests", "write failing tests", "Red phase", "start TDD", after spec is approved.
  Never writes implementation code — all tests must fail.
disable-model-invocation: true
effort: medium
paths:
  - tests/**
  - plans/**
  - features/**
  - domain/**
---

# Writing Failing Tests

## Step 1 — Read plan file + spec

Phase entry protocol: @reference/phase-ops.md §Skill phase entry — expected phases: `spec`, `red` (re-entry).

Phase entry:
- Phase `spec`: proceed normally.
- Phase `red` + `critic-spec: PASS` in `## Critic Verdicts`: skip to Step 2 (no transition needed).
- Phase `red` without `critic-spec: PASS`, or any other phase: `[BLOCKED] writing-tests entered from unexpected phase {phase} — critic-spec PASS required; re-run writing-spec`.

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

Proceed directly to Step 3.

## Step 3 — Write failing tests

Create tasks to track progress:

```
TaskCreate: "Write tests for {scenario 1}"
TaskCreate: "Write tests for {scenario 2}"
...
```

Set plan file phase to `red` before writing any test files:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" red \
  "approved plan — writing failing tests"
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
3. Skip the implement phase for that test — it does not need implementing

Tests that pass due to incomplete test logic (e.g. empty assertions, wrong subject) must still be rewritten to fail properly.

Update `## Test Manifest` with file:test_name → RED or GREEN (pre-existing) for each test.

After all tests are written, commit the red tests:
```
git add {test files}
git commit -m "test(red): {scenario summary}"
```
This preserves the Red state across session interruptions.

## Phase rollback

@reference/phase-ops.md §Phase Rollback Procedure — `{target-phase}` = `red`, `{critic-name}` = `critic-test`, `{skill-name}` = `writing-tests`.

When phase is `green` on entry: `writing-spec` will have already rolled back to `spec` before `writing-tests` runs — the Step 1 phase check will pass. ✓

## Step 4 — Run critic-test (convergence loop)

Reset the critic-test milestone before running (clears stale `[CONVERGED] red/critic-test` and `[FIRST-TURN]` markers from any prior run, and adds a `[MILESTONE-BOUNDARY]` so prior-run verdicts do not inflate the new streak):
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "plans/{slug}.md" critic-test
```

Run @reference/critics.md §Invocation recipe with agent=`critic-test`, phase=`red`, prompt="Review tests at [paths] against spec at [path]. Test command: [command]."
