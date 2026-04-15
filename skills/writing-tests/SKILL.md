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
---

# Writing Failing Tests

Layer rules: @reference/layers.md

## Step 1 — Read plan file + spec

Read `plans/{slug}.md` (resume context after `/compact`). Confirm Phase is `spec`.

**Batch mode exception** — In batch mode (`--profile greenfield` or explicit `--batch`), the
orchestrator writes all specs first and then all tests. When writing tests for feature 2+, the
plan phase may already be `red` (set by the previous feature's tests). This is expected. If the
phase is `red` on entry and you are writing tests for a feature whose spec was written during the
current batch run (verify by checking `## Critic Verdicts` for a `critic-spec: PASS` for this
feature):
1. Append a phase transition entry to `## Phase Transitions` (preserve existing verdicts).
2. Continue from Step 2 — do NOT re-run writing-spec.

If the phase is `red` and no `critic-spec: PASS` verdict exists for this feature, stop and
report: "Phase is `red` but no spec verdict found for this feature — run writing-spec first."

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
- **Non-interactive** (`CLAUDE_NONINTERACTIVE=1`): skip `ExitPlanMode` — run:
  ```bash
  bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" record-auto-approved "plans/{slug}.md" PLAN writing-tests "test plan auto-approved"
  ```
  and proceed directly to Step 3.

## Step 3 — Write failing tests

Create tasks to track progress:

```
TaskCreate: "Write tests for {scenario 1}"
TaskCreate: "Write tests for {scenario 2}"
...
```

Set plan file phase to `red` before writing any test files:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" red
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

Update `## Test Manifest` with file:test_name → RED or GREEN (pre-existing) for each test.

After all tests are written, commit the red tests:
```
git add {test files}
git commit -m "test(red): {scenario summary}"
```
This preserves the Red state across session interruptions.

## Phase rollback

If re-entering `writing-tests` from a later phase (e.g., multi-feature slice mode where the previous
feature's implementing left the plan at `green`, or a bug requires tests to be rewritten):

1. Preserve all existing `## Critic Verdicts` — do not delete them.
2. Append a phase transition entry to `## Phase Transitions`:
   ```
   - {previous-phase} → red (reason: {one sentence})
   ```
3. Step 3 already sets the plan phase to `red` at the start of the step (before writing test
   files); the plan-file phase check in Step 1 ("Confirm Phase is `spec`") is satisfied once
   writing-spec has run for the current feature and set the phase to `spec` via its own rollback.

If the plan phase is `green` when this skill starts (previous feature completed in slice mode):
- writing-spec for the current feature will have already rolled back to `spec` (see writing-spec
  Phase rollback section) before writing-tests is invoked. By the time writing-tests runs, the
  phase will be `spec`. ✓

## Step 4 — Run critic-test (convergence loop)

Full protocol: @reference/critic-loop.md

```
Skill("critic-test", "Review tests at [paths] against spec at [path]. Test command: [command].")
```

After each run, `plan-file.sh record-verdict` fires automatically (SubagentStop hook). Read `## Open Questions` for `critic-test` markers in priority order:

| Marker | Action |
|--------|--------|
| `[BLOCKED-CEILING] critic-test` | Stop — manual review required |
| `[BLOCKED-CATEGORY] critic-test` | Stop — fix root cause first |
| `[BLOCKED-AMBIGUOUS] critic-test: …` | Stop — human decision needed |
| `[BLOCKED-PARSE] critic-test` | Stop — check critic output format before retrying |
| `[CONVERGED] critic-test` | Proceed to Step 5 |
| `[FIRST-TURN] critic-test` | Ask user (interactive) or append `[AUTO-APPROVED-FIRST] critic-test` (non-interactive), then re-run |
| PARSE_ERROR (no `[BLOCKED-PARSE]` yet) | Re-run automatically (second consecutive PARSE_ERROR triggers `[BLOCKED-PARSE]`) |
| PASS, no `[CONVERGED]` yet | Re-run automatically |
| FAIL | Apply fix, then re-run |
