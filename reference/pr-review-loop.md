# PR-Review Loop

Iteration protocol (`§PR-review one-shot iteration`) is spawned by `run-critic-loop.sh`.
Fix chains below are invoked from within that iteration on FAIL.

## §PR-review one-shot iteration

Single iteration spawned by `run-critic-loop.sh`. Do not loop — one pr-review per session.

1. `Skill("pr-review-toolkit:review-pr")`
2. Output the review verdict (before the ultrathink audit in step 3) in exactly the format injected by `run-critic-loop.sh` into this session's prompt:
   `<!-- review-verdict: {nonce} PASS -->` or `<!-- review-verdict: {nonce} FAIL -->`
   where `{nonce}` is the UUID printed in the prompt. `run-critic-loop.sh` captures the *last* nonce-anchored marker and records the verdict via `append-review-verdict`. Do NOT call `append-review-verdict` directly — `run-critic-loop.sh` must own the final recorded verdict to support REJECT-PASS and ACCEPT-OVERRIDE overrides (the REJECT-PASS and ACCEPT-OVERRIDE overrides in step 3 below each emit an additional marker; `run-critic-loop.sh` captures the *last* occurrence so overrides win). The nonce prevents verdict spoofing via doc citations of the marker format.
3. `@reference/ultrathink.md §Ultrathink verdict audit`
   **REJECT-PASS override**: if the audit outcome is REJECT-PASS, additionally emit `<!-- review-verdict: {nonce} FAIL -->` (using the nonce from this session's prompt) immediately after the `append-audit` call — `run-critic-loop.sh` captures the *last* occurrence of the nonce-anchored marker, so this FAIL overrides the step-2 PASS and ensures `append-review-verdict` records FAIL rather than the demoted PASS.
   **ACCEPT-OVERRIDE override**: if the audit outcome is ACCEPT-OVERRIDE, additionally emit `<!-- review-verdict: {nonce} PASS -->` (using the nonce from this session's prompt) immediately after the `append-audit` call — `run-critic-loop.sh` captures the *last* occurrence of the nonce-anchored marker, so this PASS overrides the step-2 FAIL and ensures `append-review-verdict` records PASS rather than the promoted FAIL.
4. Read `## Open Questions` and query `plan-file.sh is-converged` — apply `@reference/critics.md §Skill branching logic` (pr-review exception: steps 1→4-5→7→8 only):
   - `[BLOCKED:ceiling]` → exit (shell loop returns exit 2)
   - `is-converged` exits 0 → exit (shell loop returns exit 0)
   - no terminal marker + PASS → exit (shell loop re-runs)
   - no terminal marker + FAIL → apply fix chain below, then exit
5. On FAIL: §Categorisation below → appropriate fix chain → §Fix-chain finisher → exit.
   Shell loop re-runs pr-review in the next iteration.

**Categorisation** — interactive: `AskUserQuestion`; non-interactive: infer from evidence. If ambiguous, append `[BLOCKED:spec] pr-review: ambiguous — {question}` and stop.

**Fix chains on FAIL** — **(if not already in `review` phase)** transition to `review` before fixing; remain in `review` for all subsequent FAILs:

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "$CLAUDE_PROJECT_DIR/plans/{slug}.md" review \
  "first pr-review FAIL"
```

## Code-only

Issues: naming, duplication, complexity, style, silent failures.

→ Codex fix: write a fix prompt containing the critic finding, target file, change to apply, and test command to a tmp file:
  `codex exec --full-auto - < "$_fix_prompt" > "$_fix_log" 2>&1; tail -200 "$_fix_log"; rm -f "$_fix_prompt" "$_fix_log"`
→ run tests → apply §Fix-chain finisher (steps 1–2 only; step 3 is handled by the shell loop)

## Spec gap

Issue: unhandled scenario revealed by review.

→ Add scenario to `spec.md`

→ Reset the critic-spec milestone and transition to `spec` phase (`reset-milestone` bumps `milestone_seq` so the new streak is isolated from prior verdicts; it also requires the current phase to equal the marker scope):
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "$CLAUDE_PROJECT_DIR/plans/{slug}.md" spec \
  "spec gap — resetting critic-spec milestone before re-review"
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "$CLAUDE_PROJECT_DIR/plans/{slug}.md" critic-spec
```
→ `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/run-critic-loop.sh" --agent critic-spec --phase spec --plan "$CLAUDE_PROJECT_DIR/plans/{slug}.md" --nested --prompt "Review spec at [spec-path]. Relevant docs: [doc-paths]."` — exit 0 → proceed; exit 1 → `[BLOCKED:{kind}]` written to plan — stop and report; exit 2 → `[BLOCKED:ceiling]` — manual review required.

→ Reset critic-cross milestone and re-run cross-feature consistency check (spec changes may affect cross-feature envelope compatibility):
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "$CLAUDE_PROJECT_DIR/plans/{slug}.md" critic-cross
```
→ `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/run-critic-loop.sh" --agent critic-cross --phase spec --plan "$CLAUDE_PROJECT_DIR/plans/{slug}.md" --nested --prompt "Cross-feature consistency review after spec gap fix. All specs: [all spec-paths]. Relevant docs: [doc-paths]."` — exit 0 → proceed; exit 1 → `[BLOCKED:{kind}]` written to plan — stop and report; exit 2 → `[BLOCKED:ceiling]` — manual review required.

→ Apply `@reference/phase-ops.md §Phase Rollback Procedure`: target-phase=`red`, critic=`critic-test`
→ Write failing test → `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/run-critic-loop.sh" --agent critic-test --phase red --plan "$CLAUDE_PROJECT_DIR/plans/{slug}.md" --nested --prompt "Review tests at [paths] against spec at [path]. Test command: [command]."` (§Phase Rollback already reset the milestone.) — exit 0 → proceed; exit 1 → `[BLOCKED:{kind}]` written to plan — stop and report; exit 2 → `[BLOCKED:ceiling]` — manual review required.
→ Advance to `implement`:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "$CLAUDE_PROJECT_DIR/plans/{slug}.md" implement \
  "spec gap test written — implementing fix"
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" commit-phase "$CLAUDE_PROJECT_DIR/plans/{slug}.md" \
  "chore(phase): advance to implement — spec gap fix"
```
→ Implement → apply §Fix-chain finisher (all 3 steps)

## Docs conflict

Issue: implementation contradicts domain rules.

→ Apply `@reference/phase-ops.md §DOCS CONTRADICTION cascade` (all steps including the **During `review` phase** section)

## Fix-chain finisher

1. **(If code changed)** Re-run critic-code:
   (a) **(If not already in `implement` phase)** Transition to `implement` (ensures `record-verdict` stamps `implement/critic-code`; without this, the plan may be in `review` and markers would be stamped `review/critic-code`, breaking convergence):
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "$CLAUDE_PROJECT_DIR/plans/{slug}.md" implement \
     "pr-review fix — re-running critic-code"
   ```
   (b) Reset critic-code milestone:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "$CLAUDE_PROJECT_DIR/plans/{slug}.md" critic-code
   ```
   → `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/run-critic-loop.sh" --agent critic-code --phase implement --plan "$CLAUDE_PROJECT_DIR/plans/{slug}.md" --nested --prompt "Review these files: [explicit list]. Spec at: [path]. Relevant docs: [paths]."` — exit 0 → proceed; exit 1 → `[BLOCKED:{kind}]` written to plan — stop and report; exit 2 → `[BLOCKED:ceiling]` — manual review required.

2. **(If not already in `review` phase)** Restore to `review`:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "$CLAUDE_PROJECT_DIR/plans/{slug}.md" review \
     "{fix description} — resuming pr-review"
   ```

3. Exit current iteration — the shell loop (`run-critic-loop.sh`) re-runs pr-review in the next iteration.
