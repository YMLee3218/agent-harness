# Critics

> Single source for: verdict format, critic blocking rules, convergence policy, branching priority, review execution rules, running critics, blocked-state procedures. Phase ops: `@reference/phase-ops.md`. Ultrathink audit: `@reference/ultrathink.md`. PR-review fix loop: `@reference/pr-review-loop.md`.

Severity rules: @reference/severity.md
Layer rules: @reference/layers.md
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

Rules: `@reference/markers.md §HTML verdict envelopes`. Full iteration protocol: §Loop convergence.

---

Convergence-based protocol used by every phase-gate critic (critic-spec, critic-test, critic-code) and the pr-review step.

## Brainstorm exception

`critic-feature` uses a max-2 iteration guard: on the second consecutive FAIL, the brainstorming skill appends `[BLOCKED] final: critic-feature failed twice — manual review required` to `## Open Questions` and stops. The SubagentStop hook records the verdict normally; convergence/ceiling/category markers are skipped for this agent.

## Consecutive same-category escalation

`plan-file.sh record-verdict` tracks the last FAIL category per critic (agent-scoped, phase-independent). If the same critic emits **two consecutive FAILs with the same category**, the script writes:

```
[BLOCKED] category:{critic}: {CATEGORY} failed twice — fix the root cause before retrying
```

to `## Open Questions` in the plan file, then exits 1. The skill reads the `[BLOCKED]` marker and stops. The loop cannot converge when the same structural problem recurs; human review is required.

## Review execution rule (subagent mandate)

All phase-gate critics (`critic-feature`, `critic-spec`, `critic-test`, `critic-code`) and pr-review **must** run in isolated subagents. Generating a verdict inline in the parent context (i.e., executing review logic without spawning a subagent) is forbidden.

Normative implementations:

- **`critic-*` (4 variants)**: `skills/critic-*/SKILL.md` frontmatter `context: fork` + `agent: critic-*` + `workspace/agents/critic-*.md` definition.
- **`pr-review-toolkit:review-pr`**: The external plugin internally orchestrates `pr-review-toolkit:code-reviewer`, `…:pr-test-analyzer`, `…:silent-failure-hunter`, `…:comment-analyzer`, and `…:type-design-analyzer` subagents, so the isolation requirement is satisfied by the plugin definition.

**Prohibited**: any implementation that generates a verdict directly in the parent context without subagent isolation.

## Loop convergence

The harness always operates in non-interactive mode — skills write `[BLOCKED]` markers to `## Open Questions` instead of prompting the user.

The loop terminates on **2 consecutive PASSes** (convergence), not on a single PASS. This filters lucky single-run PASSes caused by LLM non-determinism.

`plan-file.sh record-verdict` (and `append-review-verdict` for pr-review) automatically writes markers to `## Open Questions`. The skill reads these markers after each run and branches accordingly.

### Convergence markers in ## Open Questions

Definitions: `@reference/markers.md §Critic loop markers` and `@reference/markers.md §Phase-scoped convergence markers`. Policy: §Skill branching logic below.

#### pr-review asymmetry

pr-review omits category/parse tracking — failures are categorised by the skill (see `skills/implementing/SKILL.md §Step 5`). Apply §Skill branching logic steps 1 → 3 → 4–5 → 7 → 8 only.

**Integration pipeline markers**: `@reference/markers.md §Integration test markers`. They do not interact with the critic convergence protocol above.

Ceiling N defaults to **5** (runs 1–5 are allowed; the 6th run triggers `[BLOCKED-CEILING]`). Override with env var `CLAUDE_CRITIC_LOOP_CEILING`.

### Skill branching logic (after each run)

```
After critic/review run → script records verdict + emits markers
Skill reads ## Open Questions, checks in priority order:

  1. [BLOCKED-CEILING] {phase}/{agent}  → stop (manual review)
  2. [BLOCKED] {any text}               → stop (read reason; fix root cause; clear marker; retry)
  3. [BLOCKED-AMBIGUOUS] {agent}        → stop (human decision required)
  4. [CONVERGED] {phase}/{agent}        → proceed to next step
  5. [FIRST-TURN] {phase}/{agent}       → re-run automatically
                                          **Only when latest verdict is PASS or PARSE_ERROR.**
                                          If latest verdict is FAIL, skip to step 7.
  6. (no terminal marker, PARSE_ERROR in last ## Critic Verdicts entry)
                                → re-run automatically (one retry allowed;
                                  second consecutive PARSE_ERROR triggers [BLOCKED] parse:)
  7. (no terminal marker, PASS) → re-run automatically
  8. (no terminal marker, FAIL) → LLM determines fix direction:
       - direction is clear → apply fix + re-run
       - direction is ambiguous → append [BLOCKED-AMBIGUOUS] {agent}: {question} + stop
       - [DOCS CONTRADICTION] in critic output → append [BLOCKED-AMBIGUOUS] {agent}: DOCS
         CONTRADICTION — cannot determine whether docs or code is ground truth + stop.
         Then follow `@reference/phase-ops.md §DOCS CONTRADICTION cascade`.
```

---

## Running the critic

Invoke the critic skill with the relevant paths. The `SubagentStop` hook fires `plan-file.sh record-verdict` automatically when the critic agent exits — do **not** call `record-verdict` manually (doing so would double-record the run, inflating the streak and ceiling counters). For pr-review (which is not a subagent), call `append-review-verdict` directly after the pr-review skill returns.

After `record-verdict` (or `append-review-verdict`) completes, run `@reference/ultrathink.md §Ultrathink verdict audit`, then read `## Open Questions` for the markers listed in §Skill branching logic and branch accordingly.

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

## §Invocation recipe

Standard critic convergence loop. Skills cite as:
`Run @reference/critics.md §Invocation recipe with agent=\`{A}\`, phase=\`{P}\`, prompt="…".`

1. `Skill("{agent}", "{prompt}")`
2. Follow §Running the critic (SubagentStop records verdict; run ultrathink audit).
3. Branch per §Skill branching logic (substitute `{agent}`).
4. On `[CONVERGED] {phase}/{agent}`: proceed to next step.
5. On `[DOCS CONTRADICTION]`: `@reference/phase-ops.md §DOCS CONTRADICTION cascade`.

pr-review diverges from steps 2–5 — use §pr-review asymmetry instead.

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
| `[BLOCKED-AMBIGUOUS]` | Resolve the question stated in the marker (update docs, code, or spec). If the fix changes spec or tests, roll back phase first (`@reference/phase-ops.md §Phase Rollback Procedure`) before re-running. |
| `[BLOCKED] parse:` | Investigate missing `<!-- verdict: -->` marker (common causes: agent ran out of turns, truncated output, model change). Fix root cause. |
| `[BLOCKED] category:` | Inspect consecutive same-category FAILs in `## Critic Verdicts`; address the structural cause (refactor, spec change, layer fix — not a surface tweak). |

### Clear the marker and re-run

After fixing the root cause, clear the marker using the exact text that appears in `## Open Questions`:

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" clear-marker "plans/{slug}.md" "[BLOCKED] {type}:{agent}"
```

Re-run the critic. If streak reset needed (parse or category block): `reset-milestone "plans/{slug}.md" {agent}` (separate call — `reset-milestone` does NOT clear any `[BLOCKED]` marker).
