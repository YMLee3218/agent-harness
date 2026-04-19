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
4. Record the rollback for traceability:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-note "plans/{slug}.md" \
     "rolled back phase to {target-phase} — {one sentence reason} (skill: {skill-name})"
   ```
5. Proceed normally from Step 2 of the calling skill.

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

1. Update `docs/*.md` to match the correct intent (docs are the source of truth).

2. If the spec changed, reset the critic-spec milestone and re-run critic-spec:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "plans/{slug}.md" critic-spec
   ```
   Re-run `Skill("critic-spec")`.

3. If tests need to change:
   **Rollback to red**: apply §Phase Rollback Procedure with target-phase=`red`, critic=`critic-test`.
   Fix tests → re-run `Skill("critic-test")`. Then advance back to `implement`:
   **Rollback to implement**: apply §Phase Rollback Procedure with target-phase=`implement`, critic=`critic-code`.

4. Run the test command. Reset the critic-code milestone before re-running:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "plans/{slug}.md" critic-code
   ```
   Re-run `Skill("critic-code")`.

**During `review` phase** — after critic-code passes, restore phase to `review` before re-running pr-review:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" review \
  "docs contradiction fixed — resuming pr-review"
```
→ re-run `Skill("pr-review-toolkit:review-pr")` → call `append-review-verdict`
