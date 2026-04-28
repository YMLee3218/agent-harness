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

A **FAIL** verdict must include a `<!-- category: X -->` marker. A FAIL that has a verdict marker but no category marker is recorded as PARSE_ERROR; on the second consecutive occurrence `[BLOCKED] parse:{agent}` is set.

Full iteration protocol: §Loop convergence.

## Consecutive same-category escalation

`plan-file.sh record-verdict` tracks the last FAIL category per critic (agent-scoped, phase-independent). If the same critic emits **two consecutive FAILs with the same category** (PARSE_ERROR verdicts between them are transparent — they do not reset the streak; `reset-milestone` writes a `[MILESTONE-BOUNDARY @ts]` sentinel that **does** reset the streak — streaks are therefore isolated per milestone), the script writes:

```
[BLOCKED] category:{agent}: {CATEGORY} failed twice — fix the root cause before retrying
```

to `## Open Questions` in the plan file, then exits 1. The skill reads the `[BLOCKED]` marker and stops. The loop cannot converge when the same structural problem recurs; human review is required.

## Review execution rule (subagent mandate)

All phase-gate critics (`critic-feature`, `critic-spec`, `critic-test`, `critic-code`) and pr-review **must** run in isolated subagents. Generating a verdict inline in the parent context (i.e., executing review logic without spawning a subagent) is forbidden.

Normative implementations:

- **`critic-*` (4 variants)**: `skills/critic-*/SKILL.md` frontmatter `context: fork` + `agent: critic-*` + `agents/critic-*.md` definition.
- **`pr-review-toolkit:review-pr`**: The external plugin internally orchestrates `pr-review-toolkit:code-reviewer`, `…:pr-test-analyzer`, `…:silent-failure-hunter`, `…:comment-analyzer`, and `…:type-design-analyzer` subagents, so the isolation requirement is satisfied by the plugin definition.

**Prohibited**: any implementation that generates a verdict directly in the parent context without subagent isolation.

## Loop convergence

Convergence-based protocol used by every phase-gate critic (critic-feature, critic-spec, critic-test, critic-code) and the pr-review step.

The harness always operates in non-interactive mode — skills write `[BLOCKED]` markers to `## Open Questions` instead of prompting the user.

The loop terminates on **2 consecutive PASSes** (convergence), not on a single PASS. This filters lucky single-run PASSes caused by LLM non-determinism. Unlike the FAIL category streak (§Consecutive same-category escalation, where PARSE_ERROR is transparent), a PARSE_ERROR between two PASSes interrupts the convergence streak: `PASS → PARSE_ERROR → PASS` counts as streak=1, not 2 — two uninterrupted consecutive PASSes are required for CONVERGED.

`plan-file.sh record-verdict` (and `append-review-verdict` for pr-review) automatically writes markers to `## Open Questions`. The skill reads these markers after each run and branches accordingly.

### Convergence markers in ## Open Questions

Definitions: `@reference/markers.md §Critic loop markers` and `@reference/markers.md §Phase-scoped convergence markers`. Policy: §Skill branching logic below.

#### pr-review asymmetry

pr-review omits category/parse tracking — failures are categorised by the skill (see `@reference/pr-review-loop.md`). Apply §Skill branching logic steps 1 → 4–5 → 7 → 8 only. Steps 2, 3, and 6 are omitted: step 2 (`[BLOCKED-AMBIGUOUS]` stop) because pre-existing markers are caught by the orchestrating skill's Step 0 check before pr-review is reached, and any marker written during the fix chain causes an immediate `stop` that exits the B-session before step 4 is re-entered — same out-of-band handling as step 3; step 3 (`[BLOCKED]` check) because any `[BLOCKED]` markers would have halted the orchestrating skill's Step 0 check before pr-review is reached; step 6 (PARSE_ERROR retry) because pr-review uses `append-review-verdict` directly and does not produce PARSE_ERROR verdicts.

**Integration pipeline markers**: `@reference/markers.md §Integration test markers`. They do not interact with the critic convergence protocol above.

Ceiling N defaults to **5** (runs 1–5 are allowed; the 6th run triggers `[BLOCKED-CEILING]`; PARSE_ERROR verdicts count toward this ceiling — the transparency at §Consecutive same-category escalation applies only to streak resetting, not to ceiling counting; `REJECT-PASS` entries written by `clear-converged` do **not** count). Override with env var `CLAUDE_CRITIC_LOOP_CEILING`.

### Skill branching logic (after each run)

```
After critic/review run → script records verdict + emits markers
Skill reads ## Open Questions, checks in priority order:

  1. [BLOCKED-CEILING] {phase}/{agent}  → stop (manual review)
  2. [BLOCKED-AMBIGUOUS] {agent}        → stop (human decision required)
  3. [BLOCKED] {any text}               → stop (read reason; fix root cause; clear marker; retry)
  4. [CONVERGED] {phase}/{agent}        → proceed to next step
  5. [FIRST-TURN] {phase}/{agent}       → re-run automatically
                                          **Only when latest verdict is PASS.**
                                          If latest verdict is FAIL, skip to step 8.
  6. (no terminal marker, PARSE_ERROR in last ## Critic Verdicts entry)
                                → re-run automatically (one retry allowed;
                                  second consecutive PARSE_ERROR triggers [BLOCKED] parse:)
  7. (no terminal marker, PASS) → re-run automatically
  8. (no terminal marker, FAIL) → LLM determines fix direction:
       - direction is clear → construct Codex fix prompt (critic finding, target file,
         change to apply, test command, layer rules if applicable); write to tmp file:
           codex exec --full-auto - < "$_fix_prompt" > "$_fix_log" 2>&1; tail -200 "$_fix_log"; rm -f "$_fix_prompt" "$_fix_log"
         → re-run critic
       - direction is ambiguous → append [BLOCKED-AMBIGUOUS] {agent}: {question} + stop
       - [DOCS CONTRADICTION] in critic output → append [BLOCKED-AMBIGUOUS] {agent}: DOCS
         CONTRADICTION — cannot determine whether docs or code is ground truth + stop.
         (The calling context must then follow `@reference/phase-ops.md §DOCS CONTRADICTION cascade` — see [BLOCKED-AMBIGUOUS] recovery below.)
```

---

## Running the critic

Invoke the critic skill with the relevant paths. The `SubagentStop` hook fires `plan-file.sh record-verdict` automatically when the critic agent exits — do **not** call `record-verdict` manually (doing so would double-record the run, inflating the streak and ceiling counters). For pr-review (which is not a subagent), call `append-review-verdict` directly after the pr-review skill returns.

### Background execution

`run-critic-loop.sh` may exceed the Bash tool's 10-minute maximum timeout. Always run it with `run_in_background=true` (Bash tool parameter). Do **not** append `&` to the command string — `run_in_background=true` handles backgrounding; adding `&` orphans the script. Do **not** set up a Monitor — Monitor surfaces B/C session output, which causes the parent agent to intervene with fixes that belong to the spawned B session.

After launching in background, wait for the completion notification, then read `## Open Questions` in the plan file for terminal markers and proceed per exit code rules. Do **not** apply fixes based on any output observed before the notification — B sessions handle all fixes.

After `record-verdict` (or `append-review-verdict`) completes, run `@reference/ultrathink.md §Ultrathink verdict audit`, then read `## Open Questions` for the markers listed in §Skill branching logic and branch accordingly. **Exception — `run-critic-loop.sh` background runs**: the one-shot B-session runs the audit internally per §Critic one-shot iteration step 2; do **not** re-run the audit after the loop returns. This step applies to `append-review-verdict` (pr-review) and direct critic invocations only.

### New milestone

Before starting a critic run for a new milestone within the same phase, call:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "plans/{slug}.md" {agent}
```
This clears the 3 phase-scoped convergence markers (see `@reference/markers.md §Phase-scoped convergence markers`) for this phase+agent from `## Open Questions`, and appends a `[MILESTONE-BOUNDARY]` sentinel to `## Critic Verdicts` so prior-milestone history does not contribute to the new streak. `transition` must run before `reset-milestone` when also changing phase (`transition` calls `set-phase` internally and writes a Phase Transitions log entry; using `plan-file.sh set-phase` directly would skip the log entry), so `reset-milestone` reads the correct phase when clearing phase-scoped markers. For the full list of markers written and cleared by `reset-milestone`, `reset-pr-review`, and `reset-for-rollback`, see `reference/markers.md §Operation → markers reverse lookup`.

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

When the cleanup phase differs from the destination phase (e.g., clearing `implement` markers while rolling back to `red`): use a 3-call sequence — `transition {cleanup-phase}`, `reset-for-rollback {cleanup-phase}`, then `transition {destination-phase}`. This is necessary because `reset-for-rollback` calls `set-phase` internally, which would overwrite a prior `transition {destination-phase}`. After `transition {destination-phase}`, additionally call `reset-milestone {destination-critic}` if a stale `[CONVERGED] {destination-phase}/{destination-critic}` marker remains from a prior milestone (e.g., rolling back to `red` requires `reset-milestone critic-test` to clear any stale `[CONVERGED] red/critic-test`).

## §Critic one-shot iteration

One iteration for a `claude` CLI session from `run-critic-loop.sh`. Do **not** loop — one critic run per session.
1. `Skill("{agent}", "{prompt}")` — `SubagentStop` fires `record-verdict` automatically.
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

If none of the above apply, fix and re-run without stopping.

## Resuming from a BLOCKED marker

`[BLOCKED-AMBIGUOUS]`, `[BLOCKED] category:`, and `[BLOCKED] parse:` are agent-scoped and do not clear on phase transition or `reset-milestone`. Rationale and lifecycle: `@reference/markers.md §Implementation notes`.

### Root cause per marker

| Marker prefix | What to fix |
|---------------|-------------|
| `[BLOCKED-AMBIGUOUS]` | Resolve the question stated in the marker (update docs, code, or spec). **If the marker text says `DOCS CONTRADICTION`**: follow `@reference/phase-ops.md §DOCS CONTRADICTION cascade` to resolve the contradiction and re-run the full critic chain — do not simply re-run the one blocked critic. Otherwise: if the fix changes spec or tests, roll back phase first (`@reference/phase-ops.md §Phase Rollback Procedure`) before re-running. |
| `[BLOCKED] parse:` (verdict marker missing) | Investigate missing `<!-- verdict: -->` marker (common causes: agent ran out of turns, truncated output, model change). Fix root cause. |
| `[BLOCKED] parse:` (FAIL without category) | Investigate missing `<!-- category: -->` marker — agent emitted a FAIL verdict without a category. Fix agent output format. |
| `[BLOCKED] category:` | Inspect consecutive same-category FAILs in `## Critic Verdicts`; address the structural cause (refactor, spec change, layer fix — not a surface tweak). |

### Clear the marker and re-run

After fixing the root cause, clear the marker using the exact text that appears in `## Open Questions`:

```bash
# For [BLOCKED] parse: and [BLOCKED] category: markers:
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" clear-marker "plans/{slug}.md" "[BLOCKED] {type}:{agent}"

# For [BLOCKED-AMBIGUOUS] markers (clear-marker uses substring match):
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" clear-marker "plans/{slug}.md" "[BLOCKED-AMBIGUOUS] {agent}"
```

Re-run the critic. If streak reset needed (parse or category block): `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" reset-milestone "plans/{slug}.md" {agent}` (separate call — `reset-milestone` does NOT clear any `[BLOCKED]` marker).
