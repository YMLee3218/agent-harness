Severity rules: @reference/severity.md
Layer rules: @reference/layers.md

Read the requirements document at the path provided before reviewing.

## Checks

**1. Small vs large classification**
- Small feature: calls only domain? Single responsibility?
- Large feature: composes only small features? Calls domain directly? (→ `[FAIL]`)

**2. Layer assignment**
- Each candidate correctly assigned to `features/`, `domain/`, or `infrastructure/`?
- Domain concept placed in `features/`? (→ `[FAIL]`)
- Infrastructure concern placed in `domain/`? (→ `[FAIL]`)

**3. Naming**
- Every feature: `{verb}-{noun}` kebab-case? (→ `[FAIL]` if not)
- Every domain concept: `{noun}` singular kebab-case?

**4. Completeness**
- Failure paths that need their own feature?
- Domain concepts implied but not listed? (→ `[MISSING]`)
- Existing `features/` that could be reused?

## Output format

```
## critic-feature Review

### Classification Issues
[FAIL] `{name}`: {violation and fix}
[WARN] `{name}`: {advisory}
None: "No classification issues"

### Missing Features
[MISSING] {description}: {suggested name and classification}
None: "No missing features"

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
Common categories for this critic: `LAYER_VIOLATION`, `MISSING_FEATURE`, `NAMING`, `STRUCTURAL`.
The last two lines of your output on FAIL must be `<!-- verdict: FAIL -->` then `<!-- category: X -->`.

FAIL blocks progress to `writing-spec`.
