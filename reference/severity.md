# Severity Criteria (reference)

Canonical verdict protocol and iteration rules: @reference/critic-loop.md

If this file and `critic-loop.md` ever conflict, **`critic-loop.md` is canonical**.

## Finding labels → FAIL threshold

| Level | Label | Triggers FAIL? |
|-------|-------|----------------|
| Critical | `[CRITICAL]` | Yes |
| Missing | `[MISSING]` | Yes |
| Structural fail | `[FAIL]` | Yes |
| Docs contradiction | `[DOCS CONTRADICTION]` | Yes |
| Warning | `[WARN]` | No — does not block progress |

## Label → category mapping

| Finding label | FAIL category |
|---|---|
| `[CRITICAL]` | `SPEC_COMPLIANCE` (default) or `LAYER_VIOLATION` if import-related |
| `[MISSING]` | `MISSING_SCENARIO` |
| `[FAIL]` (structural) | `STRUCTURAL` or `LAYER_VIOLATION` depending on nature |
| `[FAIL]` (test integrity) | `TEST_INTEGRITY` or `TEST_QUALITY` |
| `[DOCS CONTRADICTION]` | `DOCS_CONTRADICTION` |

Category priority (highest first): `LAYER_VIOLATION` > `DOCS_CONTRADICTION` > `SPEC_COMPLIANCE` > `MISSING_SCENARIO` > `TEST_INTEGRITY` > `TEST_QUALITY` > `STRUCTURAL`

Choose the single highest-priority category when multiple labels appear in one verdict.

## Output format

Every critic **must** emit the `### Verdict` heading followed immediately by the HTML markers as the last lines of output. Both are machine-parsed by `plan-file.sh record-verdict`.

PASS:
```
### Verdict
PASS
<!-- verdict: PASS -->
<!-- category: NONE -->
```

FAIL:
```
### Verdict
FAIL — {comma-separated list of blocking finding labels}
<!-- verdict: FAIL -->
<!-- category: {highest-priority category} -->
```
