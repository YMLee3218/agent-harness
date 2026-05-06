# Phase Operations

Phase rollback, skill phase entry, and DOCS CONTRADICTION cascade procedures.
Skills cite sections here by name.

Severity rules: @reference/severity.md
Layer rules: @reference/layers.md

## Phase Rollback Procedure

Used when re-entering a writing phase from a later phase (slice mode or any rollback).
Calling skill specifies `{target-phase}` and `{critic-name}`.

1. Preserve all existing `## Critic Verdicts` — do not delete them.
2. Set plan phase and record the rollback (`transition` sets phase first, then appends the entry — correct ordering for step 3):
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" {target-phase} \
     "{one sentence reason}"
   ```
3. Reset the `{critic-name}` milestone (`transition` already ran `set-phase`, so `reset-milestone` reads the correct rollback phase when clearing the stale `[CONVERGED] {target-phase}/{critic-name}` marker):
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "plans/{slug}.md" {critic-name}
   ```
4. Proceed normally from Step 2 of the calling skill.

## Skill phase entry

On entry, every skill must verify the plan file phase before doing any work.

### Standard check

1. Read `plans/{slug}.md` (resumes context after `/compact`).
2. Confirm phase matches the skill's expected entry phase(s) listed at the top of the skill.
3. If phase matches: proceed.
4. If phase does not match and rollback is allowed (e.g., slice mode re-entry or explicit rollback trigger): apply §Phase Rollback Procedure with the appropriate `{target-phase}`.
5. If phase does not match and no rollback path applies: append `[BLOCKED] {skill-name} entered from unexpected phase {phase} — {guidance}` to `## Open Questions` and stop.

### Unexpected phase handling

| Situation | Action |
|-----------|--------|
| Phase is earlier than expected (skill was already run) | Continue if idempotent; otherwise ask/block |
| Phase is later than expected (re-entry from slice mode) | Apply phase rollback to correct phase |
| Phase is `done` | New feature needed — run `/brainstorming` first |
| Phase is unknown/unreadable | Block: malformed plan file |

### After phase confirmation

Set or confirm the correct phase in the plan file using:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" {phase} "{reason}"
```
Only call `transition` when actually changing phase. Do not re-transition to the same phase.

## DOCS CONTRADICTION cascade

When a `[DOCS CONTRADICTION]` verdict is raised, apply this cascade:

First, clear the `[BLOCKED-AMBIGUOUS]` marker that triggered this cascade — `run-critic-loop.sh` exits 1 on any `[BLOCKED` match, so leaving it in place blocks every sub-run below.

**Run from a human terminal** (Claude cannot execute this step — `pretooluse-bash.sh` blocks `clear-marker` on `[BLOCKED-AMBIGUOUS]` markers):
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" clear-marker "plans/{slug}.md" "[BLOCKED-AMBIGUOUS] {agent}"
```

1. Determine ground truth: if `docs/*.md` is stale (the implementation reflects the correct intent), update `docs/*.md` to match; if the implementation deviated from documented intent, update code/spec to match `docs/*.md`. `docs/*.md` is the intended source of truth for domain knowledge — leave it accurate after resolution.

2. If the spec changed, transition to `spec` first (skip if already in `spec`; required so `reset-milestone` targets `spec/critic-spec` — not the current-phase-scoped variant; see `@reference/critics.md §New milestone`), then reset the milestone and re-run critic-spec:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" spec \
     "docs contradiction — resetting spec milestone for re-review"
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "plans/{slug}.md" critic-spec
   ```
   `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/run-critic-loop.sh" --agent critic-spec --phase spec --plan "plans/{slug}.md" --nested --prompt "Review spec at [spec-path]. Relevant docs: [doc-paths]."` — exit 0 → proceed; exit 1 → [BLOCKED] written to plan — stop and report; exit 2 → [BLOCKED-CEILING] — manual review required.
   After critic-spec converges, **only if step 3 will NOT also run** (tests do not need changing), restore to `implement`:
   ```bash
   # Skip this block if step 3 (tests need changing) will also run — step 3's §Phase Rollback handles the phase advance from spec → red → implement
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" implement \
     "docs contradiction fixed — spec re-verified"
   ```

3. If tests need to change:
   **Rollback to red**: apply §Phase Rollback Procedure with target-phase=`red`, critic=`critic-test`.
   Fix tests → `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/run-critic-loop.sh" --agent critic-test --phase red --plan "plans/{slug}.md" --nested --prompt "Review tests at [paths] against spec at [path]. Test command: [command]."` (Phase Rollback already reset the milestone.) — exit 0 → proceed; exit 1 → [BLOCKED] written to plan — stop and report; exit 2 → [BLOCKED-CEILING] — manual review required. Then advance back to `implement`:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" implement \
     "docs contradiction fixed — tests updated and passing"
   ```

4. If steps 2 and 3 did not run (docs-only fix with no spec or test changes), check the current plan phase. If it is `review`, transition to `implement` so `record-verdict` stamps `implement/critic-code` (not `review/critic-code`). If already in `implement`, skip this transition:
   ```bash
   # Only run if plan phase is `review` — do not re-transition if already in `implement`
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" implement \
     "docs contradiction applied — no spec or test changes; re-running critic-code"
   ```
   Run the test command. Reset the critic-code milestone before re-running:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "plans/{slug}.md" critic-code
   ```
   `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/run-critic-loop.sh" --agent critic-code --phase implement --plan "plans/{slug}.md" --nested --prompt "Review these files: [changed files]. Spec at: [spec-path]. Relevant docs: [paths]."` — exit 0 → proceed; exit 1 → [BLOCKED] written to plan — stop and report; exit 2 → [BLOCKED-CEILING] — manual review required.

**During `review` phase** — after critic-code passes, restore phase to `review` before re-running pr-review:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" review \
  "docs contradiction fixed — resuming pr-review"
```
→ re-run `Skill("pr-review-toolkit:review-pr")` → call `append-review-verdict` → run `@reference/ultrathink.md §Ultrathink verdict audit` → branch per `@reference/critics.md §pr-review asymmetry` ([CONVERGED]: return to calling context; FAIL: re-categorize above and apply the appropriate fix chain again)
