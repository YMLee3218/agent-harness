# Critics

> Single source for: verdict format, critic blocking rules, convergence policy, branching priority, review execution rules, running critics, blocked-state procedures. Phase ops: `@reference/phase-ops.md`. Ultrathink audit: `@reference/ultrathink.md`. PR-review fix loop: `@reference/pr-review-loop.md`.

Severity rules: @reference/severity.md
Layer rules: @reference/layers.md
Language and verdict-marker language: @reference/language.md

Use only the explicit file list from the prompt. Do not derive paths from git history.

If invoked outside the `{name}` skill context (no parent skill orchestrating this run), refuse: output "ERROR: {name} must be invoked via the /{name} skill, not directly." and stop. (`{name}` = this agent's `name` field from its frontmatter.)

## §Verdict format

Severity levels, PASS/FAIL threshold, category priority, and finding labels: `@reference/severity.md` (single source of truth — do not duplicate here).

Every critic **must** end its output with a `### Verdict` section containing the HTML markers shown below. Output that does not contain these markers is recorded as `PARSE_ERROR` in the plan file. (The parser accepts the last occurrence of the markers anywhere in the transcript — trailing text after the markers does not cause a PARSE_ERROR, but critics should still place markers at the end for clarity.)

**PASS**
```
### Verdict
PASS
<!-- verdict: PASS -->
<!-- category: NONE -->
```
(`<!-- category: NONE -->` is required when a category marker is present on PASS; a PASS with no category marker at all is also accepted. A non-NONE category on PASS is a `PARSE_ERROR`.)

**FAIL**
```
### Verdict
FAIL — {comma-separated list of blocking finding labels}
<!-- verdict: FAIL -->
<!-- category: {highest-priority category} -->
```

A **FAIL** verdict must include a `<!-- category: X -->` marker. A FAIL that has a verdict marker but no category marker is recorded as PARSE_ERROR; on the second consecutive occurrence `[BLOCKED:code] {agent}: parse` is set. Verdict calibration: false PASS → production defect (cost 10×); false FAIL → one extra iteration (cost 1×). When evidence is ambiguous, FAIL.

The `<!-- category: X -->` value on a FAIL MUST be copied verbatim from the `→ category:` annotation on the check/angle that fired. Descriptive synonyms (e.g. `COMPLETENESS`, `CONSISTENCY`, `CORRECTNESS`) are not enum members and produce `PARSE_ERROR`. On `PASS`, X MUST be `NONE`. If a finding genuinely has no matching enum value (not a synonym), do not invent a category — emit closest-fit in the verdict and append `[BLOCKED:harness] {critic-name}: reference-extension — ...` to `## Open Questions`. Full procedure: `@reference/severity.md §Enum-extension escape`.

**Structural validity guards** (enforced by `plan-file.sh record-verdict` — see `@reference/severity.md` for enum values):
- **Invalid category**: `<!-- category: X -->` where X is not in the severity.md enum → `PARSE_ERROR` (auto-retry; second consecutive → `[BLOCKED:code] {agent}: parse`).
- **Non-NONE category on PASS**: `<!-- category: X -->` where X is not `NONE` on a `<!-- verdict: PASS -->` → `PARSE_ERROR` (same escalation).
- **FAIL without blocking finding**: `<!-- verdict: FAIL -->` but no blocking-label finding (`[CRITICAL]`, `[MISSING]`, `[MANIFEST-GAP]`, `[FAIL]`, `[DOCS CONTRADICTION]`, or `[UNVERIFIED CLAIM]`) in the output → `PARSE_ERROR` (same escalation). Every FAIL must include at least one blocking finding.

Full iteration protocol: §Loop convergence.

## Consecutive same-category escalation

`plan-file.sh record-verdict` tracks the last FAIL category per critic (agent-scoped, milestone-scoped — the streak resets on `reset-milestone` and is computed within the current phase+milestone boundary). If the same critic emits **two consecutive FAILs with the same category** (PARSE_ERROR verdicts between them are transparent — they do not reset the streak; `reset-milestone` writes a `[MILESTONE-BOUNDARY @ts]` sentinel that **does** reset the streak — streaks are therefore isolated per milestone), the script writes a **non-halting advisory**:

```
[RECURRING] {agent}: {CATEGORY} flagged 2× consecutively — next fix must resolve the root cause behind every {CATEGORY} finding, not only the latest
```

to `## Open Questions` (self-superseding — at most one `[RECURRING]` per agent). The loop continues normally; no `[BLOCKED:code]` is written and `blocked.jsonl` is not updated. Hard stops from §Skill branching logic still apply; RECURRING adds no new stop conditions. `gc-events` removes stale `[RECURRING]` lines; `reset-milestone` clears them at milestone boundaries.

## Review execution rule (subagent mandate)

All phase-gate critics (`critic-feature`, `critic-spec`, `critic-test`, `critic-code`, `critic-cross`) and pr-review **must** run in isolated subagents. Generating a verdict inline in the parent context (i.e., executing review logic without spawning a subagent) is forbidden.

Normative implementations:

- **`critic-*` (5 variants)**: `skills/critic-*/SKILL.md` frontmatter `context: fork` + `agent: critic-*` + `agents/critic-*.md` definition.
- **`pr-review-toolkit:review-pr`**: The external plugin internally orchestrates `pr-review-toolkit:code-reviewer`, `…:pr-test-analyzer`, `…:silent-failure-hunter`, `…:comment-analyzer`, and `…:type-design-analyzer` subagents, so the isolation requirement is satisfied by the plugin definition.

**Prohibited**: any implementation that generates a verdict directly in the parent context without subagent isolation.

## Loop convergence

Convergence-based protocol used by every phase-gate critic (critic-feature, critic-spec, critic-test, critic-code, critic-cross) and the pr-review step. Convergence state is stored exclusively in `plans/{slug}.state/convergence/{phase}__{agent}.json` — updated on every verdict by `_record_loop_state`; `converged=true` requires 2 consecutive PASSes (see `@reference/markers.md §Sidecar control state`). A PARSE_ERROR between two PASSes resets the streak: `PASS → PARSE_ERROR → PASS` = streak 1. Query via `plan-file.sh is-converged <plan> <phase> <agent>` (exit 0 = converged). No plan.md marker mirrors this state.

`plan-file.sh record-verdict` appends to `## Critic Verdicts` and updates sidecar convergence state for all normal verdict outcomes (PASS, FAIL, PARSE_ERROR); in exceptional cases it writes a `[BLOCKED]` marker to `## Open Questions` — second consecutive PARSE_ERROR → `[BLOCKED:code] {agent}: parse` (skips the Critic Verdicts append for this case — only sidecar + Open Questions); ceiling exceeded → `[BLOCKED:ceiling]` (appends to both `## Critic Verdicts` and `## Open Questions`). Exception: if the subagent produced no output or known infrastructure error signatures are detected, record-verdict classifies the run as `[BLOCKED:env] {agent}: critic-skill-not-run` — it writes only to `## Open Questions` and `blocked.jsonl`; no Critic Verdicts entry is written and convergence state is not updated (the run is not counted against the ceiling). The skill reads `## Open Questions` for any BLOCKED markers and queries sidecar after each run, then branches per §Skill branching logic. For pr-review, `run-critic-loop.sh` extracts `<!-- review-verdict: {nonce} PASS|FAIL -->` from stdout and calls `append-review-verdict` on the parent side.

**pr-review exception**: omits category/parse — apply steps 1 → 4–5 → 7 → 8 only (see `@reference/pr-review-loop.md`); use `plan-file.sh is-converged` for step 4. Integration pipeline markers (`@reference/markers.md §Integration test markers`) do not interact with this protocol.

Ceiling N defaults to **20** (runs 1–20 are allowed; the 21st run triggers `[BLOCKED:ceiling]`; PARSE_ERROR verdicts count toward this ceiling — the transparency at §Consecutive same-category escalation applies only to streak resetting, not to ceiling counting; `REJECT-PASS` entries written by `clear-converged` do **not** count). Override with env var `CLAUDE_CRITIC_LOOP_CEILING`.

### Skill branching logic (after each run)

```
After critic/review run → script records verdict + emits markers
Skill reads ## Open Questions and queries sidecar, checks in priority order:

  1. [BLOCKED:ceiling] {agent}: ...   → stop (manual review; use reset-milestone)
  2. [BLOCKED:spec] {agent}: ambiguous → stop (human decision required)
  3. [BLOCKED:docs] {agent}: ...      → stop (human decision required; apply DOCS CONTRADICTION cascade)
  4. [BLOCKED:{any kind}] ...         → stop (read reason; fix root cause; run unblock; retry)
  5. is-converged exits 0             → proceed to next step
  6. (no terminal marker, PARSE_ERROR in last ## Critic Verdicts entry)
                                → re-run automatically (one retry allowed;
                                  second consecutive PARSE_ERROR triggers [BLOCKED:code] {agent}: parse)
  7. (no terminal marker, PASS) → re-run automatically
  8. (no terminal marker, FAIL) → if `[RECURRING] {agent}:` is in `## Open Questions`, the Codex
       fix prompt must address all findings of that category at root-cause level, not only the latest.
       LLM determines fix direction:
       - direction is clear → construct Codex fix prompt (critic finding, target file,
         change to apply, test command, layer rules if applicable); write to tmp file:
           codex exec --full-auto - < "$_fix_prompt" > "$_fix_log" 2>&1; tail -200 "$_fix_log"; rm -f "$_fix_prompt" "$_fix_log"
         → re-run critic
       - direction is ambiguous → append [BLOCKED:spec] {agent}: ambiguous — {question} + stop
       - [DOCS CONTRADICTION] in critic output → treat docs/*.md as ground truth; fix code (and spec) to match. If fixing code would itself require changing docs (stale requirements), direction is ambiguous → append [BLOCKED:docs] {agent}: contradiction — docs may be stale, ground truth ambiguous; apply cascade + stop; follow `@reference/phase-ops.md §DOCS CONTRADICTION cascade`.
     ENVELOPE_MISMATCH / ENVELOPE_OVERREACH are ordinary FAIL categories — no
     envelope-specific branch. They resolve through the three branches above:
       - an axis derivable from the spec body, or a scenario overreaching a
         correct envelope (shrink the scenario, per @reference/effort.md) →
         clear → fix, then the critic re-run validates;
       - an axis the spec body does not determine, or a scenario that may be a
         real requirement whose resolution (widen the envelope vs drop the
         scenario) the loop cannot decide → ambiguous → [BLOCKED:spec];
       - an ENVELOPE_MISMATCH FAIL whose finding text says the envelope
         contradicts docs/*.md (the category is ENVELOPE_MISMATCH, not a
         literal [DOCS CONTRADICTION]) — it is a ground-truth decision; apply
         the [DOCS CONTRADICTION] branch by the finding text → [BLOCKED:docs].
```

---

## Running the critic

Invoke the critic skill with the relevant paths. The `SubagentStop` hook fires `plan-file.sh record-verdict-guarded` automatically when the critic agent exits — do **not** call `record-verdict` or `record-verdict-guarded` manually (doing so would double-record the run, inflating the streak and ceiling counters). For pr-review, `run-critic-loop.sh` records the verdict automatically by extracting the nonce-anchored `<!-- review-verdict: {nonce} PASS|FAIL -->` marker from the spawned session's stdout — do **not** call `append-review-verdict` manually either.

**B-session only** (invoked by `run-critic-loop.sh` as a `claude -p` one-shot): `Skill("{agent}", "{prompt}")` runs the critic subagent synchronously — the subagent completes and the `SubagentStop` hook records the verdict within the **same turn**. Do **not** end the turn after invoking Skill; do **not** run the call in the background; do **not** wait for a completion notification — `claude -p` has no subsequent turn. Ending the turn early orphans the subagent and any child Codex processes, causing a verdict-less `PARSE_ERROR`. After `Skill(...)` returns, proceed immediately to the ultrathink audit and branching within the same turn before exiting.

After `record-verdict` (or `append-review-verdict`) completes, run `@reference/ultrathink.md §Ultrathink verdict audit`, then read `## Open Questions` for the markers listed in §Skill branching logic and branch accordingly. The B-session for each `run-critic-loop.sh` iteration runs the audit internally — `§Critic one-shot iteration` step 2 for the five critic subagents, `pr-review-loop.md §PR-review one-shot iteration` step 3 for pr-review — so the orchestrator that called `run-critic-loop.sh` must **not** re-run the audit after the loop returns. (Direct critic invocations are not a remaining code path: the `record-verdict-guarded` SubagentStop hook at settings.json rejects any critic-subagent run outside `run-critic-loop.sh`.)

**Exit codes**: 0 = converged; 1 = blocked (`[BLOCKED:{kind}]` marker in plan, or transient retry); 2 = `[BLOCKED:ceiling]`; 3 = lock contention, **non-nested invocations only** (another run already active for this plan — wait for it to finish or remove the plan's `.critic.lock` file (e.g. `plans/{slug}.md.critic.lock`)); recovery cascades using `--nested` silently inherit any existing lock and never return exit 3; any other code is a script failure: write `[BLOCKED:env] {agent}: script-failure — exit {code}` to `## Open Questions` and stop. Running critics manually is not a fallback — it is a protocol violation.
### New milestone

Before starting a critic run for a new milestone within the same phase, call:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "$CLAUDE_PROJECT_DIR/plans/{slug}.md" {agent}
```
This clears the 1 phase-scoped convergence marker (`[BLOCKED:ceiling]`) (see `@reference/markers.md §Phase-scoped convergence markers`) for this phase+agent from `## Open Questions`, and appends a `[MILESTONE-BOUNDARY]` sentinel to `## Critic Verdicts` so prior-milestone history does not contribute to the new streak. `transition` must run before `reset-milestone` when also changing phase (`transition` calls `set-phase` internally and writes a Phase Transitions log entry; using `plan-file.sh set-phase` directly would skip the log entry), so `reset-milestone` reads the correct phase when clearing phase-scoped markers. For the full list of markers written and cleared by `reset-milestone`, `reset-pr-review`, and `reset-for-rollback`, see `reference/markers.md §Stop marker taxonomy`.

Re-brainstorming the same requirements doc: transition to `brainstorm` first (required before `reset-milestone` so the correct phase-scoped markers are cleared — see line above), then reset the prior critic-feature streak:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "$CLAUDE_PROJECT_DIR/plans/{slug}.md" brainstorm \
  "re-brainstorming"
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "$CLAUDE_PROJECT_DIR/plans/{slug}.md" critic-feature
```
Then re-invoke the `brainstorming` skill.

### Full rollback reset

For integration failure or unit-test failure before integration: call `transition` first to log the rollback reason in Phase Transitions, then `reset-for-rollback` to atomically set phase, run `reset-milestone critic-code`, run `reset-pr-review`, and clear stale `review/critic-code` markers:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "$CLAUDE_PROJECT_DIR/plans/{slug}.md" {target-phase} \
  "{one sentence reason}"
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-for-rollback "$CLAUDE_PROJECT_DIR/plans/{slug}.md" {target-phase}
```

When the cleanup phase differs from the destination phase (e.g., clearing `implement` markers while rolling back to `red`): use a 3-call sequence — `transition {cleanup-phase}`, `reset-for-rollback {cleanup-phase}`, then `transition {destination-phase}`. This is necessary because `reset-for-rollback` calls `set-phase` internally, which would overwrite a prior `transition {destination-phase}`. After `transition {destination-phase}`, additionally call `reset-milestone {destination-critic}` if a prior milestone's sidecar streak needs resetting (e.g., rolling back to `red` may require `reset-milestone critic-test` to isolate the new streak). When a milestone must be reset at a non-destination phase (e.g., resetting `red/critic-test` while destination is `spec`): use a phase round-trip — `transition {milestone-phase}`, `reset-milestone {milestone-critic}`, `transition {destination-phase}` — because `reset-milestone` scopes to the current plan phase (implemented by `run-integration.sh`'s spec-gap recovery path).

## §Critic one-shot iteration

One iteration for a `claude` CLI session from `run-critic-loop.sh`. Do **not** loop — one critic run per session. Steps 1 and 2 execute in a single continuous turn — no turn boundary between them.
0. **Pre-fix** (only when `prior_fail_log={path}` in prompt): read the log; for each FAIL finding, apply a Codex fix if direction is clear — skip findings where direction is ambiguous (those will re-surface in step 1). Run one fix prompt per clear finding group. Proceed to step 1 regardless of Codex outcome.
1. `Skill("{agent}", "{prompt}")` — synchronous; `SubagentStop` fires `record-verdict-guarded` automatically when the subagent exits. Do not end the turn here.
2. `@reference/ultrathink.md §Ultrathink verdict audit`. Then read `## Open Questions` per §Skill branching logic — **exception**: this session never re-runs (steps 6 and 7 hand their re-run back to the shell loop; step 8 / FAIL is executed by this session before exiting); exit after each branching action.

## Ambiguity signaling

When a FAIL leaves the fix direction unclear, do **not** guess. Append a `[BLOCKED:spec]` or `[BLOCKED:docs]` marker to `## Open Questions` and stop:

```
[BLOCKED:spec] {agent}: ambiguous — {one-sentence question for the human}
[BLOCKED:docs] {agent}: contradiction — docs may be stale, ground truth ambiguous; apply cascade
```

**Conditions that require human input** (LLM must not resolve unilaterally):

- **Multiple valid fix paths**: "Should docs be updated to match code, or code fixed to match docs?" (classic DOCS_CONTRADICTION split → use `[BLOCKED:docs]`)
- **Contradictory requirements**: spec and docs conflict, and which is ground truth is unclear (→ `[BLOCKED:docs]`)
- **Scope expansion needed**: the fix requires changes outside this feature's scope (→ `[BLOCKED:spec]`)
- **Repeated failure with unknown cause**: the same problem recurs across runs and the root cause cannot be identified (→ `[BLOCKED:spec]`)

If none of the above apply, fix and re-run without stopping. **Autonomous mode behaviour**: the session terminates (Telegram notified if configured). **Resuming**: once you have resolved the question, **run from a human terminal** (Ring C — `CLAUDE_PLAN_CAPABILITY=human` required):
```bash
export CLAUDE_PLAN_CAPABILITY=human
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" unblock "$CLAUDE_PROJECT_DIR/plans/{slug}.md"
```
Then tell the interactive Claude the decision; it will restart the autonomous run.

## Resuming from a BLOCKED marker

All `[BLOCKED:{kind}]` markers are cleared by `unblock` in a single pass — no marker text input needed. `[BLOCKED:transient]` is intentionally excluded (auto lifecycle; not a human-must marker). After fixing the root cause, **run from a human terminal** (Ring C — `CLAUDE_PLAN_CAPABILITY=human` required; see `@reference/markers.md`):
```bash
export CLAUDE_PLAN_CAPABILITY=human
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" unblock "$CLAUDE_PROJECT_DIR/plans/{slug}.md"
```
Re-run the critic. **Exception: for `[BLOCKED:ceiling]`, never use `unblock` alone** — use `reset-milestone {agent}` instead (Ring B — `CLAUDE_PLAN_CAPABILITY=harness` required, not `=human`; `unblock` alone does not increment `milestone_seq` and immediately re-triggers the ceiling block):
```bash
export CLAUDE_PLAN_CAPABILITY=harness
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "$CLAUDE_PROJECT_DIR/plans/{slug}.md" {agent}
```
