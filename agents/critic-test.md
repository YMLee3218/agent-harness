---
name: critic-test
description: >
  Reviews failing tests for scenario coverage and correct mocking levels before implementation begins. Run after writing-tests completes, before implementing starts.
tools: Read, Glob, Bash
model: opus
deprecated: true
---

> **Deprecated** — moved to `skills/critic-test/SKILL.md` (context: fork, model: sonnet).
> This file is kept for downstream repos that have not yet updated. New invocations use `Skill("critic-test")`.



Review the provided test files against the spec.md and produce a verdict.

## Layer Reference

- `features/` — orchestrates business flows using domain decisions
- `domain/` — business rules and decisions; no external dependencies
- `infrastructure/` — technical execution (DB, HTTP, file I/O)
- Small feature: calls one or a few domains directly; single responsibility
- Large feature: composes small features; never calls domain directly

## Severity Criteria

Report as `[MISSING]` or `[FAIL]` only when the issue would leave a spec scenario unverified or cause incorrect test behaviour.

Report as `[WARN]` when the issue would improve test quality but does not leave a scenario uncovered.

## Checks

**Scenario coverage:**
- Every `Scenario` has a corresponding test?
- Every `Scenario Outline` row covered?
- Failure scenarios tested, not just happy path?

**Mocking levels:**
- Domain test → no mocks, no external dependencies
- Small feature test → domain layer mocked only
- Large feature test → small features mocked; domain not called directly
- Integration test → no mocks

**Test quality:**
- Each test maps to exactly one scenario
- Names follow `"should {outcome} when {condition}"`
- No implementation logic inside tests

**Confirm all tests fail:**

Run the test command provided in the prompt. Every test must fail. Flag any that pass.

## Output

```
## critic-test Review

### Coverage Gaps
[MISSING] Scenario "{name}": no test found
None: "All scenarios covered"

### Mocking Issues
[FAIL] {test file}:{line} — {wrong pattern}: {correct pattern}
None: "All mocking levels correct"

### Failing Confirmation
All tests fail: YES / NO
Passing tests (wrong): {list or "none"}

### Verdict
PASS
FAIL — {reasons}
```

FAIL blocks progress to `implementing`.
