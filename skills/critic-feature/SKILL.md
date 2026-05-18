---
name: critic-feature
description: >
  Review feature decomposition: classification errors, layer misassignment, naming, missing features.
  Trigger: after brainstorming produces a candidate list, before writing-spec begins.
user-invocable: false
context: fork
agent: critic-feature
allowed-tools: [Read, Glob]
paths: ["docs/**", "features/**", "plans/**"]
---

@reference/critics.md

Read the requirements document at the path provided.

## Checks

**1. Small vs large classification** → category: `LAYER_VIOLATION`
- Small feature: calls domain and/or infrastructure directly? Single responsibility?
- Large feature: calls domain directly? (→ `[FAIL]`) Composes a peer large feature that is not a self-contained sub-pipeline reused across multiple business flows? (→ `[FAIL]`)

**2. Naming** — per `@reference/layers.md §Naming conventions` (→ `[FAIL]` if violated) → category: `STRUCTURAL`

**3. Missing features** → category: `MISSING_SCENARIO`
- Failure paths that need their own feature?
- Existing `features/` that could be reused?

**4. Operating Envelope** → category: `ENVELOPE_MISMATCH`
- Brainstorming declares the Operating Envelope in the plan file (not the requirements doc). Derive the plan file path from the requirements doc path: `docs/requirements/{slug}.md` → `plans/{slug}.md`. Read the plan file and verify each candidate feature has an Operating Envelope with all 6 axes (Actors, Frequency, Concurrency, Persistence, Failure model, External I/O) declared.
- If absent or any axis is undeclared (not `[BLOCKED]`): `[FAIL]` ENVELOPE_MISMATCH — writing-spec (step 2) cannot determine the envelope; the Operating Envelope must be declared in the plan file before spec writing begins.

## Output format

```
## critic-feature Review

### Classification Issues
[FAIL] `{name}`: {violation and fix}
None: "No classification issues"

### Missing Features
[MISSING] {description}: {suggested name} — missing failure path or reusable feature
None: "No missing features"

### Citation Summary
(one line per blocking finding — omit if PASS)
- {tag} @ {file}:{line}: "{verbatim excerpt, max 80 chars}"

### Verdict
PASS
<!-- verdict: PASS -->
<!-- category: NONE -->
```
or (FAIL):
```
### Verdict
FAIL — {comma-separated blocking finding labels}
<!-- verdict: FAIL -->
<!-- category: {one of LAYER_VIOLATION | STRUCTURAL | MISSING_SCENARIO | ENVELOPE_MISMATCH} -->
```

Copy `<!-- category: X -->` verbatim from the `→ category:` annotation on the check that fired. Do not substitute descriptive synonyms (e.g. `COMPLETENESS` is not an enum member).

End with exactly one `### Verdict` block (PASS or FAIL). Verdict & blocking rules: @reference/critics.md §Verdict format. On FAIL blocks progress to `writing-spec`.

Category mapping (per `@reference/severity.md §Category priority`):

| Check | Category |
|-------|----------|
| Size-classification violation (Check 1) | `LAYER_VIOLATION` |
| Naming violation (Check 2) | `STRUCTURAL` |
| Missing features (Check 3) | `MISSING_SCENARIO` |
| Operating Envelope absent/incomplete (Check 4) | `ENVELOPE_MISMATCH` |

When multiple FAILs fire, pick the highest-priority category per `@reference/severity.md §Category priority`.
