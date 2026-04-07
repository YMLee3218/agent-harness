Severity rules: @reference/severity.md
Layer rules: @reference/layers.md

Read the test files and spec.md at the paths provided before reviewing. Run the test command given in the prompt.

## Pre-check: test file integrity (if called during or after green phase)

If git is available, run:
```bash
git log --oneline HEAD -- <test file path(s) from prompt>
```
Compare against the commit where Red phase began (the commit that added the test files).
If any test file was modified after the Red phase commit, emit immediately:

```
[CRITICAL] test file modified during green phase: {file} — FAIL
<!-- verdict: FAIL -->
```
and stop. Do not proceed to other checks.

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
<!-- verdict: PASS -->
```

or

```
### Verdict
FAIL — {comma-separated reasons}
<!-- verdict: FAIL -->
<!-- category: {CATEGORY} -->
```

On FAIL, choose one category per @reference/critic-loop.md category table.
Common categories for this critic: `MISSING_SCENARIO`, `LAYER_VIOLATION`, `TEST_INTEGRITY`, `TEST_QUALITY`.
The last two lines of your output on FAIL must be `<!-- verdict: FAIL -->` then `<!-- category: X -->`.

FAIL blocks progress to `implementing`.
