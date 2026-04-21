---
name: critic-feature
description: >
  Review feature decomposition: classification errors, layer misassignment, naming, missing features.
  Trigger: after brainstorming produces a candidate list, before writing-spec begins.
user-invocable: false
context: fork
agent: critic-feature
allowed-tools: [Read, Glob]
effort: high
paths: ["docs/**"]
---

@reference/critics.md

Read the requirements document at the path provided.

## Checks

**1. Small vs large classification**
- Small feature: calls only domain? Single responsibility?
- Large feature: composes only small features? Calls domain directly? (→ `[FAIL]`)

**2. Layer assignment**
- Each candidate correctly assigned to `features/`, `domain/`, or `infrastructure/`?
- Domain concept placed in `features/`? (→ `[FAIL]`)
- Infrastructure concern placed in `domain/`? (→ `[FAIL]`)

**3. Naming** — per `@reference/layers.md §Naming conventions` (→ `[FAIL]` if violated)

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
```

Verdict & blocking rules: @reference/critics.md §Verdict format. On FAIL blocks progress to `writing-spec`.

Category mapping (per `@reference/severity.md §Category priority`):

| Check | Category |
|-------|----------|
| Layer assignment / size-classification violation (Checks 1–2) | `LAYER_VIOLATION` |
| Naming violation (Check 3) | `STRUCTURAL` |
| Missing domain concept (Check 4) | `MISSING_SCENARIO` |

When multiple FAILs fire, pick the highest-priority category per `@reference/severity.md §Category priority`.
