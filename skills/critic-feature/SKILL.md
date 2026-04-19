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

**3. Naming** (per @reference/layers.md §Naming conventions)
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
```

Verdict & blocking rules: @reference/critics.md §Verdict format. On FAIL blocks progress to `writing-spec`.
Naming violations (kebab-case, verb-noun, noun-singular) map to `STRUCTURAL`.

## Calibration examples

### PASS — well-formed decomposition
Input: `add-todo` (small, single responsibility, calls `domain/todo`), `manage-todo-workflow` (large, composes `add-todo` + `complete-todo`, no direct domain call), domain concept `todo` (noun, pure).

### FAIL — layer misassignment + naming violations
Input: `todo` listed as a small feature (it's a domain concept), `AddTodo` (PascalCase), `manage-todo-workflow` calls `domain.todo` directly (large feature violation), `send-notification` in domain concepts (infrastructure concern, verb-noun).

```
### Classification Issues
[FAIL] `todo`: domain concept placed as feature — move to `domain/todo`
[FAIL] `AddTodo`: PascalCase violates naming — rename to `add-todo`
[FAIL] `manage-todo-workflow`: large feature calls domain directly — compose small features only
[FAIL] `send-notification`: infrastructure concern in domain; rename to noun (e.g. `notification`)

### Missing Features
None

### Verdict
FAIL — layer misassignment, naming violations, large-feature domain call
```
(Verdict envelope format: `@reference/critics.md §Verdict format`; category: `LAYER_VIOLATION`)
