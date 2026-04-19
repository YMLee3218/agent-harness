# Critics

> Single source for: critic preamble (verdict format, blocking rules), convergence policy, marker semantics, branching priority, review execution rules, ultrathink audit, running critics, blocked-state procedures, and phase rollback. Skills cite sections here by name.

Severity rules: @reference/severity.md
Layer rules: @reference/layers.md
Verification policy (non-existence claims require evidence): verify via WebSearch/WebFetch before claiming an API, flag, or model does not exist.

Language and verdict-marker language: @~/harness-builder/CLAUDE.md

Use only the explicit file list from the prompt. Do not derive paths from git history.

If invoked outside the `{name}` skill context (no parent skill orchestrating this run), refuse: output "ERROR: {name} must be invoked via the /{name} skill, not directly." and stop. (`{name}` = this agent's `name` field from its frontmatter.)

## §Verdict format

Severity levels, PASS/FAIL threshold, category priority, and finding labels: `@reference/severity.md` (single source of truth — do not duplicate here).

Every critic **must** end its output with a `### Verdict` section containing the HTML markers shown below. Output that does not end with these markers is recorded as `PARSE_ERROR` in the plan file.

**PASS**
```
### Verdict
PASS
<!-- verdict: PASS -->
<!-- category: NONE -->
```

**FAIL**
```
### Verdict
FAIL — {comma-separated list of blocking finding labels}
<!-- verdict: FAIL -->
<!-- category: {highest-priority category} -->
```

Rules:
- The verdict marker (`<!-- verdict: PASS|FAIL -->`) is always English; the explanatory summary follows @~/harness-builder/CLAUDE.md.
- On FAIL, emit one `<!-- category: {CATEGORY} -->` per @reference/severity.md §Category priority. If multiple root causes, choose the highest-severity one.
- Blocking consequence is critic-specific — see each critic SKILL.

| Verdict | Next action |
|---------|-------------|
| PASS | Proceed to next phase |
| FAIL | Orchestrating skill applies fixes, increments counter, re-runs this critic |
| PASS (ceiling hit) | Orchestrating skill checks `[BLOCKED-CEILING]` marker and stops |

Full iteration protocol: §Loop convergence.

---

Convergence-based protocol used by every phase-gate critic (critic-spec, critic-test, critic-code) and the pr-review step.

## Brainstorm exception

`critic-feature` uses a max-2 iteration guard (not the full convergence protocol): on the second consecutive FAIL, the brainstorming skill appends `[BLOCKED-FINAL] critic-feature failed twice — manual review required` to `## Open Questions` and stops.

**How `critic-feature` differs from other critics**:
- The SubagentStop hook **does** fire and **does** append the verdict to `## Critic Verdicts` via `plan-verdicts.sh record-verdict` (hook matcher in `settings.json` covers all four critics including `critic-feature`).
- `[BLOCKED-FINAL]` is emitted by the brainstorming skill (skill-side), not by the hook or script.
- Phase-scoped convergence markers (`@reference/markers.md §Phase-scoped convergence markers`) and the agent-scoped `[BLOCKED-CATEGORY]` / `[BLOCKED-PARSE]` markers are not emitted for `critic-feature` — the script skips the convergence/ceiling/category machinery for this agent.

## Consecutive same-category escalation

`plan-file.sh record-verdict` tracks the last FAIL category per critic (agent-scoped, phase-independent). If the same critic emits **two consecutive FAILs with the same category**, the script writes:

```
[BLOCKED-CATEGORY] {critic}: category {CATEGORY} failed twice — fix the root cause before retrying
```

to `## Open Questions` in the plan file, then exits 1. The skill reads the `[BLOCKED-CATEGORY]` marker and stops. The loop cannot converge when the same structural problem recurs; human review is required.

## Review execution rule (subagent mandate)

All phase-gate critics (`critic-feature`, `critic-spec`, `critic-test`, `critic-code`) and pr-review **must** run in isolated subagents. Generating a verdict inline in the parent context (i.e., executing review logic without spawning a subagent) is forbidden.

Normative implementations:

- **`critic-*` (4 variants)**: `skills/critic-*/SKILL.md` frontmatter `context: fork` + `agent: critic-*` + `workspace/agents/critic-*.md` definition.
- **`pr-review-toolkit:review-pr`**: The external plugin internally orchestrates `pr-review-toolkit:code-reviewer`, `…:pr-test-analyzer`, `…:silent-failure-hunter`, `…:comment-analyzer`, and `…:type-design-analyzer` subagents, so the isolation requirement is satisfied by the plugin definition.

**Prohibited**: any implementation that generates a verdict directly in the parent context without subagent isolation.

## Loop convergence

The loop terminates on **2 consecutive PASSes** (convergence), not on a single PASS. This filters lucky single-run PASSes caused by LLM non-determinism.

`plan-file.sh record-verdict` (and `append-review-verdict` for pr-review) automatically writes markers to `## Open Questions`. The skill reads these markers after each run and branches accordingly.

### Convergence markers in ## Open Questions

Full marker registry (scope, emitter, consumer, effect, clear path, written-by, gc): `@reference/markers.md §Critic loop markers`. Phase-scoped vs agent-scoped scope, FIRST-TURN and CONVERGED emission rules: `@reference/markers.md §Phase-scoped convergence markers`.

#### pr-review asymmetry

The pr-review fix loop (in `skills/implementing/SKILL.md §Step 5`) intentionally omits `[BLOCKED-CATEGORY]` and `[BLOCKED-PARSE]` from its marker table. pr-review failures are categorised by the skill itself (inferred from evidence), not by the category-tracking mechanism used for critics. `[BLOCKED-PARSE]` is not produced by `append-review-verdict`.

Effective pr-review branching order: steps 2 (`[BLOCKED-CATEGORY]`) and 4 (`[BLOCKED-PARSE]`) are skipped — apply §Skill branching logic with steps 1 → 3 → 5 → 6 → 7 → 8 → 10 → 11. Phase-match is required for all `[...] {phase}/pr-review` markers; PASS-only steps (CONFIRMED-FIRST / AUTO-APPROVED-FIRST / FIRST-TURN) skip to FAIL when the latest verdict is FAIL.

**Integration pipeline markers**: `@reference/markers.md §Integration test markers`. They do not interact with the critic convergence protocol above.

Ceiling N defaults to **5** (runs 1–5 are allowed; the 6th run triggers `[BLOCKED-CEILING]`). Override with env var `CLAUDE_CRITIC_LOOP_CEILING`.

### Skill branching logic (after each run)

```
After critic/review run → script records verdict + emits markers
Skill reads ## Open Questions, checks in priority order:

  1. [BLOCKED-CEILING] {phase}/{agent}  → stop (manual review)
  2. [BLOCKED-CATEGORY] {agent}         → stop (fix root cause)
  3. [BLOCKED-AMBIGUOUS] {agent}        → stop (human decision)
  4. [BLOCKED-PARSE] {agent}            → stop (investigate critic output format)
  5. [CONVERGED] {phase}/{agent}   → proceed to next step
  6. [CONFIRMED-FIRST] {phase}/{agent}     → re-run automatically (user confirmed in prior session)
                                             **Only when latest verdict is PASS or PARSE_ERROR.**
                                             If latest verdict is FAIL, skip to step 11.
  7. [AUTO-APPROVED-FIRST] {phase}/{agent} → re-run automatically
                                             (non-interactive: FIRST-TURN auto-approved in prior session)
                                             **Only when latest verdict is PASS or PARSE_ERROR.**
                                             If latest verdict is FAIL, skip to step 11.
  8. [FIRST-TURN] {phase}/{agent}          → confirm with user, then re-run
                                             (non-interactive: auto-approve + re-run)
                                             **Only when latest verdict is PASS or PARSE_ERROR.**
                                             If latest verdict is FAIL, skip to step 11.
                                             After user confirms, call record-confirmed-first:
                                               bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" \
                                                 record-confirmed-first "plans/{slug}.md" {agent}
  9. (no terminal marker, PARSE_ERROR in last ## Critic Verdicts entry)
                                   → re-run automatically (one retry allowed;
                                     second consecutive PARSE_ERROR triggers [BLOCKED-PARSE])
  10. (no terminal marker, PASS) → re-run automatically
  11. (no terminal marker, FAIL) → LLM determines fix direction:
       - direction is clear → apply fix + re-run
       - direction is ambiguous → append [BLOCKED-AMBIGUOUS] + stop
       - [DOCS CONTRADICTION] in critic output → interactive: AskUserQuestion ("docs or code?");
         non-interactive: append [BLOCKED-AMBIGUOUS] {agent}: DOCS CONTRADICTION — cannot
         determine whether docs or code is ground truth; human decision required and stop.
         Then follow §DOCS CONTRADICTION cascade.
```

## Non-interactive mode

Full non-interactive policy: @reference/non-interactive-mode.md §Critic loop behaviour

## Hook exit codes

`0`=allow stop, `2`=block stop (stderr fed back to Claude as context), `1`/other=non-blocking error. Use `exit 2` (never `exit 1`) to prevent Claude from stopping. Implementation: `scripts/stop-check.sh`.

---

## Ultrathink verdict audit

Every verdict returned by a review subagent **must pass a parent-context ultrathink audit** before it is accepted. Run the audit immediately after `record-verdict` (or `append-review-verdict`) completes and **before** branching on `## Open Questions` markers (§Skill branching logic).

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
| **ACCEPT** | Verdict is sound | Adopt verdict as-is; proceed to §Skill branching logic |
| **REJECT-PASS** | Subagent returned PASS but audit found a substantive gap | Call `clear-converged` (if `[CONVERGED]` marker exists), then record audit and enter FAIL path. **Ultrathink may demote PASS→FAIL but must never promote FAIL→PASS.** |
| **BLOCKED-AMBIGUOUS** | Audit result is inconclusive | Append `[BLOCKED-AMBIGUOUS] {agent}: ultrathink audit inconclusive — {question}` to `## Open Questions` and stop |

### Applying the audit outcome

Apply audit outcomes for `{agent}` using these commands (substitute the real agent name):

**ACCEPT**:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-audit \
  "plans/{slug}.md" "{agent}" "ACCEPT" "{one-line summary}"
```
Proceed to §Skill branching logic.

**REJECT-PASS** — `record-verdict` runs before the parent sees the verdict, so `[CONVERGED]` may already be written. Clear it first, then record the override:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" clear-converged \
  "plans/{slug}.md" "{agent}"
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-audit \
  "plans/{slug}.md" "{agent}" "REJECT-PASS" "audit overrode PASS — {one-line gap description}"
```
Enter the FAIL path. (If no `[CONVERGED]` marker exists, `clear-converged` is a safe no-op. For agents not listed in VALID_CRITIC_AGENTS (e.g. `critic-feature`), skip `clear-converged` entirely — it will error, not no-op.)

**BLOCKED-AMBIGUOUS**:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-audit \
  "plans/{slug}.md" "{agent}" "BLOCKED-AMBIGUOUS" "{question}"
```
Append `[BLOCKED-AMBIGUOUS] {agent}: ultrathink audit inconclusive — {question}` to `## Open Questions` and stop.

**Non-interactive mode** (`CLAUDE_NONINTERACTIVE=1`): BLOCKED-AMBIGUOUS still stops. REJECT-PASS automatically enters the FAIL path without user confirmation.

### Audit trail

Record every audit outcome in the plan file:

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-audit \
  "plans/{slug}.md" "{agent}" "{ACCEPT|REJECT-PASS|BLOCKED-AMBIGUOUS}" "{one-line summary}"
```

Entries accumulate in `## Verdict Audits` (permanent trail — not compacted by `gc-events`).

## Running the critic

Invoke the critic skill with the relevant paths. The `SubagentStop` hook fires `plan-file.sh record-verdict` automatically when the critic agent exits — do **not** call `record-verdict` manually (doing so would double-record the run, inflating the streak and ceiling counters). For pr-review (which is not a subagent), call `append-review-verdict` directly after the pr-review skill returns.

After `record-verdict` (or `append-review-verdict`) completes, run the ultrathink audit (§Ultrathink verdict audit above), then read `## Open Questions` for the markers listed in §Skill branching logic and branch accordingly.

### New milestone

Before starting a critic run for a new milestone within the same phase, call:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "plans/{slug}.md" {agent}
```
This clears the 5 phase-scoped convergence markers (see `@reference/markers.md §Phase-scoped convergence markers`) for this phase+agent from `## Open Questions`, and appends a `[MILESTONE-BOUNDARY]` sentinel to `## Critic Verdicts` so prior-milestone history does not contribute to the new streak. `set-phase` must run before `reset-milestone` when also changing phase, so `reset-milestone` reads the correct phase when clearing phase-scoped markers. For the full list of markers written and cleared by `reset-milestone`, `reset-pr-review`, and `reset-for-rollback`, see `reference/markers.md §Operation → markers reverse lookup`.

### Full rollback reset

For integration failure or unit-test failure before integration: use `reset-for-rollback` to atomically set phase, run `reset-milestone critic-code`, run `reset-pr-review`, and clear stale `review/critic-code` markers in one call:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-for-rollback "plans/{slug}.md" {target-phase}
```

## Ambiguity signaling

When a FAIL leaves the fix direction unclear, do **not** guess. Append a `[BLOCKED-AMBIGUOUS]` marker to `## Open Questions` and stop:

```
[BLOCKED-AMBIGUOUS] {agent}: {one-sentence question for the human}
```

**Conditions that require human input** (LLM must not resolve unilaterally):

- **Multiple valid fix paths**: "Should docs be updated to match code, or code fixed to match docs?" (classic DOCS_CONTRADICTION split)
- **Contradictory requirements**: spec and docs conflict, and which is ground truth is unclear
- **Scope expansion needed**: the fix requires changes outside this feature's scope
- **Repeated failure with unknown cause**: the same problem recurs across runs and the root cause cannot be identified

If none of the above apply, fix and re-run without stopping.

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

## Resuming from a BLOCKED-* marker

All three (`[BLOCKED-AMBIGUOUS]`, `[BLOCKED-PARSE]`, `[BLOCKED-CATEGORY]`) are agent-scoped and do not clear on phase transition or `reset-milestone`. Rationale and lifecycle: `@reference/markers.md §Implementation notes`.

### Root cause per marker

| Marker | What to fix |
|--------|-------------|
| `[BLOCKED-AMBIGUOUS]` | Resolve the question stated in the marker (update docs, code, or spec). If the fix changes spec or tests, roll back phase first (§Phase Rollback Procedure) before re-running. |
| `[BLOCKED-PARSE]` | Investigate missing `<!-- verdict: -->` marker (common causes: agent ran out of turns, truncated output, model change). Fix root cause. |
| `[BLOCKED-CATEGORY]` | Inspect consecutive same-category FAILs in `## Critic Verdicts`; address the structural cause (refactor, spec change, layer fix — not a surface tweak). |

### Clear the marker and re-run

After fixing the root cause, clear the marker:

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" clear-marker "plans/{slug}.md" "[BLOCKED-{TYPE}] {agent}"
```

Re-run the critic. If streak reset needed (BLOCKED-PARSE or BLOCKED-CATEGORY): `reset-milestone "plans/{slug}.md" {agent}` (separate call — `reset-milestone` does NOT clear any `[BLOCKED-*]` marker).

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
