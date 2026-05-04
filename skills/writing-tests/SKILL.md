---
name: writing-tests
description: >
  Write failing Red-phase tests for every Scenario in an approved spec.md.
  Trigger: "write the tests", "write failing tests", "Red phase", "start TDD", after spec is approved.
  Never writes implementation code — all tests must fail.
  Do NOT trigger automatically — only on explicit user request or when called by running-dev-cycle.
effort: medium
context: fork
agent: test-writer
paths:
  - tests/**
  - plans/**
  - features/**
  - domain/**
  - infrastructure/**
  - src/**
---

# Writing Failing Tests

## Step 1 — Read plan file + spec

Phase entry protocol: @reference/phase-ops.md §Skill phase entry — expected phases: `spec`, `red` (re-entry).

Phase entry:
- Phase `spec`: proceed normally.
- Phase `red` + `[CONVERGED] spec/critic-spec` in `## Open Questions`: skip to Step 2 (no transition needed).
- Phase `red` without `[CONVERGED] spec/critic-spec`, or any other phase: `[BLOCKED] writing-tests entered from unexpected phase {phase} — critic-spec convergence required; re-run writing-spec`.

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

## Step 3 — Delegate test writing to Codex

Set plan file phase to `red` (skip if already in `red` — do not re-transition to the same phase; see `@reference/phase-ops.md §Skill phase entry`):
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" red \
  "approved plan — writing failing tests"
```

Build a Codex prompt that folds in the full spec, the test plan from Step 2, and hard constraints. Use the Write tool to create the prompt file:

```
Task: write Red-phase failing tests for every Scenario in the spec below.

Spec (verbatim):
{paste full contents of spec.md}

Test plan (one entry per Scenario, from Step 2):
{paste the Step 2 plan entries}

Mocking levels per layer (verbatim from reference/layers.md §Test mocking levels):
{paste the mocking level table}

Hard constraints:
- Each test maps to exactly one Scenario.
- Test name form: "should {outcome} when {condition}".
- Apply the mocking level dictated by the test's layer — no exceptions.
- No implementation logic inside tests.
- Write tests only at the test file paths listed in the plan; do not create files elsewhere.
- Every newly written test must FAIL when the test command runs. The only exception is a scenario already fully satisfied by existing code AND the test is being added to a test file that predates this Red-phase commit — in that case leave the test asserting the real behaviour and tag it GREEN-PRE-EXISTING in a trailing comment on the test. If the test file itself is newly created in the Red phase, ALL tests in it must FAIL (critic-test rejects GREEN-PRE-EXISTING in new files).

After writing all tests, run: {test command}
Print the test results, then for each test file you created or modified emit one line:
  TEST_OUTCOME: {file}::{test_name} -> RED | GREEN_PRE_EXISTING
End with: === TEST-WRITER DONE ===
```

Run Codex; capture the tail only:

```bash
_codex_prompt=$(mktemp /tmp/test-writer-prompt-XXXXXX.txt)
_codex_log=$(mktemp /tmp/test-writer-log-XXXXXX.txt)
# Write the prompt above into "$_codex_prompt" with the Write tool
codex exec --full-auto - < "$_codex_prompt" > "$_codex_log" 2>&1
_codex_exit=$?
echo "=== Codex exit: $_codex_exit ==="
tail -200 "$_codex_log"
rm -f "$_codex_prompt" "$_codex_log"
```

## Step 4 — Verify and record

Parse the tail for `TEST_OUTCOME:` lines. For each:
- `RED` → record in `## Test Manifest` as `{file}::{test_name} → RED`.
- `GREEN_PRE_EXISTING` → record as `{file}::{test_name} → GREEN (pre-existing)` and append a `## Open Questions` note so the user can confirm the existing behaviour is intentional. Skip implement for these.

If the tail is missing `=== TEST-WRITER DONE ===`, retry once with `RETRY: previous run did not complete; finish all scenarios and emit the done sentinel.` appended. If the second run also fails, write `[BLOCKED] test-writer: Codex did not complete` and stop.

If any test claimed `RED` actually passed (rerun the test command yourself once to confirm), retry once with the failing-test names appended and the instruction `RETRY: these tests must be rewritten to FAIL — they currently pass without implementation`. Tests that pass due to wrong subject or empty assertions must be rewritten, not relabelled.

Then commit:
```
git add {test files}
git commit -m "test(red): {scenario summary}"
```
This preserves the Red state across session interruptions.

## Phase rollback

@reference/phase-ops.md §Phase Rollback Procedure — `{target-phase}` = `red`, `{critic-name}` = `critic-test`.
