# PR-Review Fix Loop

Called from `skills/running-dev-cycle/SKILL.md §Step 2c` on pr-review FAIL.

**Categorisation** — interactive: `AskUserQuestion`; non-interactive: infer from evidence. If ambiguous, append `[BLOCKED-AMBIGUOUS] pr-review: {question}` and stop.

**Fix chains on FAIL** — on first FAIL from `implement`, transition to `review` before fixing; remain in `review` for all subsequent FAILs:

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" review \
  "first pr-review FAIL"
```

## Code-only

Issues: naming, duplication, complexity, style, silent failures.

→ Fix code → run tests → apply §Fix-chain finisher (all 3 steps)

## Spec gap

Issue: unhandled scenario revealed by review.

→ Add scenario to `spec.md`

→ Reset the critic-spec milestone and transition to `spec` phase (stale `[CONVERGED] spec/critic-spec` would short-circuit convergence; `reset-milestone` requires the current phase to equal the marker scope):
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" spec \
  "spec gap — resetting critic-spec milestone before re-review"
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "plans/{slug}.md" critic-spec
```
→ `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/run-critic-loop.sh" --agent critic-spec --phase spec --plan "plans/{slug}.md" --prompt "Review spec at [spec-path]."` — exit 0 → proceed; exit 1 → [BLOCKED] written to plan — stop and report; exit 2 → [BLOCKED-CEILING] — manual review required.

→ Apply `@reference/phase-ops.md §Phase Rollback Procedure`: target-phase=`red`, critic=`critic-test`
→ Write failing test → `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/run-critic-loop.sh" --agent critic-test --phase red --plan "plans/{slug}.md" --prompt "Review tests at [paths] against spec at [path]. Test command: [command]."` (§Phase Rollback already reset the milestone.) — exit 0 → proceed; exit 1 → [BLOCKED] written to plan — stop and report; exit 2 → [BLOCKED-CEILING] — manual review required.
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

1. **(If code changed)** Re-run critic-code:
   (a) Transition to `implement` (ensures `record-verdict` stamps `implement/critic-code`; without this, the plan may be in `review` and markers would be stamped `review/critic-code`, breaking convergence):
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" implement \
     "pr-review fix — re-running critic-code"
   ```
   (b) Reset critic-code milestone:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "plans/{slug}.md" critic-code
   ```
   → `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/run-critic-loop.sh" --agent critic-code --phase implement --plan "plans/{slug}.md" --prompt "Review these files: [explicit list]. Spec at: [path]. Relevant docs: [paths]."` — exit 0 → proceed; exit 1 → [BLOCKED] written to plan — stop and report; exit 2 → [BLOCKED-CEILING] — manual review required.

2. **(If not already in `review` phase)** Restore to `review`:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" review \
     "{fix description} — resuming pr-review"
   ```

3. Re-run `Skill("pr-review-toolkit:review-pr")` → call `append-review-verdict` → run `@reference/ultrathink.md §Ultrathink verdict audit` → branch per `@reference/critics.md §pr-review asymmetry` ([CONVERGED]: return to calling context; FAIL: re-categorize above and apply the appropriate fix chain again)
