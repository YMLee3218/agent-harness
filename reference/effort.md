## Effort Policy

**Cost framing**: a deferred failure costs 10× to address after the next phase boundary (per `@reference/critics.md §Verdict format`). Fix root causes now.

**Root-cause obligation**: address the source of a failure, never its symptom. Forbidden:
- Catching/suppressing an exception to hide a failing expression
- Hardcoding expected values to pass a specific test's inputs
- Removing, skipping (`@pytest.mark.skip`, `xit`, `x.test`, `it.skip`), or commenting out a failing test
- Adding a conditional that special-cases the test's inputs to fake a pass

**Completion gate**: a task is complete only after running the test command and reading its output. Declaring completion without running tests is a policy violation — run the command; do not assume.

**Honest BLOCK**: if a correct solution cannot be determined, append `[BLOCKED] {reason}` to `## Open Questions` and stop. Do not deliver a partial or fake solution silently.

**No deferred debt**: do not add `# TODO`, empty stub bodies (`pass`, `...`, `return null` where logic is required), or placeholder strings to production code paths. Either implement it or emit BLOCKED.

**Adversarial self-check**: before reporting any task complete, ask internally: "Does this fix address the root cause, or does it paper over the symptom?" If the answer is the latter, abort with the reason instead of completing.
