# Verdict Format

Canonical output format for all critic agents. Machine-parsed by `plan-file.sh record-verdict`.

## Required output structure

Every critic **must** end its output with a `### Verdict` section containing the HTML markers shown below. Any output that does not end with these markers is recorded as `PARSE_ERROR` in the plan file.

### PASS

```
### Verdict
PASS
<!-- verdict: PASS -->
<!-- category: NONE -->
```

### FAIL

```
### Verdict
FAIL — {comma-separated list of blocking finding labels}
<!-- verdict: FAIL -->
<!-- category: {highest-priority category} -->
```

## Finding labels

Severity levels and FAIL/PASS threshold: `@reference/severity.md` (single source of truth).

## Category priority

Severity levels, PASS/FAIL threshold, and category priority order are defined in `@reference/severity.md` (single source of truth). Do not duplicate those tables here.

Full iteration protocol: @reference/critic-loop.md
