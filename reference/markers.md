# Marker Registry

Single source of truth for all machine-readable markers used in plan files.
Includes per-marker Write/Read/Clear/gc lifecycle and operation→marker reverse lookup.

## Bracketed plan-file markers

### Critic loop markers (written to `## Open Questions`)

Managed by `scripts/lib/plan-verdicts.sh` and consumed by skills after each critic or pr-review run. Policy: `@reference/critics.md §Loop convergence`.

| Marker | Scope | Emitter | Consumer | Effect | Clear path | Written by | gc |
|--------|-------|---------|----------|--------|------------|------------|----|
| `[BLOCKED-CEILING] {phase}/{agent}` | phase-scoped | `plan-verdicts.sh record-verdict` | Skill (§Skill branching logic) | Stop — total runs exceeded ceiling; manual review required | `plan-file.sh reset-milestone {agent}` | `plan-verdicts.sh _record_loop_state` | Yes |
| `[BLOCKED-CATEGORY] {agent}` | agent-scoped | `plan-verdicts.sh record-verdict` | Skill | Stop — two consecutive FAILs with same category; fix root cause first | Manual `plan-file.sh clear-marker` after fixing | `plan-verdicts.sh cmd_record_verdict` | Yes |
| `[BLOCKED-AMBIGUOUS] {agent}: {question}` | agent-scoped | Skill (parent context) | Skill | Stop — fix direction unclear; human decision required | Manual `plan-file.sh clear-marker` after human resolves | Skills (parent context) | Yes |
| `[BLOCKED-PARSE] {agent}` | agent-scoped | `plan-verdicts.sh record-verdict` | Skill | Stop — verdict marker missing twice consecutively; investigate agent output | Manual `plan-file.sh clear-marker` after fixing agent format | `plan-verdicts.sh cmd_record_verdict` | Yes |
| `[CONVERGED] {phase}/{agent}` | phase-scoped | `plan-verdicts.sh record-verdict` | Skill | PASS streak ≥ 2 — proceed to next step | `plan-file.sh reset-milestone {agent}` or `plan-file.sh clear-converged {agent}` | `plan-verdicts.sh _record_loop_state` | Yes |
| `[FIRST-TURN] {phase}/{agent}` | phase-scoped | `plan-verdicts.sh record-verdict` | Skill | First real verdict for this phase+agent — ask user to confirm, then re-run | `plan-file.sh reset-milestone {agent}` | `plan-verdicts.sh _record_loop_state` | Yes |
| `[CONFIRMED-FIRST] {phase}/{agent}` | phase-scoped | `plan-file.sh record-confirmed-first` | Skill | User confirmed FIRST-TURN in a prior session — re-run without re-confirming | `plan-file.sh reset-milestone {agent}` | `plan-verdicts.sh cmd_record_confirmed_first` | Yes |
| `[AUTO-APPROVED-FIRST] {phase}/{agent}` | phase-scoped | `plan-file.sh record-auto-approved FIRST` | Skill | Non-interactive: FIRST-TURN auto-approved in prior session — re-run automatically | `plan-file.sh reset-milestone {agent}` | `plan-verdicts.sh cmd_record_auto_approved` | Yes |

### Non-loop stop markers (written to `## Open Questions`)

Written by skills or hooks outside the critic convergence protocol.

| Marker | Emitter | Effect | Clear path | Written by | gc |
|--------|---------|--------|------------|------------|----|
| `[BLOCKED] {reason}` | Various skills | Generic stop — human action required | Manual `plan-file.sh clear-marker` after fixing | Various skills | Yes |
| `[BLOCKED-FINAL] critic-feature` | brainstorming skill | critic-feature failed twice — manual review required (see `@reference/critics.md §Brainstorm exception`) | Manual `plan-file.sh clear-marker` | brainstorming skill | Yes |
| `[BLOCKED-CODER] {reason}` | coder agent | Coder hit an unresolvable blocker | Manual `plan-file.sh clear-marker` | coder agent | Yes |
| `[BLOCKED-PREFLIGHT] {description} — {fix}` | running-dev-cycle | Autonomous pre-flight check failed | Fix prerequisite, then `plan-file.sh clear-marker` | running-dev-cycle | Yes |
| `[STOP-BLOCKED @ts] phase={p} — {reason}` | stop-check.sh | Why Stop hook blocked the previous stop attempt | Informational; survives `gc-events` | `plan-ledger.sh cmd_record_stop_block` | Yes |
| `[DEFERRED-ERROR] {err-id} {file}:{line} — {description}` | implementing skill | Distant-scope pre-existing error deferred for later fix | Manual `plan-file.sh clear-marker` after fixing | implementing skill | Yes |

### Integration test markers (written to `## Integration Failures`)

Written by `running-integration-tests`; do not interact with the critic convergence protocol.

| Marker | Emitter | Effect | Clear path |
|--------|---------|--------|------------|
| `[BLOCKED-INTEGRATION] {test name}: {reason}` | running-integration-tests | Category ambiguous — manual review required | Manual |
| `[AUTO-CATEGORIZED-INTEGRATION] {test name}: {category}` | running-integration-tests | Non-interactive: failure category inferred; fix skill invoked | Discarded by `gc-events` |

### Session event markers (written to `## Open Questions`)

Written by hook-driven commands in `scripts/lib/plan-ledger.sh`. Format: `[MARKER @ts] detail`.

| Marker | Emitter | Written by | Survives `gc-events`? | Effect |
|--------|---------|------------|-----------------------|--------|
| `[PRE-COMPACT @ts] trigger={t}` | `plan-ledger.sh flush-before-compact` | `plan-ledger.sh cmd_flush_before_compact` | No | Signals compaction is about to occur |
| `[POST-COMPACT @ts] phase={p} open_questions={n}` | `plan-ledger.sh log-post-compact` | `plan-ledger.sh cmd_log_post_compact` | Yes (last entry only) | Sanity-check after compaction; phase + open-question count |
| `[SESSION-END @ts] reason={r}` | `plan-ledger.sh flush-on-end` | `plan-ledger.sh cmd_flush_on_end` | Yes (last entry only) | Clean session exit marker |

### Audit and run markers

Written to `## Critic Verdicts`; not subject to `gc-events`.

| Marker | Section | Emitter | Effect |
|--------|---------|---------|--------|
| `[MILESTONE-BOUNDARY @ts] {scope}:` | `## Critic Verdicts` | `reset-milestone`, `reset-pr-review`, `clear-converged` | Breaks trailing-PASS streak; prior milestone verdicts do not count toward new streak |

### Inline plan-file markers

| Marker | Emitter | Survives `gc-events`? | Effect |
|--------|---------|----------------------|--------|
| `[UNVERIFIED CLAIM]` | brainstorming skill (non-interactive) | Yes | Provisional assumption that was not web-verified; critic-spec will flag it |
| `[AUTO-DECIDED] {skill}/{step}: {decision}` | implementing skill | No | Non-interactive: architectural choice made without asking |
| `[INFO] {message}` | Various skills | Yes (intentional — falls through to `user_memos` in `gc-events:164`, treated like a user memo) | Informational log entry |

## HTML verdict envelopes

Canonical format and machine-parsing rules: `@reference/critics.md §Verdict format`. The `<!-- coder-status: X -->` marker (`complete` | `abort`) is written by the coder agent to signal completion or abort.

## Audit outcome words

Written by parent-context ultrathink audit to `## Verdict Audits` via `plan-file.sh append-audit`. Full protocol: `@reference/critics.md §Applying the audit outcome`.

| Word | Condition | Action |
|------|-----------|--------|
| `ACCEPT` | Verdict is sound | Adopt verdict; proceed to §Skill branching logic |
| `REJECT-PASS` | Subagent returned PASS but audit found a gap | Call `clear-converged` then enter FAIL path |
| `BLOCKED-AMBIGUOUS` | Audit inconclusive | Append `[BLOCKED-AMBIGUOUS]` and stop |

## Category enum values

Category enum values and priority: `@reference/severity.md §Category priority`

## Phase-scoped convergence markers

> Canonical set cleared by `reset-milestone` (implementation: `_clear_convergence_markers` in `scripts/lib/plan-verdicts.sh`):
> `[BLOCKED-CEILING]`, `[CONVERGED]`, `[FIRST-TURN]`, `[CONFIRMED-FIRST]`, `[AUTO-APPROVED-FIRST]`
>
> All five require `{phase}` to equal the current plan file phase — stale markers from prior phases do not satisfy a check.

## Operation → markers reverse lookup

What each command writes, clears, keeps, and discards in `## Open Questions` (unless noted).

| Operation | Markers written | Markers cleared | Notes |
|-----------|----------------|----------------|-------|
| `reset-milestone {agent}` | `[MILESTONE-BOUNDARY]` (→ Critic Verdicts) | 5 phase-scoped markers (§Phase-scoped convergence markers) for `{phase}/{agent}` | Does NOT clear `[BLOCKED-CATEGORY]`, `[BLOCKED-PARSE]`, `[BLOCKED-AMBIGUOUS]` — those require manual `clear-marker` |
| `reset-pr-review` | `[MILESTONE-BOUNDARY]` (→ Critic Verdicts) | Same 5 markers for `implement/pr-review` and `review/pr-review` | Does NOT clear `[BLOCKED-CATEGORY]`, `[BLOCKED-PARSE]`, `[BLOCKED-AMBIGUOUS]` |
| `reset-for-rollback {target-phase}` | 2× `[MILESTONE-BOUNDARY]` (→ Critic Verdicts) | 5 markers for `{new-phase}/critic-code` (via `reset-milestone`) + 5 for `implement/pr-review` + 5 for `review/pr-review` (via `reset-pr-review`) + 5 stale `review/critic-code` markers (via `_clear_convergence_markers`) | Calls `set-phase`, `reset-milestone critic-code`, `reset-pr-review`, then `_clear_convergence_markers "review/critic-code"`; `[BLOCKED-CATEGORY]` still not cleared |
| `clear-converged {agent}` | REJECT-PASS sentinel (→ Critic Verdicts, streak reset) | `[CONVERGED] {phase}/{agent}` | Use on REJECT-PASS audit outcome before entering FAIL path |
| `clear-marker {text}` | — | Any line in `## Open Questions` containing `{text}` | Low-level; prefer `reset-milestone` for milestone transitions |
| `gc-events` | — | Discards: `[PRE-COMPACT]`, `[AUTO-DECIDED]`. Keeps last: `[SESSION-END]`, `[POST-COMPACT]`. Keeps all: `[BLOCKED*]`, `[STOP-BLOCKED]`, `[DEFERRED-ERROR]`, `[CONVERGED]`, `[FIRST-TURN]`, `[CONFIRMED-FIRST]`, `[AUTO-APPROVED-FIRST]`, `[UNVERIFIED CLAIM]`. User-memos fallthrough preserves anything else. | `[INFO]` and unrecognized markers survive via user_memos fallthrough |
| `record-verdict` | `[FIRST-TURN]`, `[CONVERGED]`, `[BLOCKED-CEILING]` via `_record_loop_state`; `[BLOCKED-PARSE]` on consecutive PARSE_ERROR; `[BLOCKED-CATEGORY]` on consecutive same-category FAIL | — | Also appends verdict line to `## Critic Verdicts` |
| `record-auto-approved FIRST` | `[AUTO-APPROVED-FIRST] {phase}/{agent}` | — | Survives gc; must persist to avoid re-triggering first-turn auto-approval on resume |
| `record-confirmed-first` | `[CONFIRMED-FIRST] {phase}/{agent}` | — | Dedup-safe: no-op if already present |
| `transition <plan-file> <to-phase> <reason>` | — | — | Sets phase + `.state.json`; callers must call `reset-milestone` explicitly if a streak reset is needed |
| `advance-phase <plan-file> <to-phase> <reason> <msg>` | — | — | Wraps `transition` + internal commit; stages plan file + `.state.json` and commits |
| `set-phase <plan-file> <phase>` | — | — | Writes `.state.json` for machine-read durability; does not commit |
| `append-review-verdict <plan-file> <agent> PASS\|FAIL` | `[FIRST-TURN]`, `[CONVERGED]`, `[BLOCKED-CEILING]`, `[BLOCKED-PARSE]` | — | Same streak/ceiling/FIRST-TURN/CONVERGED logic as `record-verdict`; no `[BLOCKED-CATEGORY]` |
| `report-error <plan-file> <task-id> …` | — | — | `err-id` auto-assigned inside an atomic lock — safe for concurrent coder worktrees |
| `record-stop-block <plan-file> <phase> <reason>` | `[STOP-BLOCKED @ts] phase={p} — {reason}` (→ `## Open Questions`) | — | Survives `gc-events` |
| `record-integration-attempt <plan-file>` | — | — | Locked read-modify-write on `.state.json`; counter survives `/compact` |

## Implementation notes

- **`[INFO]`** — Falls through to `user_memos` in `gc-events`, treated like a user memo.

- **`[BLOCKED-CATEGORY]`** — Persists across phase rollback by design: category escalation is phase-independent per `@reference/critics.md §Consecutive same-category escalation`. Recipe at `@reference/critics.md §Resuming from a BLOCKED-* marker`.

- **`[BLOCKED-PARSE]`** — Persists across phase rollback by design. Recipe at `@reference/critics.md §Resuming from a BLOCKED-* marker`.
