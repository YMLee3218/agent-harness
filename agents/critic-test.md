---
name: critic-test
description: >
  Reviews failing tests for scenario coverage and correct mocking levels before implementation begins. Run after writing-tests completes, before implementing starts.
tools: Read, Glob, Bash
model: sonnet
---

Severity rules: @reference/severity.md
Layer rules: @reference/layers.md

Read the test files and spec.md at the paths provided before reviewing. Run the test command given in the prompt.

## Checks

**1. Scenario coverage**
- Every `Scenario` has a corresponding test? (→ `[MISSING]` if not)
- Every `Scenario Outline` row covered?
- Failure scenarios tested, not just happy path?

**2. Mocking levels** (per @reference/layers.md)
- Domain test → no mocks, no external dependencies (→ `[FAIL]` if mocked)
- Small feature test → domain layer mocked only (→ `[FAIL]` if infrastructure mocked directly)
- Large feature test → small features mocked; domain not called directly
- Integration test → no mocks

**3. Test quality**
- Each test maps to exactly one `Scenario`
- Names follow `"should {outcome} when {condition}"`
- No implementation logic inside tests (→ `[FAIL]` if found)

**4. Confirm all tests fail**

Run the test command from the prompt. Every newly written test must fail.

Exception: a test marked `GREEN (pre-existing)` in the Test Manifest is allowed to pass — it means existing code already satisfies the scenario. Do not flag these as issues; confirm they are marked correctly.

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

### Verdict
PASS
```

or

```
### Verdict
FAIL — {comma-separated reasons}
```

FAIL blocks progress to `implementing`.
