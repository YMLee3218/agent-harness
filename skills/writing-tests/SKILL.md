---
name: writing-tests
description: >
  Write failing Red-phase tests for every Scenario in an approved spec.md.
  Trigger: "write the tests", "write failing tests", "Red phase", "start TDD", after spec is approved.
  Never writes implementation code — all tests must fail.
effort: medium
paths:
  - tests/**
  - plans/**
  - features/**
  - domain/**
---

**Non-interactive handling** (`CLAUDE_NONINTERACTIVE=1`): replace every `AskUserQuestion` per `@reference/non-interactive-mode.md §AskUserQuestion replacement`. `[BLOCKED] {description}` goes to `## Open Questions` when decision is required; `[AUTO-DECIDED] {decision}` when skill may proceed.

# Writing Failing Tests

## Step 1 — Read plan file + spec

Phase entry protocol: @reference/critics.md §Skill phase entry — expected phases: `spec`, `red` (re-entry).

**Phase `red` on entry** — Two cases where phase is already `red` when this skill starts:

- **Batch mode**: In batch mode (`--profile greenfield` or explicit `--batch`), the orchestrator
  writes all specs first and then all tests. Phase was set to `red` by the previous feature's tests.
- **Phase-rollback re-entry**: `§Phase rollback` (below) resets phase to `red` when tests need
  rewriting. The plan file already has a `critic-spec: PASS` from the original spec writing run.

In both cases, verify by checking `## Critic Verdicts` for a `critic-spec: PASS` for this feature.
If found:
1. Continue from Step 2 — do NOT re-run writing-spec. (No phase transition to record — phase is already `red`.)

If the phase is `red` and no `critic-spec: PASS` verdict exists for this feature, stop and
report: "Phase is `red` but no spec verdict found for this feature — run writing-spec first."

If the phase is neither `spec` nor `red`, append `[BLOCKED] writing-tests entered from unexpected phase {phase} — run writing-spec first` to `## Open Questions` and stop.

@reference/non-interactive-mode.md §EnterPlanMode / ExitPlanMode

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

Call `ExitPlanMode` to request approval (interactive only).
- Non-interactive: @reference/non-interactive-mode.md §ExitPlanMode replacement — proceed directly to Step 3.

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

Triggered when re-entering from a later phase (slice mode or tests need rewriting).

Apply @reference/critics.md §Phase Rollback Procedure with `{target-phase}` = `red`, `{critic-name}` = `critic-test`, `{skill-name}` = `writing-tests`.

When phase is `green` on entry: `writing-spec` will have already rolled back to `spec` before `writing-tests` runs — the Step 1 phase check will pass. ✓

## Step 4 — Run critic-test (convergence loop)

Full protocol: @reference/critics.md §Loop convergence

```
Skill("critic-test", "Review tests at [paths] against spec at [path]. Test command: [command].")
```

After each run, follow @reference/critics.md §Running the critic and @reference/critics.md §Skill branching logic, substituting `critic-test` for `{agent}`.

On `[CONVERGED] {phase}/critic-test`: writing-tests phase done; proceed to `implementing` (if invoked via `running-dev-cycle`, it advances automatically).
