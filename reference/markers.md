# Marker Registry

Single source of truth for all machine-readable markers used in plan files.
Includes per-marker Write/Read/Clear/gc lifecycle and operation→marker reverse lookup.

## Bracketed plan-file markers

### Critic loop markers (written to `## Open Questions`)

Managed by `scripts/lib/plan-lib.sh` and consumed by skills after each critic or pr-review run. Policy: `@reference/critics.md §Loop convergence`.

| Marker | Scope | Written by | Clear path | Survives gc? |
|--------|-------|------------|------------|-------------|
| `[BLOCKED-CEILING] {phase}/{agent}: exceeded {N} runs — manual review required` | phase-scoped | `plan-lib.sh _record_loop_state` | `plan-file.sh reset-milestone {agent}` | Yes |
| `[BLOCKED] category:{agent}: {CATEGORY} failed twice — fix the root cause before retrying` | agent-scoped | `plan-lib.sh cmd_record_verdict` | Manual `plan-file.sh clear-marker` | Yes |
| `[BLOCKED] parse:{agent}: verdict marker missing (two consecutive parse errors) — check agent output format before retrying` | agent-scoped | `plan-lib.sh cmd_record_verdict` | Manual `plan-file.sh clear-marker` | Yes |
| `[BLOCKED] parse:{agent}: FAIL without category (two consecutive parse errors) — check agent output format before retrying` | agent-scoped | `plan-lib.sh cmd_record_verdict` | Manual `plan-file.sh clear-marker` | Yes |
| `[BLOCKED-AMBIGUOUS] {agent}: {question}` | agent-scoped | Skills (parent context) | Manual `plan-file.sh clear-marker` | Yes |
| `[CONVERGED] {phase}/{agent}` | phase-scoped | `plan-lib.sh _record_loop_state` | `plan-file.sh reset-milestone {agent}` or `clear-converged {agent}` | Yes |
| `[FIRST-TURN] {phase}/{agent}` | phase-scoped | `plan-lib.sh _record_loop_state` | `plan-file.sh reset-milestone {agent}` | Yes |

### Non-loop stop markers (written to `## Open Questions`)

Written by skills or hooks outside the critic convergence protocol.

| Marker | Emitter | Effect | Clear path | Survives gc? |
|--------|---------|--------|------------|-------------|
| `[BLOCKED] {reason}` | Various skills | Generic stop — human action required | Manual `plan-file.sh clear-marker` after fixing | Yes |
| `[BLOCKED] coder:{task-id} — {reason}` | run-implement.sh | Coder hit unresolvable blocker or abort | Manual `plan-file.sh clear-marker` | Yes |
| `[BLOCKED] post-implement smoke test failed — full test suite not passing after all tiers` | run-implement.sh | Full test suite failed after all task tiers merged — check for unimplemented tests or regressions | Manual `plan-file.sh clear-marker` after fixing failing tests | Yes |
| `[BLOCKED] preflight:{tool}: {fix}` | preflight.sh | Autonomous pre-flight check failed | Fix prerequisite, then `plan-file.sh clear-marker` | Yes |
| `[BLOCKED] integration:{test}: {reason}` | running-integration-tests | Failure category ambiguous — manual review required | Manual | Yes |
| `[BLOCKED] integration: mixed failure categories ({categories}) — manual review required` | run-integration.sh | Integration failures in current run span multiple root-cause categories — cannot apply a single automated fix; manual triage required | Manual `plan-file.sh clear-marker "[BLOCKED] integration: mixed"` after diagnosing root cause | Yes |
| `[BLOCKED] {agent}: session-timeout after {N}s — increase CLAUDE_CRITIC_SESSION_TIMEOUT or re-run` | `run-critic-loop.sh` | Critic session timed out — increase `CLAUDE_CRITIC_SESSION_TIMEOUT` or re-run | Manual `plan-file.sh clear-marker` after adjusting timeout | Yes |
| `[BLOCKED] {agent}: no timeout binary — install GNU coreutils (brew install coreutils) or set CLAUDE_CRITIC_SESSION_TIMEOUT=0 to disable the cap` | `run-critic-loop.sh` | No `gtimeout`/`timeout` binary — install GNU coreutils or disable the cap | Manual `plan-file.sh clear-marker` after installing or disabling | Yes |
| `[BLOCKED] {agent}: plan unchanged for {N} consecutive iterations — critic is not writing to plan file; check session logs` | `run-critic-loop.sh` | Critic session produced no verdicts — check session logs | Manual `plan-file.sh clear-marker` after debugging | Yes |
| `[BLOCKED] protocol-violation:{agent}: invoked outside run-critic-loop.sh context` | `plan-lib.sh cmd_record_verdict_guarded` | SubagentStop hook detected a critic agent running outside `run-critic-loop.sh`; plan file flagged | Manual `plan-file.sh clear-marker "[BLOCKED] protocol-violation"` after diagnosing | Yes |
| `[STOP-BLOCKED @ts] phase={p} — {reason}` | stop-check.sh | Why Stop hook blocked the previous stop attempt | Informational; survives `gc-events` | Yes |

### Integration test markers (written to `## Integration Failures`)

Written by `running-integration-tests`; do not interact with the critic convergence protocol.

| Marker | Emitter | Effect | Clear path |
|--------|---------|--------|------------|
| `[AUTO-CATEGORIZED-INTEGRATION] {test name}: {category}` | running-integration-tests | Failure category inferred; fix skill invoked | Log entry — persists in `## Integration Failures`; not processed by `gc-events` |

### Audit and run markers

Written to `## Critic Verdicts`; not subject to `gc-events`.

| Marker | Section | Emitter | Effect |
|--------|---------|---------|--------|
| `[MILESTONE-BOUNDARY @ts] {scope}:` | `## Critic Verdicts` | `reset-milestone`, `reset-pr-review` | Breaks trailing-PASS streak; prior milestone verdicts do not count toward new streak |

### Inline plan-file markers

| Marker | Emitter | Survives `gc-events`? | Effect |
|--------|---------|----------------------|--------|
| `[UNVERIFIED CLAIM]` | brainstorming skill | Yes | Provisional assumption that was not web-verified; critic-spec will flag it |
| `[AUTO-DECIDED] {skill}/{step}: {decision}` | implementing skill | No | Architectural choice made without asking |
| `[INFO] {message}` | Various skills | Yes (falls through to `user_memos` in `gc-events`) | Informational log entry |

## HTML verdict envelopes

Format and rules: `@reference/critics.md §Verdict format` (single source of truth).

## Coder status signals

The coder agent emits a plain-text signal (not an HTML comment) to its output log:
- `coder-status: complete` — task finished successfully
- `coder-status: abort` — task could not be completed

Detected by `run-implement.sh` via `grep -q 'coder-status: complete'`.

## Audit outcome words

Written by parent-context ultrathink audit to `## Verdict Audits` via `plan-file.sh append-audit`. Full protocol and outcome table: `@reference/ultrathink.md §Audit outcomes`.

## Category enum values

Category enum values and priority: `@reference/severity.md §Category priority`

## Phase-scoped convergence markers

Canonical list: `PHASE_CONVERGENCE_MARKERS` array in `scripts/lib/plan-lib.sh` (`_clear_convergence_markers`). All markers require `{phase}` to equal the current plan phase — stale markers from prior phases do not satisfy a check.

| Phase | Agent | Invocation site |
|-------|-------|-----------------|
| `brainstorm` | `critic-feature` | `skills/running-dev-cycle/SKILL.md` Step 1 |
| `spec` | `critic-spec` | `skills/running-dev-cycle/SKILL.md` Step 2a (feature-slice) / Step 2 (batch) |
| `red` | `critic-test` | `skills/running-dev-cycle/SKILL.md` Step 2b (feature-slice) / Step 3 (batch) |
| `implement` | `critic-code` | `skills/running-dev-cycle/SKILL.md` Step 2c |
| `review` | `pr-review` | `skills/running-dev-cycle/SKILL.md` Step 2c (always called with `--phase review`; `reset-pr-review` also clears `implement/pr-review` defensively — see §Operation → markers reverse lookup) |

Markers written under `{phase}/{agent}` use the phase value from the plan file at the time `record-verdict` runs — not the agent's conceptual owner phase.

`review/critic-code` has no active invocation site — the cleanup in `cmd_reset_for_rollback` (`scripts/lib/plan-lib.sh`) defensively clears stale markers that would arise if `critic-code` ever ran while the plan phase was `review`.

## Operation → markers reverse lookup

What each command writes, clears, keeps, and discards in `## Open Questions` (unless noted).

| Operation | Markers written | Markers cleared | Notes |
|-----------|----------------|----------------|-------|
| `reset-milestone {agent}` | `[MILESTONE-BOUNDARY]` (→ Critic Verdicts) | 3 phase-scoped markers (§Phase-scoped convergence markers) for `{phase}/{agent}` | Does NOT clear `[BLOCKED]` variants — those require manual `clear-marker` |
| `reset-pr-review` | `2× [MILESTONE-BOUNDARY]` (→ Critic Verdicts, one per phase: `implement/pr-review` and `review/pr-review`) | Same 3 markers for `implement/pr-review` and `review/pr-review` | Does NOT clear `[BLOCKED]` variants |
| `reset-for-rollback {target-phase}` | 3× `[MILESTONE-BOUNDARY]` (→ Critic Verdicts) | 3 markers for `{new-phase}/critic-code` (via `reset-milestone`) + 3 for `implement/pr-review` + 3 for `review/pr-review` (via `reset-pr-review`) + 3 stale `review/critic-code` markers (via `_clear_convergence_markers`) | Calls `set-phase`, `reset-milestone critic-code`, `reset-pr-review`, then `_clear_convergence_markers "review/critic-code"` |
| `clear-converged {agent}` | REJECT-PASS sentinel (→ Critic Verdicts, streak reset) | `[CONVERGED] {phase}/{agent}` | Use on REJECT-PASS audit outcome before entering FAIL path |
| `clear-marker {text}` | — | Any line in `## Open Questions` containing `{text}` | Low-level; prefer `reset-milestone` for milestone transitions |
| `gc-events` | — | Discards: `[AUTO-DECIDED]`. Keeps all: `[BLOCKED*]`, `[STOP-BLOCKED]`, `[CONVERGED]`, `[FIRST-TURN]`, `[UNVERIFIED CLAIM]`. User-memos fallthrough preserves anything else. | `[INFO]` and unrecognized markers survive via user_memos fallthrough |
| `record-verdict` | `[FIRST-TURN]`, `[CONVERGED]`, `[BLOCKED-CEILING]` via `_record_loop_state`; `[BLOCKED] parse:` on consecutive PARSE_ERROR; `[BLOCKED] category:` on consecutive same-category FAIL | — | Also appends verdict line to `## Critic Verdicts` |
| `transition <plan-file> <to-phase> <reason>` | — | — | Sets phase in the plan file; callers must call `reset-milestone` explicitly if a streak reset is needed |
| `commit-phase <plan-file> <msg>` | — | — | Stages plan file and commits; call after `transition` |
| `set-phase <plan-file> <phase>` | — | — | Writes phase to the plan file's `## Phase` section and frontmatter |
| `append-review-verdict <plan-file> <agent> PASS\|FAIL` | `[FIRST-TURN]`, `[CONVERGED]`, `[BLOCKED-CEILING]` | — | Same streak/ceiling/FIRST-TURN/CONVERGED logic as `record-verdict`; no category tracking |
| `record-stop-block <plan-file> <phase> <reason>` | `[STOP-BLOCKED @ts] phase={p} — {reason}` (→ `## Open Questions`) | — | Survives `gc-events` |

## Implementation notes

- **`[INFO]`** — Falls through to `user_memos` in `gc-events`, treated like a user memo.

- **`[BLOCKED] category:`** — Persists across phase rollback by design: category escalation is phase-independent per `@reference/critics.md §Consecutive same-category escalation`. Recipe at `@reference/critics.md §Resuming from a BLOCKED marker`.

- **`[BLOCKED] parse:`** — Persists across phase rollback by design. Recipe at `@reference/critics.md §Resuming from a BLOCKED marker`.

- **`[BLOCKED-AMBIGUOUS]`** — Persists across phase rollback by design: the embedded question requires human input to resolve; auto-clearing on phase transition would discard the question before the human can act. Recipe: resolve the stated question, then `plan-file.sh clear-marker "[BLOCKED-AMBIGUOUS] {agent}"` and re-run.
