---
name: critic-feature
description: >
  Review feature decomposition: classification errors, layer misassignment, naming, missing features.
  Trigger: after brainstorming produces a candidate list, before writing-spec begins.
user-invocable: false
context: fork
agent: critic-feature
allowed-tools: [Read, Glob]
paths: ["docs/**", "features/**"]
---

@reference/critics.md

Read the requirements document at the path provided.

## Checks

**1. Small vs large classification**
- Small feature: calls domain and/or infrastructure directly? Single responsibility?
- Large feature: composes only small features? Calls domain directly? (→ `[FAIL]`)

**2. Requirements scope**
- Does the requirements doc contain only user-facing features?
- Domain concepts or infrastructure items listed as features? (→ `[WARN]` — not blocking; writing-spec will classify them correctly)

**3. Naming** — per `@reference/layers.md §Naming conventions` (→ `[FAIL]` if violated)

**4. Completeness**
- Failure paths that need their own feature?
- Existing `features/` that could be reused?

## Output format

```
## critic-feature Review

### Classification Issues
[FAIL] `{name}`: {violation and fix}
[WARN] `{name}`: {advisory}
None: "No classification issues"

### Missing Features
[MISSING] {description}: {suggested name} — missing failure path or reusable feature
[WARN] {description}: domain concept or infrastructure item noted in requirements — writing-spec will classify
None: "No missing features"
```

Verdict & blocking rules: @reference/critics.md §Verdict format. On FAIL blocks progress to `writing-spec`.

Category mapping (per `@reference/severity.md §Category priority`):

| Check | Category |
|-------|----------|
| Size-classification violation (Check 1) | `LAYER_VIOLATION` |
| Naming violation (Check 3) | `STRUCTURAL` |
| Missing feature (Check 4) | `MISSING_SCENARIO` |

When multiple FAILs fire, pick the highest-priority category per `@reference/severity.md §Category priority`.
