---
name: critic-test
description: >
  Review failing tests for scenario coverage and correct mocking levels.
  Trigger: after writing-tests completes, before implementing starts.
user-invocable: false
context: fork
agent: critic-test
allowed-tools: [Read, Glob, Bash]
effort: high
paths: ["src/**", "tests/**", "docs/**", "plans/**"]
---

@reference/critics.md

Read the test files and spec.md at the paths provided. Run the test command given in the prompt.

## Pre-check: test file integrity (if called during or after implement phase)

If git is available, run:
```bash
git log --grep='^test(red):' --format='%H %s' -- <test file path(s) from prompt> | head -1
```
This finds the Red-phase commit (identified by the `test(red):` commit message prefix written by `writing-tests`). Then run:
```bash
git log --oneline <red-commit-sha>..HEAD -- <test file path(s) from prompt>
```
If this returns any commits, the test file was modified after the Red phase commit.
If no `test(red):` commit exists for the file, fall back to:
```bash
git log --oneline HEAD -- <test file path(s) from prompt>
```
and treat the oldest commit touching the file as the Red commit.

If **no commits at all** exist for the file (new file not yet committed, pre-commit flow):
```
[SKIP] test file integrity: no commit history found for {file} — cannot verify Red-phase baseline
```
Continue to the Checks section; do not fail on missing history alone.

If **git is not available** in this environment:
```
[SKIP] test file integrity: git unavailable — cannot verify Red-phase commit
```
Continue to the Checks section.

If any test file was modified after the Red phase commit, emit immediately:

```
[CRITICAL] test file modified after Red phase: {file} — FAIL
<!-- verdict: FAIL -->
<!-- category: TEST_INTEGRITY -->
```
and stop. Do not proceed to other checks.

## Checks

**1. Scenario coverage**
- Every `Scenario` has a corresponding test? (→ `[MISSING]` if not)
- Every `Scenario Outline` row covered?
- Failure scenarios tested, not just happy path?

**2. Mocking levels** — table: @reference/layers.md §Test mocking levels; each Violation column entry → `[FAIL]`

**3. Test quality**
- Each test maps to exactly one `Scenario`
- Names follow `"should {outcome} when {condition}"`
- No implementation logic inside tests (→ `[FAIL]` if found)

**4. Confirm all tests fail**

Run the test command from the prompt. Every newly written test must fail.

Exception: a test marked `GREEN (pre-existing)` in the Test Manifest is allowed to pass — it means existing code already satisfies the scenario.

**Independent git verification of GREEN (pre-existing) entries**: for each test file listed as `GREEN (pre-existing)` in the Test Manifest, verify using git that the file predates the current Red-phase commit:

```bash
# Find the test(red): commit for this feature
red_commit=$(git log --grep='^test(red):' --format='%H %at' | head -1 | awk '{print $2}')
# For each GREEN (pre-existing) file, find its creation commit timestamp
create_ts=$(git log --follow --diff-filter=A --format='%at' -- "$test_file" | tail -1)
# If create_ts >= red_commit_ts: the file was created in or after the Red phase — not pre-existing
```

If a file claimed as `GREEN (pre-existing)` was first committed at or after the `test(red):` commit timestamp, emit:
```
[FAIL] category: TEST_INTEGRITY — {file}: marked GREEN (pre-existing) but was created in the Red phase commit; existing code did not pre-exist
```

If git is unavailable or the `test(red):` commit cannot be found, emit `[SKIP] GREEN integrity check: {reason}` and continue.

Flag any test that passes but is NOT marked `GREEN (pre-existing)` in the Test Manifest (→ `[FAIL]`).

## Output format

```
## critic-test Review

### Coverage Gaps
[MISSING] Scenario "{name}": no test found
None: "All scenarios covered"

### Mocking Issues
[FAIL] {test file}:{line} — {wrong pattern}: {correct pattern}
None: "All mocking levels correct"

### Failing Confirmation
All newly written tests fail: YES / NO
Passing tests not marked GREEN (pre-existing): {list or "none"}
GREEN (pre-existing) tests confirmed: {list or "none"}
GREEN integrity violations (created in Red phase): {list or "none"}
```

Verdict & blocking rules: @reference/critics.md §Verdict format. On FAIL blocks progress to `implementing`.

Category mapping (per `@reference/severity.md §Category priority`):

| Check | Category |
|-------|----------|
| Test file modified after Red / GREEN (pre-existing) violation (Pre-check, Check 4) | `TEST_INTEGRITY` |
| Mocking level violation (Check 2 — `layers.md §Test mocking levels`) | `LAYER_VIOLATION` |
| Scenario coverage gap — missing test (Check 1) | `MISSING_SCENARIO` |
| Test maps multiple scenarios / implementation logic in tests / naming (Check 3) | `TEST_QUALITY` |

When multiple FAILs fire, pick the highest-priority category per `@reference/severity.md §Category priority`.
