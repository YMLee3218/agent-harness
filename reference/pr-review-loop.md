# PR-Review Fix Loop

Called from `skills/implementing/SKILL.md §Step 5` on FAIL.

**Categorisation** — interactive: `AskUserQuestion`; non-interactive: infer from evidence. If ambiguous, append `[BLOCKED-AMBIGUOUS] pr-review: {question}` and stop.

**Fix chains on FAIL** — on first FAIL from `implement`, transition to `review` before fixing; remain in `review` for all subsequent FAILs:

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" review \
  "first pr-review FAIL"
```

## Code-only

Issues: naming, duplication, complexity, style, silent failures.

→ Fix code → run tests → apply §Fix-chain finisher (steps 1 and 3; step 2 not needed — already in `review`)

## Spec gap

Issue: unhandled scenario revealed by review.

→ Add scenario to `spec.md`

→ Reset the critic-spec milestone and transition to `spec` phase (stale `[CONVERGED] spec/critic-spec` would short-circuit convergence; `reset-milestone` requires the current phase to equal the marker scope):
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" spec \
  "spec gap — resetting critic-spec milestone before re-review"
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "plans/{slug}.md" critic-spec
```
→ Re-run `Skill("critic-spec")` (follow `@reference/critics.md §Invocation recipe` until `[CONVERGED]`)

→ Apply `@reference/phase-ops.md §Phase Rollback Procedure`: target-phase=`red`, critic=`critic-test`
→ Write failing test → re-run `Skill("critic-test")`
→ Advance to `implement`:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" implement \
  "spec gap test written — implementing fix"
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" commit-phase "plans/{slug}.md" \
  "chore(phase): advance to implement — spec gap fix"
```
→ Implement → apply §Fix-chain finisher (all 3 steps)

## Docs conflict

Issue: implementation contradicts domain rules.

→ Apply `@reference/phase-ops.md §DOCS CONTRADICTION cascade` (all steps including the **During `review` phase** section)

## Fix-chain finisher

1. **(If code changed)** Reset critic-code milestone and re-run:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "plans/{slug}.md" critic-code
   ```
   → `Skill("critic-code")` (follow `@reference/critics.md §Skill branching logic` until `[CONVERGED]`)

2. **(If not already in `review` phase)** Restore to `review`:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" review \
     "{fix description} — resuming pr-review"
   ```

3. Re-run `Skill("pr-review-toolkit:review-pr")` → call `append-review-verdict` → run `@reference/ultrathink.md §Ultrathink verdict audit` → branch per `@reference/critics.md §pr-review asymmetry` (PASS: convergence reached, return to calling context; FAIL: re-categorize above and apply the appropriate fix chain again)
