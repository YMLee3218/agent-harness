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

| Label | Triggers FAIL? |
|-------|----------------|
| `[CRITICAL]` | Yes |
| `[MISSING]` | Yes |
| `[FAIL]` | Yes |
| `[DOCS CONTRADICTION]` | Yes |
| `[WARN]` | No |

## Category priority (highest → lowest)

`LAYER_VIOLATION` > `DOCS_CONTRADICTION` > `SPEC_COMPLIANCE` > `MISSING_SCENARIO` > `TEST_INTEGRITY` > `TEST_QUALITY` > `STRUCTURAL`

Choose the single highest-priority category when multiple labels appear in one verdict.

Full iteration protocol: @reference/critic-loop.md
