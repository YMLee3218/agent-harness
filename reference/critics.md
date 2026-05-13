# Critics

> Single source for: verdict format, critic blocking rules, convergence policy, branching priority, review execution rules, running critics, blocked-state procedures. Phase ops: `@reference/phase-ops.md`. Ultrathink audit: `@reference/ultrathink.md`. PR-review fix loop: `@reference/pr-review-loop.md`.

Severity rules: @reference/severity.md
Layer rules: @reference/layers.md
Language and verdict-marker language: @reference/language.md

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

A **FAIL** verdict must include a `<!-- category: X -->` marker. A FAIL that has a verdict marker but no category marker is recorded as PARSE_ERROR; on the second consecutive occurrence `[BLOCKED] parse:{agent}` is set. Verdict calibration: false PASS → production defect (cost 10×); false FAIL → one extra iteration (cost 1×). When evidence is ambiguous, FAIL.

Full iteration protocol: §Loop convergence.

## Consecutive same-category escalation

`plan-file.sh record-verdict` tracks the last FAIL category per critic (agent-scoped, milestone-scoped — the streak resets on `reset-milestone` and is computed within the current phase+milestone boundary). If the same critic emits **two consecutive FAILs with the same category** (PARSE_ERROR verdicts between them are transparent — they do not reset the streak; `reset-milestone` writes a `[MILESTONE-BOUNDARY @ts]` sentinel that **does** reset the streak — streaks are therefore isolated per milestone), the script writes:

```
[BLOCKED] category:{agent}: {CATEGORY} failed twice — fix the root cause before retrying
```

to `## Open Questions` in the plan file, then exits 1. The skill reads the `[BLOCKED]` marker and stops. The loop cannot converge when the same structural problem recurs; human review is required.

## Review execution rule (subagent mandate)

All phase-gate critics (`critic-feature`, `critic-spec`, `critic-test`, `critic-code`, `critic-cross`) and pr-review **must** run in isolated subagents. Generating a verdict inline in the parent context (i.e., executing review logic without spawning a subagent) is forbidden.

Normative implementations:

- **`critic-*` (5 variants)**: `skills/critic-*/SKILL.md` frontmatter `context: fork` + `agent: critic-*` + `agents/critic-*.md` definition.
- **`pr-review-toolkit:review-pr`**: The external plugin internally orchestrates `pr-review-toolkit:code-reviewer`, `…:pr-test-analyzer`, `…:silent-failure-hunter`, `…:comment-analyzer`, and `…:type-design-analyzer` subagents, so the isolation requirement is satisfied by the plugin definition.

**Prohibited**: any implementation that generates a verdict directly in the parent context without subagent isolation.

## Loop convergence

Convergence-based protocol used by every phase-gate critic (critic-feature, critic-spec, critic-test, critic-code, critic-cross) and the pr-review step. Convergence state is stored exclusively in `plans/{slug}.state/convergence/{phase}__{agent}.json` — updated on every verdict by `_record_loop_state`; `converged=true` requires 2 consecutive PASSes (see `@reference/markers.md §Sidecar control state`). A PARSE_ERROR between two PASSes resets the streak: `PASS → PARSE_ERROR → PASS` = streak 1. Query via `plan-file.sh is-converged <plan> <phase> <agent>` (exit 0 = converged). No plan.md marker mirrors this state.

`plan-file.sh record-verdict` automatically writes markers to `## Open Questions`; the skill reads them after each run and branches per §Skill branching logic. For pr-review, `run-critic-loop.sh` extracts `<!-- review-verdict: {nonce} PASS|FAIL -->` from stdout and calls `append-review-verdict` on the parent side.

**pr-review exception**: omits category/parse — apply steps 1 → 4–5 → 7 → 8 only (see `@reference/pr-review-loop.md`); use `plan-file.sh is-converged` for step 4. Integration pipeline markers (`@reference/markers.md §Integration test markers`) do not interact with this protocol.

Ceiling N defaults to **5** (runs 1–5 are allowed; the 6th run triggers `[BLOCKED-CEILING]`; PARSE_ERROR verdicts count toward this ceiling — the transparency at §Consecutive same-category escalation applies only to streak resetting, not to ceiling counting; `REJECT-PASS` entries written by `clear-converged` do **not** count). Override with env var `CLAUDE_CRITIC_LOOP_CEILING`.

### Skill branching logic (after each run)

```
After critic/review run → script records verdict + emits markers
Skill reads ## Open Questions and queries sidecar, checks in priority order:

  1. [BLOCKED-CEILING] {phase}/{agent}  → stop (manual review)
  2. [BLOCKED-AMBIGUOUS] {agent}        → stop (human decision required)
  3. [BLOCKED] {any text}               → stop (read reason; fix root cause; clear marker; retry)
  4. is-converged exits 0               → proceed to next step
  5. [FIRST-TURN] {phase}/{agent}       → re-run automatically
                                          **Only when latest verdict is PASS.**
                                          If latest verdict is FAIL, skip to step 8.
  6. (no terminal marker, PARSE_ERROR in last ## Critic Verdicts entry)
                                → re-run automatically (one retry allowed;
                                  second consecutive PARSE_ERROR triggers [BLOCKED] parse:)
  7. (no terminal marker, PASS) → re-run automatically
  8. (no terminal marker, FAIL; or redirected from step 5 on [FIRST-TURN]+FAIL) → LLM determines fix direction:
       - direction is clear → construct Codex fix prompt (critic finding, target file,
         change to apply, test command, layer rules if applicable); write to tmp file:
           codex exec --full-auto - < "$_fix_prompt" > "$_fix_log" 2>&1; tail -200 "$_fix_log"; rm -f "$_fix_prompt" "$_fix_log"
         → re-run critic
       - direction is ambiguous → append [BLOCKED-AMBIGUOUS] {agent}: {question} + stop
       - [DOCS CONTRADICTION] in critic output → treat docs/*.md as ground truth; fix code (and spec) to match. If fixing code would itself require changing docs (stale requirements), direction is ambiguous → append [BLOCKED-AMBIGUOUS] {agent}: DOCS CONTRADICTION — docs may be stale + stop; follow `@reference/phase-ops.md §DOCS CONTRADICTION cascade`.
```

---

## Running the critic

Invoke the critic skill with the relevant paths. The `SubagentStop` hook fires `plan-file.sh record-verdict-guarded` automatically when the critic agent exits — do **not** call `record-verdict` or `record-verdict-guarded` manually (doing so would double-record the run, inflating the streak and ceiling counters). For pr-review, `run-critic-loop.sh` records the verdict automatically by extracting the nonce-anchored `<!-- review-verdict: {nonce} PASS|FAIL -->` marker from the spawned session's stdout — do **not** call `append-review-verdict` manually either.

After launching, end your turn immediately. The background completion notification resumes execution in the next turn automatically — no Monitor, ScheduleWakeup, or polling of any kind. When the notification arrives, read `## Open Questions` for terminal markers and proceed per exit code rules. B sessions handle all fixes; do not act on output observed before the notification.

After `record-verdict` (or `append-review-verdict`) completes, run `@reference/ultrathink.md §Ultrathink verdict audit`, then read `## Open Questions` for the markers listed in §Skill branching logic and branch accordingly. The B-session for each `run-critic-loop.sh` iteration runs the audit internally — `§Critic one-shot iteration` step 2 for the five critic subagents, `pr-review-loop.md §PR-review one-shot iteration` step 3 for pr-review — so the orchestrator that called `run-critic-loop.sh` must **not** re-run the audit after the loop returns. (Direct critic invocations are not a remaining code path: the `record-verdict-guarded` SubagentStop hook at settings.json rejects any critic-subagent run outside `run-critic-loop.sh`.)

**Exit codes**: 0 = converged; 1 = blocked (non-ceiling BLOCKED marker in plan, or session timeout/NOOP); 2 = BLOCKED-CEILING; 3 = lock contention (another run already active for this plan — wait for it to finish or remove the plan's `.critic.lock` file (e.g. `plans/{slug}.md.critic.lock`)); 4 = ESCALATION (ENVELOPE_MISMATCH or ENVELOPE_OVERREACH — operating envelope must be corrected before re-running; `## Open Questions` contains the `[ESCALATION]` marker written by `run-critic-loop.sh`); any other code is a script failure: write `[BLOCKED] {agent}: script-failure: {code}` to `## Open Questions` and stop. Running critics manually is not a fallback — it is a protocol violation.
### New milestone

Before starting a critic run for a new milestone within the same phase, call:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "plans/{slug}.md" {agent}
```
This clears the 2 phase-scoped convergence markers (see `@reference/markers.md §Phase-scoped convergence markers`) for this phase+agent from `## Open Questions`, and appends a `[MILESTONE-BOUNDARY]` sentinel to `## Critic Verdicts` so prior-milestone history does not contribute to the new streak. `transition` must run before `reset-milestone` when also changing phase (`transition` calls `set-phase` internally and writes a Phase Transitions log entry; using `plan-file.sh set-phase` directly would skip the log entry), so `reset-milestone` reads the correct phase when clearing phase-scoped markers. For the full list of markers written and cleared by `reset-milestone`, `reset-pr-review`, and `reset-for-rollback`, see `reference/markers.md §Bracketed plan-file markers`.

Re-brainstorming the same requirements doc: transition to `brainstorm` first (required before `reset-milestone` so the correct phase-scoped markers are cleared — see line above), then reset the prior critic-feature streak:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" brainstorm \
  "re-brainstorming"
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "plans/{slug}.md" critic-feature
```
Then re-invoke the `brainstorming` skill.

### Full rollback reset

For integration failure or unit-test failure before integration: call `transition` first to log the rollback reason in Phase Transitions, then `reset-for-rollback` to atomically set phase, run `reset-milestone critic-code`, run `reset-pr-review`, and clear stale `review/critic-code` markers:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" transition "plans/{slug}.md" {target-phase} \
  "{one sentence reason}"
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-for-rollback "plans/{slug}.md" {target-phase}
```

When the cleanup phase differs from the destination phase (e.g., clearing `implement` markers while rolling back to `red`): use a 3-call sequence — `transition {cleanup-phase}`, `reset-for-rollback {cleanup-phase}`, then `transition {destination-phase}`. This is necessary because `reset-for-rollback` calls `set-phase` internally, which would overwrite a prior `transition {destination-phase}`. After `transition {destination-phase}`, additionally call `reset-milestone {destination-critic}` if a prior milestone's sidecar streak needs resetting (e.g., rolling back to `red` may require `reset-milestone critic-test` to isolate the new streak). When a milestone must be reset at a non-destination phase (e.g., resetting `red/critic-test` while destination is `spec`): use a phase round-trip — `transition {milestone-phase}`, `reset-milestone {milestone-critic}`, `transition {destination-phase}` — because `reset-milestone` scopes to the current plan phase (implemented by `run-integration.sh`'s spec-gap recovery path).

## §Critic one-shot iteration

One iteration for a `claude` CLI session from `run-critic-loop.sh`. Do **not** loop — one critic run per session.
1. `Skill("{agent}", "{prompt}")` — `SubagentStop` fires `record-verdict-guarded` automatically.
2. `@reference/ultrathink.md §Ultrathink verdict audit`. Then read `## Open Questions` per §Skill branching logic — **exception**: this session never re-runs (steps 5/6/7 hand their re-run back to the shell loop; however step 5's FAIL branch routes to step 8, which this session does execute before exiting); exit after each branching action.

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

If none of the above apply, fix and re-run without stopping. **Autonomous mode behaviour**: the session terminates (Telegram notified if configured). **Resuming**: once you have resolved the question, **run from a human terminal**: `bash .claude/scripts/plan-file.sh clear-marker plans/{slug}.md "[BLOCKED-AMBIGUOUS] {agent}"`. Then tell the interactive Claude the decision; it will restart the autonomous run.

## Resuming from a BLOCKED marker

Markers `[BLOCKED-AMBIGUOUS]`, `[BLOCKED] category:`, and `[BLOCKED] parse:` are agent-scoped; they do not clear on phase transition or `reset-milestone` — see `@reference/markers.md` for lifecycle. After fixing the root cause, clear the marker and re-run: **both commands must be run from a human terminal** (Ring C — see `@reference/markers.md`):
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" clear-marker "plans/{slug}.md" "[BLOCKED] {type}:{agent}"
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" clear-marker "plans/{slug}.md" "[BLOCKED-AMBIGUOUS] {agent}"
```
Re-run the critic. If streak reset needed (parse or category block): `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "plans/{slug}.md" {agent}` (separate call — `reset-milestone` does NOT clear any `[BLOCKED]` marker).
