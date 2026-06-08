# Ultrathink Verdict Audit

Every verdict returned by a review process **must pass an ultrathink audit** before it is accepted.

**Shell-driven critics (critic-spec/test/code/cross)**: `run-critic-loop.sh` runs the audit as a separate Claude decision-agent call on every FAIL, and as a minimal REJECT-PASS check on the convergence-triggering (2nd consecutive) PASS. On non-converging PASS iterations no audit is run. The decision agent is invoked with `build_decision_prompt` output and must apply all 6
§Audit checklist items: Read the review log and cited files for citation verification (item 1),
Read the spec for coverage gap checks (item 2), assess fix direction (item 3), false-positive
and false-negative risk (item 4), category accuracy against severity.md (item 5), and
per-finding decidability classification (item 6).
The convergence-triggering PASS check reads both the review log and spec to verify items 2 and 4.

**critic-feature (B-session)**: run the audit immediately after `record-verdict` completes and **before** branching on `## Open Questions` markers (per `@reference/critics.md §Skill branching logic`).

**pr-review**: `append-review-verdict` is recorded by the shell after the session exits; the in-session equivalent checkpoint is after outputting the nonce-anchored verdict marker in step 2 of `@reference/pr-review-loop.md`. Do NOT call `append-review-verdict` in-session.

## §Ultrathink verdict audit

### Audit checklist (fixed — apply to every verdict)

1. **Factual consistency** — for each FAIL finding in the Citation Summary: use the Read tool to open the cited file and verify the excerpt appears at that line. If the excerpt is absent, the finding is hallucinated. Record which citations were verified or absent.
   For `[MISSING]` findings: additionally Read the spec file and search for the scenario's core keywords. If found in the spec, that `[MISSING]` finding is a false positive — record it as such alongside the citation check results.
2. **Coverage gaps** — are there scenarios or boundary cases in the spec/docs that the verdict did not address?
3. **Fix direction** — on FAIL, does the proposed fix target the root cause or is it a workaround?
4. **False positive/negative risk** — is a PASS genuinely comprehensive, or is it a conventional rubber-stamp?
5. **Category accuracy** — does `<!-- category: X -->` reflect the true highest-severity finding per `@reference/severity.md §Category priority`?
6. **Per-finding decidability** — classify each blocking FAIL finding as one of: GENUINE (correct, fix direction determinable from audit evidence), FALSE-POSITIVE (citation absent or [MISSING] keyword present per item 1), AMBIGUOUS (plausibly correct but fix direction requires evidence outside the spec under review).

### Audit prompt

Include `ultrathink` in the audit prompt and check all items in §Audit checklist against the spec and source paths.

### Audit outcomes

| Outcome | Condition | Action |
|---------|-----------|--------|
| **ACCEPT** | All findings GENUINE, or GENUINE + FALSE-POSITIVE mix with no AMBIGUOUS (item 6) | Adopt verdict; fix only GENUINE findings (FALSE-POSITIVE findings excluded from fix scope); proceed to `@reference/critics.md §Skill branching logic` |
| **REJECT-PASS** | Subagent returned PASS but audit found a substantive gap | Call `clear-converged` (resets sidecar streak regardless of plan.md state), then record audit and enter FAIL path. **Ultrathink may demote PASS→FAIL but must never promote FAIL→PASS — except via ACCEPT-OVERRIDE when Read-tool verification confirms all cited excerpts are absent from their files (see §Audit outcomes).** |
| **BLOCKED-AMBIGUOUS** | AMBIGUOUS ≥ 1 (per item 6) | Emit one `[BLOCKED:spec] {agent}: ambiguous — {finding-excerpt}: {audit-question}` marker per AMBIGUOUS finding. If GENUINE findings are also present, apply Codex fix for GENUINE findings only, then stop. |
| **ACCEPT-OVERRIDE** | Verdict is FAIL and ALL blocking findings are demonstrably false: every finding satisfies either (a) its cited excerpt is absent from the cited file, or (b) it is a [MISSING] finding whose scenario keywords are confirmed present in the spec. | Exit without applying fixes (branching decision only — no sidecar state change for phase-gate critics; pr-review: additionally emit nonce marker to override recorded verdict); append-audit with "ACCEPT-OVERRIDE" and list each absent citation. |

### Applying the audit outcome

Entries accumulate in `## Verdict Audits` (permanent trail — not compacted by `gc-events`). Each outcome section below is self-contained — call `append-audit` exactly once per audit run.

**ACCEPT**: record and proceed.
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-audit \
  "$CLAUDE_PROJECT_DIR/plans/{slug}.md" "{agent}" "ACCEPT" "{one-line summary}"
```
Proceed to `@reference/critics.md §Skill branching logic`.

**REJECT-PASS** — reset convergence streak before recording:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" clear-converged "$CLAUDE_PROJECT_DIR/plans/{slug}.md" "{agent}"
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-audit "$CLAUDE_PROJECT_DIR/plans/{slug}.md" "{agent}" "REJECT-PASS" "audit overrode PASS — {gap}"
```
Enter the FAIL path. (`clear-converged` writes a `REJECT-PASS` streak-reset entry to `## Critic Verdicts` and resets the sidecar — excluded from ceiling counts.)

**BLOCKED-AMBIGUOUS**: apply GENUINE fixes first, then emit per-finding markers, then stop.

1. Record audit with GENUINE and AMBIGUOUS finding IDs (use "Finding N" labels from the audit body):
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-audit \
  "$CLAUDE_PROJECT_DIR/plans/{slug}.md" "{agent}" "BLOCKED-AMBIGUOUS" \
  "{one-line summary} | GENUINE: [Finding N, ...] | AMBIGUOUS: [Finding M, ...]"
```
2. If GENUINE findings exist, build a Codex fix prompt scoped to **only** those findings (exclude AMBIGUOUS findings from fix scope) and apply now — before emitting any `[BLOCKED:spec]` markers (the pre-tool hook blocks Bash writes once a `[BLOCKED:spec]` marker is present):
```bash
codex exec --full-auto - < "$_fix_prompt" > "$_fix_log" 2>&1; tail -200 "$_fix_log"; rm -f "$_fix_prompt" "$_fix_log"
```
3. For each AMBIGUOUS finding, check whether the exact marker text already exists in `## Open Questions`; if not, append:
   `[BLOCKED:spec] {agent}: ambiguous — {finding-excerpt}: {audit-question}`
4. Stop — do not re-run the critic. The `[BLOCKED:spec]` markers halt the loop at `@reference/critics.md §Skill branching logic` step 2.

**ACCEPT-OVERRIDE**: record, re-run once (phase-gate critics only), then exit without applying any fix.
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-audit \
  "$CLAUDE_PROJECT_DIR/plans/{slug}.md" "{agent}" "ACCEPT-OVERRIDE" \
  "all {N} citations absent from files — verdict promoted to PASS"
```
For **phase-gate critics** (`critic-code`, `critic-spec`, `critic-test`, `critic-cross`, `critic-feature`): immediately re-run `Skill("{agent}", "{prompt}")` once within this session before exiting. This avoids a wasted loop iteration when citations were hallucinated. If the re-run produces FAIL again with all citations still absent, treat as ACCEPT-OVERRIDE again and exit without a second re-run.
Exit this session immediately after the (optional) re-run — do **not** apply step 8 (FAIL-path) fixes. For **pr-review only**: also emit `<!-- review-verdict: {nonce} PASS -->` per `@reference/pr-review-loop.md §PR-review one-shot iteration` step 3 immediately after the `append-audit` call; `run-critic-loop.sh` captures the last nonce-anchored marker, overriding the recorded FAIL. For **phase-gate critics** (`critic-code`, `critic-spec`, `critic-test`, `critic-cross`, `critic-feature`): there is no nonce mechanism — the sidecar retains the original FAIL verdict; the shell loop re-runs and should produce PASS (citations were absent). Do not look at `## Critic Verdicts` to determine the branch after ACCEPT-OVERRIDE — the explicit instruction to exit (without fix) overrides the mechanical §Skill branching logic step 8. ACCEPT-OVERRIDE is only valid when the Citation Summary is present and every blocking finding satisfies (a) its cited excerpt is absent from the cited file, or (b) it is a [MISSING] finding whose scenario keywords are confirmed present in the spec. If any finding is GENUINE, use ACCEPT. If any finding is AMBIGUOUS, use BLOCKED-AMBIGUOUS.

**Non-interactive mode** (`CLAUDE_NONINTERACTIVE=1`): BLOCKED-AMBIGUOUS still stops. REJECT-PASS automatically enters the FAIL path. ACCEPT-OVERRIDE proceeds automatically (all citations absent — no ambiguity).
