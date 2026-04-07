# Severity Criteria for Critics

All critic agents use these definitions. Do not redefine them locally.

## Levels

| Level | Label | Use when |
|-------|-------|----------|
| **Critical** | `[CRITICAL]` | Would cause a bug, data loss, spec violation, or undefined behaviour in production if left unfixed |
| **Missing** | `[MISSING]` | A required scenario, test, or feature is absent; its absence leaves a gap that blocks correctness |
| **Fail** | `[FAIL]` | A structural rule is violated (layer boundary, BDD format, naming); blocks pipeline progress |
| **Docs contradiction** | `[DOCS CONTRADICTION]` | Implementation or spec conflicts with documented domain knowledge in `docs/*.md`; report only, do not judge which side is wrong |
| **Warning** | `[WARN]` | Would improve quality but absence does not cause a defect; does **not** block progress |

## Verdict rules

- Any `[CRITICAL]`, `[MISSING]`, `[FAIL]`, or `[DOCS CONTRADICTION]` → **FAIL**
- Only `[WARN]` findings → **PASS**
- No findings → **PASS**

## Output format

```
### Verdict
PASS
```

or

```
### Verdict
FAIL — {comma-separated list of blocking finding labels}
```

Always output the Verdict section last.
