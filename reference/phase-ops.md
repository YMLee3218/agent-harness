# Phase Operations

Phase rollback, skill phase entry, and DOCS CONTRADICTION cascade procedures.
Skills cite sections here by name.

Severity rules: @reference/severity.md
Layer rules: @reference/layers.md

## Phase Rollback Procedure

Used when re-entering a writing phase from a later phase (slice mode or any rollback).
Calling skill specifies `{target-phase}` and `{critic-name}`.

### Reverting from implement/red to spec

When reverting a feature fully back to spec phase, delete ALL test and implementation files for
that feature before committing. A revert that leaves implementation in place is incomplete — the
next writing-tests run will classify tests against the leftover code and produce incorrect GREEN
entries.

Checklist:
- [ ] `git rm tests/{feature_path}/*`
- [ ] `git rm src/**/{feature_module}.*` (all layers: domain, infrastructure, features)
- [ ] Clean `## Task Definitions`, `## Task Ledger`, `## Integration Failures`, and body of
      `## Open Questions` from the plan file (do NOT clean `## Critic Verdicts` — preserve per step 1 below; do NOT clean `## Verdict Audits` — permanent trail)
- [ ] Run `plan-file.sh transition ... {target-phase}` to set phase (do NOT edit `phase:` frontmatter directly — blocked by pretooluse hook; see step 2 below)

1. Preserve all existing `## Critic Verdicts` — do not delete them.
2. Set plan phase and record the rollback (`transition` sets phase first, then appends the entry — correct ordering for step 3):
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "$CLAUDE_PROJECT_DIR/plans/{slug}.md" {target-phase} \
     "{one sentence reason}"
   ```
3. Reset the `{critic-name}` milestone (`transition` already ran `set-phase`, so `reset-milestone` reads the correct rollback phase when clearing stale convergence markers for `{target-phase}/{critic-name}`):
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "$CLAUDE_PROJECT_DIR/plans/{slug}.md" {critic-name}
   ```
4. **Post-rollback convergence-verdict consistency check**: for each affected agent at `{target-phase}` (the current plan phase after step 2), verify the sidecar is consistent with `## Critic Verdicts`. Use `{target-phase}` as the phase — `clear-converged` reads the current plan phase, so `{phase}` and the current plan phase must agree:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" is-converged "$CLAUDE_PROJECT_DIR/plans/{slug}.md" {target-phase} {agent}
   ```
   If this prints a `DIVERGENCE` message (sidecar `converged=true` but plan.md shows FAIL), the runtime guard detected forged state. Explicitly reset the sidecar so the stale `converged:true` does not persist:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" clear-converged "$CLAUDE_PROJECT_DIR/plans/{slug}.md" {agent}
   ```
   **Do not hand-edit the convergence JSON to restore PASS.** Doing so recreates the exact forgery this check prevents.
5. Proceed normally from Step 2 of the calling skill.

## Skill phase entry

On entry, every skill must verify the plan file phase before doing any work.

### Standard check

1. Read `plans/{slug}.md` (resumes context after `/compact`).
2. Confirm phase matches the skill's expected entry phase(s) listed at the top of the skill.
3. If phase matches: proceed.
4. If phase does not match and rollback is allowed (e.g., slice mode re-entry or explicit rollback trigger): apply §Phase Rollback Procedure with the appropriate `{target-phase}`.
5. If phase does not match and no rollback path applies: append `[BLOCKED:env] {skill-name}: unexpected-phase — entered from {phase}; {guidance}` to `## Open Questions` and stop.

### Unexpected phase handling

| Situation | Action |
|-----------|--------|
| Phase is earlier than expected (skill was already run) | Continue if idempotent; otherwise ask/block |
| Phase is later than expected (re-entry from slice mode) | Apply phase rollback to correct phase |
| Phase is `done` | New feature needed — run `/brainstorming` first |
| Phase is unknown/unreadable | Block: malformed plan file |

### After phase confirmation

Set the correct phase in the plan file using:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "$CLAUDE_PROJECT_DIR/plans/{slug}.md" {phase} "{reason}"
```
Only call `transition` when actually changing phase. Do not re-transition to the same phase.

## DOCS CONTRADICTION cascade

When a `[BLOCKED:docs]` marker is written (triggered by a `[DOCS CONTRADICTION]` verdict), apply this cascade:

First, clear the `[BLOCKED:docs]` marker that triggered this cascade — `unblock` also clears the corresponding entry in the sidecar `blocked.jsonl`, which `run-critic-loop.sh` checks via `is-blocked`; leaving the block in place causes every sub-run below to exit 1 immediately.

**Run from a human terminal** (Ring C — `CLAUDE_PLAN_CAPABILITY=human` required; `plan-file.sh` blocks `unblock` without it):
```bash
export CLAUDE_PLAN_CAPABILITY=human
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" unblock "$CLAUDE_PROJECT_DIR/plans/{slug}.md"
```

Then switch to Ring B for all subsequent `transition` and `reset-milestone` commands:
```bash
export CLAUDE_PLAN_CAPABILITY=harness
```

1. Determine ground truth: if `docs/*.md` is stale (the implementation reflects the correct intent), update `docs/*.md` to match; if the implementation deviated from documented intent, update code/spec to match `docs/*.md`. `docs/*.md` is the intended source of truth for domain knowledge — leave it accurate after resolution.

2. If the spec changed, transition to `spec` first (skip if already in `spec`; required so `reset-milestone` targets `spec/critic-spec` — not the current-phase-scoped variant; see `@reference/critics.md §New milestone`), then reset the milestone and re-run critic-spec:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "$CLAUDE_PROJECT_DIR/plans/{slug}.md" spec \
     "docs contradiction — resetting spec milestone for re-review"
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "$CLAUDE_PROJECT_DIR/plans/{slug}.md" critic-spec
   ```
   `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/run-critic-loop.sh" --agent critic-spec --phase spec --plan "$CLAUDE_PROJECT_DIR/plans/{slug}.md" --nested --prompt "Review spec at [spec-path]. Relevant docs: [doc-paths]."` — exit 0 → proceed; exit 1 → `[BLOCKED:{kind}]` written to plan — stop and report; exit 2 → `[BLOCKED:ceiling]` — manual review required.
   After critic-spec converges, **only if step 3 will NOT also run** (tests do not need changing), restore to `implement`:
   ```bash
   # Skip this block if step 3 (tests need changing) will also run — step 3's §Phase Rollback handles the phase advance from spec → red → implement
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "$CLAUDE_PROJECT_DIR/plans/{slug}.md" implement \
     "docs contradiction fixed — spec re-verified"
   ```

3. If tests need to change:
   **Rollback to red**: apply §Phase Rollback Procedure with target-phase=`red`, critic=`critic-test`.
   Fix tests → `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/run-critic-loop.sh" --agent critic-test --phase red --plan "$CLAUDE_PROJECT_DIR/plans/{slug}.md" --nested --prompt "Review tests at [paths] against spec at [path]. Test command: [command]."` (Phase Rollback already reset the milestone.) — exit 0 → proceed; exit 1 → `[BLOCKED:{kind}]` written to plan — stop and report; exit 2 → `[BLOCKED:ceiling]` — manual review required. Then advance back to `implement`:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "$CLAUDE_PROJECT_DIR/plans/{slug}.md" implement \
     "docs contradiction fixed — tests updated and passing"
   ```

4. If steps 2 and 3 did not run (docs-only fix with no spec or test changes), no phase transition is needed — the plan stays in the phase where the contradiction surfaced. Reset that phase's critic milestone and re-run it:
   - **`implement`** (critic-code origin — see §"During `implement` phase" below): run the test command, then reset and re-run critic-code:
     ```bash
     bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "$CLAUDE_PROJECT_DIR/plans/{slug}.md" critic-code
     ```
     `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/run-critic-loop.sh" --agent critic-code --phase implement --plan "$CLAUDE_PROJECT_DIR/plans/{slug}.md" --nested --prompt "Review these files: [changed files]. Spec at: [spec-path]. Relevant docs: [paths]."` — exit 0 → proceed; exit 1 → `[BLOCKED:{kind}]` written to plan — stop and report; exit 2 → `[BLOCKED:ceiling]` — manual review required.
   - **`spec`** (critic-spec origin — the contradiction surfaced during spec review and the docs were stale, so the spec itself is unchanged): no implementation exists yet, so do not run the test command. Reset and re-run critic-spec:
     ```bash
     bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "$CLAUDE_PROJECT_DIR/plans/{slug}.md" critic-spec
     ```
     `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/run-critic-loop.sh" --agent critic-spec --phase spec --plan "$CLAUDE_PROJECT_DIR/plans/{slug}.md" --nested --prompt "Review spec at [spec-path]. Relevant docs: [doc-paths]."` — exit 0 → proceed; exit 1 → `[BLOCKED:{kind}]` written to plan — stop and report; exit 2 → `[BLOCKED:ceiling]` — manual review required.

**During `implement` phase (after critic-code)** — critic-quality re-runs automatically in the next shell-loop iteration after a fix is applied; no manual phase transition required.
