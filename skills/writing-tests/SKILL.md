---
name: writing-tests
description: >
  Write failing Red-phase tests for every Scenario in an approved spec.md.
  Trigger: "write the tests", "write failing tests", "Red phase", "start TDD", after spec is approved.
  Never writes implementation code — all tests must fail.
  Do NOT trigger automatically — only on explicit user request or when called by running-dev-cycle.
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

Phase entry protocol: @reference/phase-ops.md §Skill phase entry — expected phase: `red`.

Phase entry:
- Phase `red`: proceed. The harness (dev-cycle-phases.sh `_impl_run_test_phase`) transitions spec→red before invoking this skill, so `red` is always the entry phase in autonomous mode. In interactive use, ensure the plan is in `red` before invoking.
- Any other phase: `[BLOCKED:env] writing-tests: unexpected-phase — entered from {phase}; plan must be in red phase; run brainstorming→writing-spec→critic-spec first`.

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

Build a Codex prompt that references the spec and test plan by path, and substitutes the test command. Use the bash block below as-is — do not modify any values.

```bash
_boot=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null) || _boot="${CLAUDE_PROJECT_DIR:-$(pwd)}"
source "$_boot/.claude/scripts/lib/run-context.sh" && _resolve_project_dir
_spec_path="${WRITING_TESTS_SPEC_PATH:?WRITING_TESTS_SPEC_PATH not set}"
_plan_path="${WRITING_TESTS_PLAN_PATH:?WRITING_TESTS_PLAN_PATH not set}"
_test_command="${WRITING_TESTS_COMMAND:?WRITING_TESTS_COMMAND not set}"
_tw_template=$(mktemp /tmp/test-writer-tmpl.XXXXXX)
_codex_prompt=$(mktemp /tmp/test-writer-prompt.XXXXXX)
_codex_log=$(mktemp /tmp/test-writer-log.XXXXXX)
cat > "$_tw_template" <<'CODEX_PROMPT'
Task: write Red-phase failing tests for every Scenario in the spec below.

Spec: {spec_path}
Test plan (read ## Test Plan section from the plan file): {plan_path}

Mocking levels per layer: read ${PROJECT_DIR}/.claude/reference/layers.md §Test mocking levels

Hard constraints:
- Each test maps to exactly one Scenario.
- Test name form: "should {outcome} when {condition}".
- Apply the mocking level dictated by the test's layer — no exceptions.
- No implementation logic inside tests.
- Write tests only at the test file paths listed in the plan; do not create files elsewhere.
- Every newly written test must FAIL when the test command runs. The only exception is a scenario already fully satisfied by existing code AND the test is being added to a test file that predates this Red-phase commit — in that case leave the test asserting the real behaviour and tag it GREEN_PRE_EXISTING in a trailing comment on the test. If the test file itself is newly created in the Red phase, ALL tests in it must FAIL (critic-test rejects GREEN_PRE_EXISTING in new files).

After writing all tests, run: {test_command}
Print the test results, then for each test file you created or modified emit one line:
  TEST_OUTCOME: {file}::{test_name} -> RED | GREEN_PRE_EXISTING
End with: === TEST-WRITER DONE ===
CODEX_PROMPT
sed \
  -e "s|{spec_path}|${_spec_path}|g" \
  -e "s|{plan_path}|${_plan_path}|g" \
  -e "s|{test_command}|${_test_command}|g" \
  "$_tw_template" > "$_codex_prompt"
rm -f "$_tw_template"
codex exec --full-auto - < "$_codex_prompt" > "$_codex_log" 2>&1
_codex_exit=$?
echo "=== Codex exit: $_codex_exit ==="
tail -200 "$_codex_log"
rm -f "$_codex_prompt" "$_tw_template" "$_codex_log"
```

## Step 4 — Verify and record

Parse the tail for `TEST_OUTCOME:` lines. For each:
- `RED` → record in `## Test Manifest` as `{file}::{test_name} → RED`.
- `GREEN_PRE_EXISTING` → record as `{file}::{test_name} → GREEN (pre-existing)` and append a `## Open Questions` note so the user can confirm the existing behaviour is intentional. Skip implement for these.

If the tail is missing `=== TEST-WRITER DONE ===`, retry once with `RETRY: previous run did not complete; finish all scenarios and emit the done sentinel.` appended. If the second run also fails, write `[BLOCKED:code] test-writer: codex-incomplete — Codex did not complete` and stop.

If any test claimed `RED` actually passed (rerun the test command yourself once to confirm), retry once with the failing-test names appended and the instruction `RETRY: these tests must be rewritten to FAIL — they currently pass without implementation`. Tests that pass due to wrong subject or empty assertions must be rewritten, not relabelled.

Then commit:
```
git add {test files}
git commit -m "test(red): {scenario summary}"
```
This preserves the Red state across session interruptions.

## Phase rollback

@reference/phase-ops.md §Phase Rollback Procedure — `{target-phase}` = `red`, `{critic-name}` = `critic-test`.
