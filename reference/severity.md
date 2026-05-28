# Severity Rules

Imported via `@reference/critics.md` by all five critic skills.
Defines how to map finding labels to severity levels, when to emit PASS vs FAIL, and how to choose a category when multiple findings apply.

## Core principle

Advisory/non-blocking finding labels do not exist. Every reported finding is blocking. Observations that do not rise to blocking level (cosmetic typos, code style smells) are **not reported** — they are not promoted to a blocking label for visibility.

## Severity levels

| Level | Label | Blocks FAIL? | Description |
|-------|-------|:---:|---|
| **Critical** | `[CRITICAL]` | Yes | Correctness violation: wrong layer import, broken invariant, spec scenario not exercised |
| **Missing** | `[MISSING]` | Yes | Required element absent: missing boundary scenario, missing test, missing docs entry |
| **Manifest gap** | `[MANIFEST-GAP]` | Yes | Scenario covered by pre-existing test but Test Manifest mapping is absent |
| **Fail** | `[FAIL]` | Yes | Structural violation: BDD format error, naming convention broken, test maps multiple scenarios |
| **Docs contradiction** | `[DOCS CONTRADICTION]` | Yes | Code or spec contradicts `docs/*.md` (source of truth) |
| **Unverified** | `[UNVERIFIED CLAIM]` | Yes | Factual claim not grounded in docs/*.md, context7, @reference/*.md, or verified source |

## PASS/FAIL threshold

| Verdict | Condition |
|---------|-----------|
| **PASS** | Zero blocking-level findings |
| **FAIL** | One or more blocking-level findings |

## Category priority (highest → lowest)

When a single FAIL contains findings from multiple categories, use the **highest-priority** category for the `<!-- category: X -->` marker so the consecutive-FAIL escalation logic tracks the most severe issue. The `<!-- category: X -->` marker **must** use one of the enum values below — using a check name, section title, or any other string (e.g. `COMPLETENESS`) is invalid and will be recorded as `PARSE_ERROR`. Observed-invalid examples that MUST NOT be used: `COMPLETENESS`, `CONSISTENCY`, `CORRECTNESS`.

```
ENVELOPE_MISMATCH
  > ENVELOPE_OVERREACH
  > LAYER_VIOLATION
  > CROSS_FEATURE_CONTRADICTION
  > DOCS_CONTRADICTION
  > UNVERIFIED_CLAIM
  > SPEC_COMPLIANCE
  > MISSING_SCENARIO
  > TEST_INTEGRITY
  > TEST_QUALITY
  > STRUCTURAL
```

## Enum-extension escape

**Enum-extension escape**. If a finding's meaning is genuinely not covered by any enum value (not merely a wording question), do **not** invent a new category. Emit the closest-fit category in the verdict (to avoid PARSE_ERROR), and additionally append to `## Open Questions`:
```
[BLOCKED:harness] {critic-name}: reference-extension — category enum has no value covering "{meaning}"; proposed addition: '{value}' ({rationale}). Finding ref: {summary}.
```
Distinct from PARSE_ERROR (verdict-format violation): reference-extension is a request to expand the enum, raised by a critic that found a real issue but no enum value fits.

## Boundary-case guidance

| Situation | Decision |
|-----------|----------|
| Multiple `[MISSING]` in same category | Single FAIL with category `MISSING_SCENARIO`; list all missing items |
| Both `LAYER_VIOLATION` and `SPEC_COMPLIANCE` findings | Use `LAYER_VIOLATION` (higher priority); mention both in the verdict |
| `[DOCS CONTRADICTION]` with no other findings | Emit FAIL with category `DOCS_CONTRADICTION`; do not auto-resolve — follow `@reference/phase-ops.md §DOCS CONTRADICTION cascade` |
| `[MANIFEST-GAP]` only | Emit FAIL with category `STRUCTURAL`; fix = add mapping to `## Test Manifest` in the plan file |
| Test passes before any implementation exists | `TEST_INTEGRITY` — always FAIL regardless of other findings |

