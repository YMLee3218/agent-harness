# Critic Loop

Convergence-based protocol used by every phase-gate critic (critic-spec, critic-test, critic-code) and the pr-review step.

> **Brainstorm exception** — `critic-feature` is intentionally excluded from this
> protocol. Brainstorming output is human-reviewed before any code is written, so
> LLM convergence guarantees are unnecessary; two iterations are sufficient to catch
> obvious classification errors without risking an infinite loop on subjective
> decomposition choices. See `@skills/brainstorming/SKILL.md §Step 4`.
> `critic-feature` uses `[BLOCKED-FINAL]` (not `[BLOCKED-CEILING]`) for its double-fail stop signal.

## Finding labels and categories

Severity levels, PASS/FAIL threshold, and category priority are defined in `@reference/severity.md` (single source of truth). Critic bodies import that file directly; do not duplicate those tables here.

## Mandatory verdict marker

Every critic agent **must** emit a `### Verdict` heading followed immediately by the HTML markers as the last lines of output. Both are machine-parsed by `plan-file.sh record-verdict`. Output that does not end with these markers will be recorded as `PARSE_ERROR` in the plan file.

PASS:
```
### Verdict
PASS
<!-- verdict: PASS -->
<!-- category: NONE -->
```

FAIL:
```
### Verdict
FAIL — {comma-separated list of blocking finding labels}
<!-- verdict: FAIL -->
<!-- category: {highest-priority category} -->
```

## FAIL categories

On FAIL, the critic **must** also emit a `<!-- category: X -->` marker on the line immediately following the verdict.

Full category list, priority order, and severity thresholds: `@reference/severity.md §FAIL categories` (single source of truth — do not duplicate here).

If a single FAIL has multiple root causes from different categories, choose the **highest-severity** one (see `@reference/severity.md §Category priority`).

## Consecutive same-category escalation

`plan-file.sh record-verdict` tracks the last FAIL category per critic (agent-scoped, phase-independent). If the same critic emits **two consecutive FAILs with the same category**, the script writes:

```
[BLOCKED-CATEGORY] {critic}: category {CATEGORY} failed twice — fix the root cause before retrying
```

to `## Open Questions` in the plan file, then exits 1. The skill reads the `[BLOCKED-CATEGORY]` marker and stops. The loop cannot converge when the same structural problem recurs; human review is required.

> **Phase independence**: the category counter is not reset by `red → review` phase transitions. This prevents the same structural failure from escaping detection by crossing a phase boundary.

## Loop convergence

The loop terminates on **2 consecutive PASSes** (convergence), not on a single PASS. This filters lucky single-run PASSes caused by LLM non-determinism.

`plan-file.sh record-verdict` (and `append-review-verdict` for pr-review) automatically writes markers to `## Open Questions`. The skill reads these markers after each run and branches accordingly.

### Convergence markers in ## Open Questions

| Marker | Condition | Skill action |
|--------|-----------|--------------|
| `[BLOCKED-CEILING] {agent}` | Total runs for this phase+agent > N (default 5) | Stop — manual review required |
| `[BLOCKED-CATEGORY] {agent}` | Two consecutive FAILs with same category (agent-scoped, phase-independent) | Stop — fix root cause first |
| `[BLOCKED-AMBIGUOUS] {agent}: {question}` | LLM cannot determine fix direction | Stop — human decision required |
| `[BLOCKED-PARSE] {agent}` | Critic output missing verdict markers two consecutive times | Stop — investigate agent output format before retrying |
| `[CONVERGED] {agent}` | PASS streak ≥ 2 for this phase+agent (emitted once; duplicate-safe) | Proceed to next step |
| `[CONFIRMED-FIRST] {agent}` | Interactive: user confirmed FIRST-TURN; skill writes this marker (via append-note) after user confirms and before re-running, so a resumed session can skip re-confirmation | Re-run automatically (skip re-confirmation) |
| `[AUTO-APPROVED-FIRST] {agent}` | Non-interactive mode: `[FIRST-TURN]` auto-approved | Re-run automatically (FIRST-TURN auto-approved in prior non-interactive session) |
| `[FIRST-TURN] {agent}` | First run ever for this phase+agent | Ask user for confirmation, then re-run (or auto-approve in non-interactive mode) |
| `[AUTO-APPROVED-PLAN] {skill}: {note}` | Non-interactive mode: `ExitPlanMode` skipped, plan auto-approved | Log only — proceed to write step |
| `[AUTO-APPROVED-TASKLIST] implementing: {note}` | Non-interactive mode: implementation task list auto-approved in `implementing` skill | Log only — proceed to task execution |
| `[AUTO-CATEGORIZED] {agent}: {summary} → {category}` | Non-interactive mode: pr-review FAIL category inferred and fix applied automatically | Log only — re-run automatically |

> **pr-review asymmetry**: the pr-review fix loop (in `skills/implementing/SKILL.md`) intentionally omits `[BLOCKED-CATEGORY]` and `[BLOCKED-PARSE]` from its marker table. pr-review failures are categorised by the skill itself (`[AUTO-CATEGORIZED]`), not by the category-tracking mechanism used for critics. `[BLOCKED-PARSE]` is not produced by `append-review-verdict`. This asymmetry is by design.

> **Integration pipeline markers**: the `running-integration-tests` skill uses its own marker set, written to `## Integration Failures` (not `## Open Questions`). These markers do not interact with the critic convergence protocol above.
>
> | Marker | Written to | Meaning |
> |--------|-----------|---------|
> | `[AUTO-CATEGORIZED-INTEGRATION] {test name}: {category}` | `## Integration Failures` | Non-interactive: failure category inferred and fix skill invoked automatically |
> | `[BLOCKED-INTEGRATION] {test name}: {reason}` | `## Integration Failures` | Non-interactive: category ambiguous — manual review required |

Ceiling N defaults to **5** (runs 1–5 are allowed; the 6th run triggers `[BLOCKED-CEILING]`). Override with env var `CLAUDE_CRITIC_LOOP_CEILING`.

### Skill branching logic (after each run)

```
After critic/review run → script records verdict + emits markers
Skill reads ## Open Questions, checks in priority order:

  1. [BLOCKED-CEILING] {agent}  → stop (manual review)
  2. [BLOCKED-CATEGORY] {agent} → stop (fix root cause)
  3. [BLOCKED-AMBIGUOUS] {agent} → stop (human decision)
  4. [BLOCKED-PARSE] {agent}    → stop (investigate critic output format)
  5. [CONVERGED] {agent}           → proceed to next step
  6. [CONFIRMED-FIRST] {agent}     → re-run automatically (user confirmed in prior session)
  7. [AUTO-APPROVED-FIRST] {agent} → re-run automatically
                                     (non-interactive: FIRST-TURN auto-approved in prior session)
  8. [FIRST-TURN] {agent}          → confirm with user, then re-run
                                     (non-interactive: auto-approve + re-run)
  9. (no terminal marker, PARSE_ERROR in last ## Critic Verdicts entry)
                                   → re-run automatically (one retry allowed;
                                     second consecutive PARSE_ERROR triggers [BLOCKED-PARSE])
  10. (no terminal marker, PASS) → re-run automatically
  11. (no terminal marker, FAIL) → LLM determines fix direction:
       - direction is clear → apply fix + re-run
       - direction is ambiguous → append [BLOCKED-AMBIGUOUS] + stop
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

## Running the critic

Invoke the critic skill with the relevant paths. After it returns, call the record-verdict command (for pr-review: call `append-review-verdict` directly). Then read `## Open Questions` for the markers listed above and branch accordingly.

The `SubagentStart` hook automatically calls `plan-file.sh record-critic-start` when a critic agent launches, recording the start timestamp in `## Critic Runs` for auditing purposes.

## On PASS

After `record-verdict` (or `append-review-verdict`) returns:

1. Read `## Open Questions` for this agent's markers (priority order above).
2. If any `[BLOCKED-*]` marker is present for this agent — stop immediately
   (BLOCKED states take precedence over convergence even on a PASS run; do not continue to steps 3–7).
3. If `[CONVERGED]` is present → proceed to the next step.
4. If `[CONFIRMED-FIRST]` is present (and no `[CONVERGED]`) → re-run automatically (user confirmed in a previous session).
5. If `[AUTO-APPROVED-FIRST]` is present (and no `[CONVERGED]`, no `[CONFIRMED-FIRST]`) → re-run automatically (non-interactive FIRST-TURN was already approved in a prior session).
6. If `[FIRST-TURN]` is present (and no `[CONVERGED]`, no `[CONFIRMED-FIRST]`, no `[AUTO-APPROVED-FIRST]`) → ask user (interactive), then re-run. (Non-interactive: see §Non-interactive mode.)
   **Interactive only:** after the user confirms, run:
   `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" append-note "plans/{slug}.md" "[CONFIRMED-FIRST] {agent}"`
   before re-running, so a resumed session can skip re-confirmation.
7. Otherwise (PASS but no convergence yet) → re-run automatically.

## On FAIL

1. Output the full critic verdict.
2. If `[DOCS CONTRADICTION]` is reported:
   - **Interactive mode** (default): use `AskUserQuestion` — "Should docs be updated to match the current work, or the current work fixed to match docs?" Apply the chosen fix before continuing.
   - **Non-interactive mode** (`CLAUDE_CRITIC_NONINTERACTIVE=1` OR `CLAUDE_NONINTERACTIVE=1`): append `[BLOCKED-AMBIGUOUS] {agent}: DOCS CONTRADICTION — cannot determine whether docs or code is ground truth; human decision required` to `## Open Questions` and stop. Do not resolve unilaterally.
3. Determine fix direction:
   - If unambiguous → write a fix plan, confirm with `AskUserQuestion` (interactive) or auto-apply (non-interactive), apply fixes, re-run.
   - If ambiguous → append `[BLOCKED-AMBIGUOUS] {agent}: {question}` to `## Open Questions` and stop.
4. After fixing, re-run the critic. `record-verdict` will track the new run's streak and ceiling.

## Non-interactive mode

Two flags control non-interactive behaviour; they compose additively:

| Flag | Scope |
|------|-------|
| `CLAUDE_CRITIC_NONINTERACTIVE=1` | Critic loop only (legacy; kept for backwards compatibility) |
| `CLAUDE_NONINTERACTIVE=1` | All skills — implies `CLAUDE_CRITIC_NONINTERACTIVE=1` |

When either flag is set:

- Replace all `AskUserQuestion` calls in the critic loop with plan file writes.
- `[FIRST-TURN]` handling: instead of asking, the skill should run `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" record-auto-approved "plans/{slug}.md" FIRST {agent}` and re-run automatically.
- `ExitPlanMode` (in writing-spec, writing-tests, implementing, initializing-project, brainstorming): skip the gate — the skill should run `bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" record-auto-approved "plans/{slug}.md" PLAN {skill} "{note}"` and proceed to the write step.
- On first FAIL (critic loop): apply the fix plan automatically and re-run without stopping (auto-apply replaces the `AskUserQuestion` confirmation). For pr-review FAILs: infer the issue category and log `[AUTO-CATEGORIZED] pr-review: {summary} → {category}` to `## Open Questions` before applying the fix chain.
- `[BLOCKED-CEILING]` / `[BLOCKED-AMBIGUOUS]` / `[BLOCKED-CATEGORY]` / `[BLOCKED-PARSE]`: stop cleanly (do not apply further fixes).
- The pipeline stops cleanly rather than hanging on interactive prompts.
- The next session (with neither flag set) reads `## Open Questions` and resumes.

Use `CLAUDE_NONINTERACTIVE=1` for fully autonomous CI runs. Use `CLAUDE_CRITIC_NONINTERACTIVE=1` when you want interactive brainstorming/spec but automated critic loops.

## Hook exit code reference (verified against Anthropic docs)

Applies to the `Stop` and `SubagentStop` hooks used by `stop-check.sh`:

| Exit code | Meaning |
|-----------|---------|
| `0` | Allow stop — session ends normally |
| `2` | **Block stop** — session continues; stderr is fed back to Claude as context |
| `1` (or any other) | Non-blocking error — stop proceeds anyway (does **not** block) |

Use `exit 2` (never `exit 1`) when a hook must prevent Claude from stopping. This is the pattern used by `scripts/stop-check.sh`. Verified against Anthropic hooks reference (April 2026).
