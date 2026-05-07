# Severity Rules

Imported via `@reference/critics.md` by all five critic skills.
Defines how to map finding labels to severity levels, when to emit PASS vs FAIL, and how to choose a category when multiple findings apply.

## Severity levels

| Level | Label | Blocks FAIL? | Description |
|-------|-------|:---:|---|
| **Critical** | `[CRITICAL]` | Yes | Correctness violation: wrong layer import, broken invariant, spec scenario not exercised |
| **Missing** | `[MISSING]` | Yes | Required element absent: missing boundary scenario, missing test, missing docs entry |
| **Manifest gap** | `[MANIFEST-GAP]` | Yes | Scenario covered by pre-existing test but Test Manifest mapping is absent |
| **Fail** | `[FAIL]` | Yes | Structural violation: BDD format error, naming convention broken, test maps multiple scenarios |
| **Docs contradiction** | `[DOCS CONTRADICTION]` | Yes | Code or spec contradicts `docs/*.md` (source of truth) |
| **Unverified** | `[UNVERIFIED CLAIM]` | Yes | Factual claim not grounded in docs/*.md, context7, or verified source |
| **Warning** | `[WARN]` | No | Non-blocking improvement suggestion; must not cause a FAIL verdict by itself |

## PASS/FAIL threshold

| Verdict | Condition |
|---------|-----------|
| **PASS** | Zero `[CRITICAL]`, `[MISSING]`, `[MANIFEST-GAP]`, `[FAIL]`, `[DOCS CONTRADICTION]`, or `[UNVERIFIED CLAIM]` findings |
| **FAIL** | One or more blocking-level findings |
| **PASS with warnings** | Only `[WARN]` findings present — still emits PASS |

## Category priority (highest → lowest)

When a single FAIL contains findings from multiple categories, use the **highest-priority** category for the `<!-- category: X -->` marker so the consecutive-FAIL escalation logic tracks the most severe issue:

```
LAYER_VIOLATION
  > CROSS_FEATURE_CONTRADICTION
  > DOCS_CONTRADICTION
  > UNVERIFIED_CLAIM
  > SPEC_COMPLIANCE
  > MISSING_SCENARIO
  > TEST_INTEGRITY
  > TEST_QUALITY
  > STRUCTURAL
```

## Boundary-case guidance

| Situation | Decision |
|-----------|----------|
| `[WARN]` only, no blocking findings | Emit PASS; list `[WARN]` items in the report for awareness |
| Multiple `[MISSING]` in same category | Single FAIL with category `MISSING_SCENARIO`; list all missing items |
| Both `LAYER_VIOLATION` and `SPEC_COMPLIANCE` findings | Use `LAYER_VIOLATION` (higher priority); mention both in the verdict |
| `[DOCS CONTRADICTION]` with no other findings | Emit FAIL with category `DOCS_CONTRADICTION`; do not auto-resolve — follow `@reference/phase-ops.md §DOCS CONTRADICTION cascade` |
| `[MANIFEST-GAP]` only | Emit FAIL with category `STRUCTURAL`; fix = add mapping to `## Test Manifest` in the plan file |
| Test passes before any implementation exists | `TEST_INTEGRITY` — always FAIL regardless of other findings |
| Typo in a scenario name (cosmetic only) | `[WARN]`, not `[FAIL]` — does not block |

