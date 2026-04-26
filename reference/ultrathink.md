# Ultrathink Verdict Audit

Every verdict returned by a review subagent **must pass a parent-context ultrathink audit** before it is accepted. Run the audit immediately after `record-verdict` (or `append-review-verdict`) completes and **before** branching on `## Open Questions` markers (per `@reference/critics.md §Skill branching logic`).

## §Ultrathink verdict audit

### Audit checklist (fixed — apply to every verdict)

1. **Factual consistency** — do the subagent's evidence paths and line numbers match the actual files?
2. **Coverage gaps** — are there scenarios or boundary cases in the spec/docs that the verdict did not address?
3. **Fix direction** — on FAIL, does the proposed fix target the root cause or is it a workaround?
4. **False positive/negative risk** — is a PASS genuinely comprehensive, or is it a conventional rubber-stamp?
5. **Category accuracy** — does `<!-- category: X -->` reflect the true highest-severity finding per `@reference/severity.md §Category priority`?

### Audit prompt

Include `ultrathink` in the audit prompt and check the five items in §Audit checklist against the spec and source paths.

### Audit outcomes

| Outcome | Condition | Action |
|---------|-----------|--------|
| **ACCEPT** | Verdict is sound | Adopt verdict as-is; proceed to `@reference/critics.md §Skill branching logic` |
| **REJECT-PASS** | Subagent returned PASS but audit found a substantive gap | Call `clear-converged` (if `[CONVERGED]` marker exists), then record audit and enter FAIL path. **Ultrathink may demote PASS→FAIL but must never promote FAIL→PASS.** |
| **BLOCKED-AMBIGUOUS** | Audit result is inconclusive | Append `[BLOCKED-AMBIGUOUS] {agent}: ultrathink audit inconclusive — {question}` to `## Open Questions` and stop |

### Applying the audit outcome

Entries accumulate in `## Verdict Audits` (permanent trail — not compacted by `gc-events`). Each outcome section below is self-contained — call `append-audit` exactly once per audit run.

**ACCEPT**: record and proceed.
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-audit \
  "plans/{slug}.md" "{agent}" "ACCEPT" "{one-line summary}"
```
Proceed to `@reference/critics.md §Skill branching logic`.

**REJECT-PASS** — `[CONVERGED]` may already be written; clear it first, then record:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" clear-converged "plans/{slug}.md" "{agent}"
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-audit "plans/{slug}.md" "{agent}" "REJECT-PASS" "audit overrode PASS — {gap}"
```
Enter the FAIL path. (`clear-converged` is a safe no-op if no `[CONVERGED]` marker exists.)

**BLOCKED-AMBIGUOUS**: record, then stop.
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-audit \
  "plans/{slug}.md" "{agent}" "BLOCKED-AMBIGUOUS" "{one-line summary}"
```
Append `[BLOCKED-AMBIGUOUS] {agent}: ultrathink audit inconclusive — {question}` to `## Open Questions` and stop.

**Non-interactive mode** (`CLAUDE_NONINTERACTIVE=1`): BLOCKED-AMBIGUOUS still stops. REJECT-PASS automatically enters the FAIL path.
