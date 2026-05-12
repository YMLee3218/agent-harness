# Ultrathink Verdict Audit

Every verdict returned by a review subagent **must pass a parent-context ultrathink audit** before it is accepted. Run the audit immediately after `record-verdict` (or `append-review-verdict`) completes and **before** branching on `## Open Questions` markers (per `@reference/critics.md §Skill branching logic`).

## §Ultrathink verdict audit

### Audit checklist (fixed — apply to every verdict)

1. **Factual consistency** — for each FAIL finding in the Citation Summary: use the Read tool to open the cited file and verify the excerpt appears at that line. If the excerpt is absent, the finding is hallucinated. Record which citations were verified or absent.
   For `[MISSING]` findings: additionally Read the spec file and search for the scenario's core keywords. If found in the spec, that `[MISSING]` finding is a false positive — record it as such alongside the citation check results.
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
| **REJECT-PASS** | Subagent returned PASS but audit found a substantive gap | Call `clear-converged` (resets sidecar streak regardless of plan.md state), then record audit and enter FAIL path. **Ultrathink may demote PASS→FAIL but must never promote FAIL→PASS — except via ACCEPT-OVERRIDE when Read-tool verification confirms all cited excerpts are absent from their files (see §Audit outcomes).** |
| **BLOCKED-AMBIGUOUS** | Audit result is inconclusive | Append `[BLOCKED-AMBIGUOUS] {agent}: ultrathink audit inconclusive — {question}` to `## Open Questions` and stop |
| **ACCEPT-OVERRIDE** | Verdict is FAIL but every blocking finding is demonstrably false: either (a) its cited excerpt is absent from the cited file, or (b) it is a [MISSING] finding whose scenario keywords are confirmed present in the spec. If some findings are false and others are genuine, use BLOCKED-AMBIGUOUS instead. | Promote FAIL→PASS; append-audit with "ACCEPT-OVERRIDE" and list each absent citation. **Only when all blocking finding citations are absent — if some are absent but not all, use BLOCKED-AMBIGUOUS instead.** |

### Applying the audit outcome

Entries accumulate in `## Verdict Audits` (permanent trail — not compacted by `gc-events`). Each outcome section below is self-contained — call `append-audit` exactly once per audit run.

**ACCEPT**: record and proceed.
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-audit \
  "plans/{slug}.md" "{agent}" "ACCEPT" "{one-line summary}"
```
Proceed to `@reference/critics.md §Skill branching logic`.

**REJECT-PASS** — reset convergence streak before recording:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" clear-converged "plans/{slug}.md" "{agent}"
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-audit "plans/{slug}.md" "{agent}" "REJECT-PASS" "audit overrode PASS — {gap}"
```
Enter the FAIL path. (`clear-converged` writes a `REJECT-PASS` streak-reset entry to `## Critic Verdicts` and resets the sidecar — excluded from ceiling counts.)

**BLOCKED-AMBIGUOUS**: record, then stop.
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-audit \
  "plans/{slug}.md" "{agent}" "BLOCKED-AMBIGUOUS" "{one-line summary}"
```
Append `[BLOCKED-AMBIGUOUS] {agent}: ultrathink audit inconclusive — {question}` to `## Open Questions` and stop.

**ACCEPT-OVERRIDE**: record and proceed as PASS.
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-audit \
  "plans/{slug}.md" "{agent}" "ACCEPT-OVERRIDE" \
  "all {N} citations absent from files — verdict promoted to PASS"
```
Proceed to `@reference/critics.md §Skill branching logic` via the PASS path (re-run for convergence confirmation). ACCEPT-OVERRIDE is only valid when the Citation Summary is present and **every** blocking finding citation is absent from its file. If any citation verifies as present, fall back to BLOCKED-AMBIGUOUS.

**Non-interactive mode** (`CLAUDE_NONINTERACTIVE=1`): BLOCKED-AMBIGUOUS still stops. REJECT-PASS automatically enters the FAIL path. ACCEPT-OVERRIDE proceeds automatically (all citations absent — no ambiguity).
