---
name: critic-feature
description: >
  Review feature decomposition: classification errors, layer misassignment, naming, missing features.
  Trigger: after brainstorming produces a candidate list, before writing-spec begins.
user-invocable: false
context: fork
agent: critic-feature
allowed-tools: [Read, Glob]
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
- Brainstorming declares the Operating Envelope in the plan file (not the requirements doc). Read the plan file at `${CRITIC_PLAN_PATH:?CRITIC_PLAN_PATH not set}` and verify each candidate feature has an Operating Envelope with all 6 axes (Actors, Frequency, Concurrency, Persistence, Failure model, External I/O) declared.
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
```

## Verdict format (strict — parsed by SubagentStop hook)

End your output with exactly one PASS or FAIL block below. The SubagentStop hook
parses only the two HTML-comment markers; text outside them is ignored.

### Rule 1 — PASS pairs only with NONE (most common failure mode)

If verdict is PASS, the category marker MUST be exactly `NONE`. No exceptions.
- Inspected LAYER_VIOLATION area but found nothing blocking? → PASS + NONE.
- Found a cosmetic/typo/style observation? → Do NOT report it. PASS + NONE.

A PASS paired with any non-NONE category (STRUCTURAL, MISSING_SCENARIO, …) is
recorded as PARSE_ERROR. Two consecutive PARSE_ERRORs halt the run.

### Rule 2 — Advisory severity labels do not exist

Per `@reference/severity.md`, only these labels are valid and ALL are blocking:
`[CRITICAL]`, `[MISSING]`, `[MANIFEST-GAP]`, `[FAIL]`, `[DOCS CONTRADICTION]`,
`[UNVERIFIED CLAIM]`. Inventing `[MINOR]`, `[NIT]`, `[INFO]`, `[ADVISORY]`,
`[STYLE]`, `[SUGGESTION]` is forbidden. If an observation does not warrant one
of the six blocking labels, omit it entirely — do not relabel it.

Corollary: if your `Findings:` list contains no blocking labels, verdict is
PASS and category is NONE. Period.

### Rule 3 — FAIL category enum (only when Rule 1 does not apply)

On FAIL, copy `<!-- category: X -->` verbatim from the `→ category:`
annotation on the check that fired. Allowed enum (this critic):
`LAYER_VIOLATION | STRUCTURAL | MISSING_SCENARIO | ENVELOPE_MISMATCH`.

FORBIDDEN substitutes (recorded as PARSE_ERROR): `COMPLETENESS`, `CONSISTENCY`,
`CORRECTNESS`, `CONTRACT`, any descriptive synonym, any section title.
A FAIL without a `<!-- category: -->` marker is recorded as PARSE_ERROR.

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
FAIL — {comma-separated blocking finding labels}
<!-- verdict: FAIL -->
<!-- category: {one of LAYER_VIOLATION | STRUCTURAL | MISSING_SCENARIO | ENVELOPE_MISMATCH} -->
```

On FAIL blocks progress to `writing-spec`.

Category mapping (per `@reference/severity.md §Category priority`):

| Check | Category |
|-------|----------|
| Size-classification violation (Check 1) | `LAYER_VIOLATION` |
| Naming violation (Check 2) | `STRUCTURAL` |
| Missing features (Check 3) | `MISSING_SCENARIO` |
| Operating Envelope absent/incomplete (Check 4) | `ENVELOPE_MISMATCH` |

When multiple FAILs fire, pick the highest-priority category per `@reference/severity.md §Category priority`.
