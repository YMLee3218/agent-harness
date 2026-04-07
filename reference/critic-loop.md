# Critic Loop

Standard max-2-iteration protocol used by every phase-gate critic.

## Mandatory verdict marker

Every critic agent **must** emit exactly one of the following as the last line of its output:

```
<!-- verdict: PASS -->
```

or

```
<!-- verdict: FAIL -->
```

This marker is machine-parsed by `plan-file.sh record-verdict`. Output that does not end with this marker will be recorded as `PARSE_ERROR` in the plan file.

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
   If `iteration == 2`: use `AskUserQuestion` — "This critic has failed twice. Paste the latest verdict for manual review, or describe how to proceed."

Append the verdict (PASS or FAIL) to plan file `## Critic Verdicts` after every run.
