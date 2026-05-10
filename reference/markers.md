# Marker Registry

Single source of truth for all machine-readable markers used in plan files.
Includes per-marker Write/Read/Clear/gc lifecycle and operation→marker reverse lookup.

> **Single source of truth**: which markers Claude cannot clear is defined by the `HUMAN_MUST_CLEAR_MARKERS` array in `scripts/phase-policy.sh`. `pretooluse-bash.sh` consumes this array directly to decide whether to block. When adding a new human-must-clear marker, update the array first, then update the table below.

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
| `[CONVERGED] {phase}/{agent}` | phase-scoped | `plan-lib.sh _record_loop_state` (informational mirror only) | `plan-file.sh reset-milestone {agent}` or `clear-converged {agent}` | Yes |
| `[FIRST-TURN] {phase}/{agent}` | phase-scoped | `plan-lib.sh _record_loop_state` | `plan-file.sh reset-milestone {agent}` | Yes |

> **Never write [CONVERGED] manually.** The authoritative convergence state lives in `plans/{slug}.state/convergence/{phase}__{agent}.json` — written only by the SubagentStop hook via `record-verdict-guarded`. The `[CONVERGED]` marker in `## Open Questions` is an informational mirror; **the harness never reads it** for convergence decisions. Even if written manually, `is-converged` (called by `run-dev-cycle.sh` and `run-critic-loop.sh`) reads the sidecar only and will return false.

### Non-loop stop markers (written to `## Open Questions`)

Written by skills or hooks outside the critic convergence protocol.

| Marker | Emitter | Effect | Clear path | Survives gc? |
|--------|---------|--------|------------|-------------|
| `[BLOCKED] {category}: {reason}` | Various harness scripts and skills | Harness stop requiring human action; category identifies source (e.g. `coder:`, `preflight:`, `integration:`, `parse:`, `protocol-violation:`, `runtime:`, `script-failure:`, `session-timeout`, `no timeout binary`, `plan unchanged`) | Manual `plan-file.sh clear-marker` after resolving — see `HUMAN_MUST_CLEAR_MARKERS` in `scripts/phase-policy.sh` for full list | Yes |
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
| `[INFO] {message}` | Various skills | Yes | Informational log entry |
| `[IMPLEMENTED: {feat-slug}]` | `plan-lib.sh mark-implemented` (Ring B) | Yes | Records a completed feature slug; authoritative state is in `plans/{slug}.state/implemented.json` |

## Sidecar control state

All harness control state lives in `plans/{slug}.state/` — written only by harness scripts, never by agent tool calls (blocked by `settings.json` deny rules and `phase-gate.sh`).

### Key sidecar files

| File | Format | Written by | Read by | Lifecycle |
|------|--------|------------|---------|-----------|
| `convergence/{phase}__{agent}.json` | JSON | `_record_loop_state` (via SubagentStop hook) | `is-converged` (`run-dev-cycle.sh`, `run-critic-loop.sh`) | Created on first verdict; reset via `reset-milestone`/`clear-converged`; `converged=true` requires ≥2 consecutive PASSes |
| `verdicts.jsonl` | JSONL (append-only) | `_record_loop_state` | `is-converged` (streak computation) | Appended per verdict; GC via `gc-sidecars` (rotates pre-milestone records, keeps 2 most recent milestone_seq values) |
| `blocked.jsonl` | JSONL (append-only) | `_record_loop_state` (ceiling), `cmd_record_verdict` (parse/category), `cmd_append_note` (BLOCKED mirror) | `is-blocked`/`has-blocked` (`stop-check.sh`, `run-critic-loop.sh`) | `cleared_at:null` = open; set by `clear-marker`/`unblock` |
| `implemented.json` | JSON | `mark-implemented` | `is-implemented` (`run-dev-cycle.sh`) | Feature slugs accumulate; never cleared |
| `.migrated_from_v2.txt` | text sentinel | `migrate-to-sidecar` | admin verification only (not read at runtime) | Presence confirms sidecar was bootstrapped from plan.md v2 markers |

### Convergence JSON schema (`convergence/{phase}__{agent}.json`)

```json
{
  "phase": "implement",
  "agent": "critic-code",
  "first_turn": true,
  "streak": 2,
  "converged": true,
  "ceiling_blocked": false,
  "ordinal": 2,
  "milestone_seq": 0
}
```

`milestone_seq` increments on every `reset-milestone` / `clear-converged` call, isolating streak history between milestones.

### Blocked JSONL record schema (`blocked.jsonl`)

```json
{"ts":"2025-05-10T12:00:00Z","kind":"ceiling","agent":"critic-code","scope":"implement/critic-code","message":"exceeded 5 runs","cleared_at":null}
```

`kind` enum: `ceiling | parse | category | protocol-violation | preflight | integration | coder | ambiguous | runtime`.

### Block-state queries (Ring A — agent-callable)

```bash
# Returns 0 if any uncleared block record exists; 1 if none
bash plan-file.sh is-blocked plans/{slug}.md
bash plan-file.sh has-blocked plans/{slug}.md          # alias

# Filter by kind
bash plan-file.sh is-blocked plans/{slug}.md integration
bash plan-file.sh is-blocked plans/{slug}.md ceiling

# Returns 0 if sidecar convergence file says converged=true; 1 otherwise
bash plan-file.sh is-converged plans/{slug}.md implement critic-code
```

Both commands read the sidecar `blocked.jsonl` exclusively. If `blocked.jsonl` is absent (no blocks ever written), they return "not blocked". The plan.md grep fallback has been removed — run `migrate-to-sidecar` on any pre-migration plan before querying block state.

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
| `brainstorm` | `critic-feature` | `scripts/run-dev-cycle.sh` (feature brainstorm phase) |
| `spec` | `critic-spec` | `scripts/run-dev-cycle.sh` (Phase 1: per-feature spec pre-pass) |
| `spec` | `critic-cross` | `scripts/run-dev-cycle.sh` (Phase 2: cross-feature spec consistency review, once per plan) |
| `red` | `critic-test` | `scripts/run-dev-cycle.sh` (Phase 3: per-feature test/implement loop) |
| `implement` | `critic-code` | `scripts/run-dev-cycle.sh` (Phase 3: per-feature test/implement loop) |
| `review` | `pr-review` | `scripts/run-dev-cycle.sh` (always called with `--phase review`; `reset-pr-review` also clears `implement/pr-review` defensively — see §Operation → markers reverse lookup) |

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
| `gc-events` | — | Discards: `[AUTO-DECIDED]` and blank lines. All other `## Open Questions` content is kept. | Simplified since control state now lives in sidecar |
| `gc-sidecars <plan-file>` | — | — | Rotates `verdicts.jsonl` (keeps 2 most recent milestone_seq values) and archives old cleared `blocked.jsonl` records; run automatically by `run-critic-loop.sh` after each iteration |
| `record-verdict` | `[FIRST-TURN]`, `[CONVERGED]` (informational mirror), `[BLOCKED-CEILING]` via `_record_loop_state`; `[BLOCKED] parse:` on consecutive PARSE_ERROR; `[BLOCKED] category:` on consecutive same-category FAIL | — | Also writes to `plans/{slug}.state/convergence/{phase}__{agent}.json` (authoritative) and appends to `verdicts.jsonl` |
| `transition <plan-file> <to-phase> <reason>` | — | — | Sets phase in the plan file; callers must call `reset-milestone` explicitly if a streak reset is needed |
| `commit-phase <plan-file> <msg>` | — | — | Stages plan file and commits; call after `transition` |
| `set-phase <plan-file> <phase>` | — | — | Writes phase to the plan file's `## Phase` section and frontmatter |
| `append-review-verdict <plan-file> <agent> PASS\|FAIL` | `[FIRST-TURN]`, `[CONVERGED]`, `[BLOCKED-CEILING]` | — | Same streak/ceiling/FIRST-TURN/CONVERGED logic as `record-verdict`; no category tracking |
| `record-stop-block <plan-file> <phase> <reason>` | `[STOP-BLOCKED @ts] phase={p} — {reason}` (→ `## Open Questions`) | — | Survives `gc-events` |
| `is-blocked <plan-file> [kind]` | — | — | Ring A read-only query; returns 0 if any uncleared record exists in `blocked.jsonl` (optionally filtered by kind); if blocked.jsonl absent, returns not-blocked + stderr warning (no plan.md fallback after D5) |
| `has-blocked <plan-file> [kind]` | — | — | Alias for `is-blocked` |
| `is-converged <plan-file> <phase> <agent>` | — | — | Ring A read-only query; returns 0 if `convergence/{phase}__{agent}.json` has `converged=true`; reads sidecar only |
| `is-implemented <plan-file> <feat-slug>` | — | — | Ring A read-only query; returns 0 if `implemented.json` contains `feat-slug` |

## Implementation notes

- **`[INFO]`** — Falls through to `user_memos` in `gc-events`, treated like a user memo.

- **`[BLOCKED] category:`** — Persists across phase rollback by design: once the streak fires (two consecutive same-category FAILs within a phase+milestone boundary per `@reference/critics.md §Consecutive same-category escalation`), the marker is not cleared by a phase transition — explicit `clear-marker` is required. Recipe at `@reference/critics.md §Resuming from a BLOCKED marker`.

- **`[BLOCKED] parse:`** — Persists across phase rollback by design. Recipe at `@reference/critics.md §Resuming from a BLOCKED marker`.

- **`[BLOCKED-AMBIGUOUS]`** — Persists across phase rollback by design: the embedded question requires human input to resolve; auto-clearing on phase transition would discard the question before the human can act. Recipe: resolve the stated question, then `plan-file.sh clear-marker "[BLOCKED-AMBIGUOUS] {agent}"` and re-run.
