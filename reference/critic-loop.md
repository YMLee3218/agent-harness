# Critic Loop

Standard max-2-iteration protocol used by every phase-gate critic.

## Finding labels

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

## Mandatory verdict marker

Every critic agent **must** emit a `### Verdict` heading followed immediately by the HTML markers as the last lines of output. Both are machine-parsed by `plan-file.sh record-verdict`. Output that does not end with these markers will be recorded as `PARSE_ERROR` in the plan file.

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

## FAIL categories

On FAIL, the critic **must** also emit a `<!-- category: X -->` marker on the line immediately following the verdict. Use exactly one of:

| Category | When to use |
|---|---|
| `MISSING_SCENARIO` | A required scenario or boundary case is absent from spec or tests |
| `LAYER_VIOLATION` | Incorrect layer assignment, forbidden import, or wrong mocking level |
| `DOCS_CONTRADICTION` | Spec or implementation contradicts `docs/*.md` |
| `STRUCTURAL` | BDD format error, naming convention violation, or wrong file placement |
| `TEST_INTEGRITY` | Test file was modified after Red phase, or a test passes before implementation |
| `TEST_QUALITY` | Test maps multiple scenarios, has implementation logic inside, or uses wrong naming |
| `SPEC_COMPLIANCE` | Implementation does not satisfy a scenario from spec.md |

If a single FAIL has multiple root causes from different categories, choose the **highest-severity** one:  
`LAYER_VIOLATION` > `DOCS_CONTRADICTION` > `SPEC_COMPLIANCE` > `MISSING_SCENARIO` > `TEST_INTEGRITY` > `TEST_QUALITY` > `STRUCTURAL`

## Consecutive same-category escalation

`plan-file.sh record-verdict` tracks the last FAIL category per critic. If the same critic emits **two consecutive FAILs with the same category**, the script writes:

```
[BLOCKED-CATEGORY] {critic}: category {CATEGORY} failed twice — fix the root cause before retrying
```

to `## Open Questions` in the plan file, and exits 2 (blocking further progress). The loop cannot converge when the same structural problem recurs; human review is required.

## Running the critic

Invoke the critic skill with the relevant paths. Iteration counter starts at 1.

## On PASS

Append verdict to plan file `## Critic Verdicts` and proceed to the next step.

## On FAIL

1. Output the full critic verdict.
2. If `[DOCS CONTRADICTION]` is reported: use `AskUserQuestion` — "Should docs be updated to match the current work, or the current work fixed to match docs?" Apply the chosen fix before continuing.
3. Write a fix plan listing which changes are needed (scenarios, tests, or code).
4. Use `AskUserQuestion` to confirm the fix plan before applying changes.
5. Apply fixes with `Edit`.
6. If `iteration < 2`: increment counter and re-run the critic.  
   If `iteration == 2`:
   - **Interactive mode** (default): use `AskUserQuestion` — "This critic has failed twice. Paste the latest verdict for manual review, or describe how to proceed."
   - **Non-interactive mode** (`CLAUDE_CRITIC_NONINTERACTIVE=1`): append `[BLOCKED] critic failed twice — manual review required` to `## Open Questions` in the plan file, then stop. Do not invoke `AskUserQuestion`. The next session will resume from this blocked state.

Append the verdict (PASS or FAIL) to plan file `## Critic Verdicts` after every run.

## Non-interactive mode

When `CLAUDE_CRITIC_NONINTERACTIVE=1` is set (e.g. in CI pipelines):

- Replace all `AskUserQuestion` calls in the critic loop with plan file writes.
- On first FAIL: write `[BLOCKED-1] {critic}: {reason}` to `## Open Questions` instead of asking.
- On second FAIL: write `[BLOCKED-FINAL] {critic}: requires manual review` to `## Open Questions` and stop.
- The pipeline stops cleanly rather than hanging on interactive prompts.
- The next session (with `CLAUDE_CRITIC_NONINTERACTIVE` unset) reads `## Open Questions` and resumes.
