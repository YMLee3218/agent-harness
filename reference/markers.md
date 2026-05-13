# Marker Registry

Single source of truth for all machine-readable markers used in plan files.
Includes per-marker Write/Read/Clear/gc lifecycle and operation→marker reverse lookup.

> **Single source of truth**: which markers Claude cannot clear is defined by the `HUMAN_MUST_CLEAR_MARKERS` array in `scripts/phase-policy.sh`. `plan-file.sh` Ring C blocks all `clear-marker` calls — `CLAUDE_PLAN_CAPABILITY=human` is required. When adding a new human-must-clear marker, update the array first, then update the table below. Enforcement uses the `marker_present_human_must_clear` helper (also in `phase-policy.sh`), called by `scripts/phase-gate.sh` (`_guard_human_must_clear`) and `scripts/pretooluse-bash.sh` to block Write/Edit and Bash writes respectively; `scripts/lib/plan-cmd.sh` `cmd_unblock` also derives its awk preserve pattern from the same array.

## Bracketed plan-file markers

### Critic loop markers (written to `## Open Questions`)

Managed by `scripts/lib/plan-loop-helpers.sh` and `scripts/lib/plan-cmd.sh`; consumed by skills after each critic or pr-review run. Policy: `@reference/critics.md §Loop convergence`.

| Marker | Scope | Written by | Clear path | Survives gc? |
|--------|-------|------------|------------|-------------|
| `[BLOCKED-CEILING] {phase}/{agent}: exceeded {N} runs — manual review required` | phase-scoped | `plan-loop-helpers.sh _record_loop_state` | `plan-file.sh reset-milestone {agent}` | Yes |
| `[BLOCKED] category:{agent}: {CATEGORY} failed twice — fix the root cause before retrying` | agent-scoped | `plan-cmd.sh cmd_record_verdict` | Manual `plan-file.sh clear-marker` | Yes |
| `[BLOCKED] parse:{agent}: verdict marker missing (two consecutive parse errors) — check agent output format before retrying` | agent-scoped | `plan-cmd.sh cmd_record_verdict` | Manual `plan-file.sh clear-marker` | Yes |
| `[BLOCKED] parse:{agent}: FAIL without category (two consecutive parse errors) — check agent output format before retrying` | agent-scoped | `plan-cmd.sh cmd_record_verdict` | Manual `plan-file.sh clear-marker` | Yes |
| `[BLOCKED-AMBIGUOUS] {agent}: {question}` | agent-scoped | Skills (parent context) | Manual `plan-file.sh clear-marker` | Yes |
| `[FIRST-TURN] {phase}/{agent}` | phase-scoped | `plan-loop-helpers.sh _record_loop_state` | `plan-file.sh reset-milestone {agent}` | Yes |

> **Authoritative convergence state**: lives exclusively in `plans/{slug}.state/convergence/{phase}__{agent}.json` — updated on every verdict by `_record_loop_state`. Query via `plan-file.sh is-converged <plan> <phase> <agent>` (exit 0 = converged). No plan.md marker mirrors this state.

### Non-loop stop markers (written to `## Open Questions`)

Written by skills or hooks outside the critic convergence protocol.

| Marker | Emitter | Effect | Clear path | Survives gc? |
|--------|---------|--------|------------|-------------|
| `[BLOCKED] {category}: {reason}` | Various harness scripts and skills | Harness stop requiring human action; category identifies source (e.g. `coder:`, `preflight:`, `integration:`, `parse:`, `protocol-violation:`, `runtime:`, `script-failure:`, `session-timeout`, `no timeout binary`, `plan unchanged`). Sidecar integrity failures use inline form: `[BLOCKED] kind=corrupt`, `[BLOCKED] kind=corrupt-check`, `[BLOCKED] kind=streak`. | Manual `plan-file.sh clear-marker` after resolving — see `HUMAN_MUST_CLEAR_MARKERS` in `scripts/phase-policy.sh` for full list | Yes |
| `[ESCALATION] {agent}: {ENVELOPE_MISMATCH\|ENVELOPE_OVERREACH} — {reason}` | `run-critic-loop.sh` (exit 4 path) | Operating envelope must be corrected before re-running the critic; triggers `llm_exit` exit 4 in callers | Manual `plan-file.sh clear-marker` after correcting the spec's Operating Envelope | Yes |
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
| `[IMPLEMENTED: {feat-slug}]` | `plan-file.sh mark-implemented` (Ring B) | Yes | Records a completed feature slug; authoritative state is in `plans/{slug}.state/implemented.json` |

## Sidecar control state

Persistent harness state lives in `plans/{slug}.state/` — written only by harness scripts, never by agent tool calls (blocked by `settings.json` deny rules and `phase-gate.sh`). The transient critic lock file (`plans/{slug}.md.critic.lock`) is also harness-exclusive but lives adjacent to the plan file, not inside `.state/`.

### Key sidecar files

| File | Format | Written by | Read by | Lifecycle |
|------|--------|------------|---------|-----------|
| `convergence/{phase}__{agent}.json` | JSON | `_record_loop_state` (via SubagentStop hook) | `is-converged` (`run-dev-cycle.sh`, `run-critic-loop.sh`) | Created on first verdict; reset via `reset-milestone`/`clear-converged`; `converged=true` requires ≥2 consecutive PASSes |
| `verdicts.jsonl` | JSONL (append-only) | `_record_loop_state` | `is-converged` (streak computation) | Appended per verdict; GC via `_sc_rotate_jsonl` in `scripts/lib/sidecar.sh` (not invoked automatically — file grows until milestone reset or manual cleanup) |
| `blocked.jsonl` | JSONL (append-only) | `_record_loop_state` (ceiling), `cmd_record_verdict` (parse/category), `cmd_append_note` (BLOCKED mirror) | `is-blocked`/`has-blocked` (`stop-check.sh`, `run-critic-loop.sh`) | `cleared_at:null` = open; set by `clear-marker`/`unblock` |
| `implemented.json` | JSON | `mark-implemented` | `is-implemented` (`run-dev-cycle.sh`) | Feature slugs accumulate; never cleared |

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

Both commands read the sidecar `blocked.jsonl` exclusively. If `blocked.jsonl` is absent (no blocks ever written), they return "not blocked".

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

Cleared per scope by `plan-file.sh reset-milestone {agent}` (invokes `cmd_reset_milestone` in `scripts/lib/plan-cmd.sh`, which calls `cmd_clear_marker` + `_clear_ceiling_sidecar_entry`): `[BLOCKED-CEILING]` and `[FIRST-TURN]`. All markers require `{phase}` to equal the current plan phase — stale markers from prior phases do not satisfy a check.

| Phase | Agent | Invocation site |
|-------|-------|-----------------|
| `brainstorm` | `critic-feature` | `scripts/run-dev-cycle.sh` (feature brainstorm phase) |
| `spec` | `critic-spec` | `scripts/run-dev-cycle.sh` (Phase 1: per-feature spec pre-pass) |
| `spec` | `critic-cross` | `scripts/run-dev-cycle.sh` (Phase 2: cross-feature spec consistency review, once per plan) |
| `red` | `critic-test` | `scripts/run-dev-cycle.sh` (Phase 3: per-feature test/implement loop) |
| `implement` | `critic-code` | `scripts/run-dev-cycle.sh` (Phase 3: per-feature test/implement loop) |
| `review` | `pr-review` | `scripts/run-dev-cycle.sh` (always called with `--phase review`; `reset-pr-review` also clears `implement/pr-review` defensively) |

Markers written under `{phase}/{agent}` use the phase value from the plan file at the time `record-verdict` runs — not the agent's conceptual owner phase.

`review/critic-code` has no active invocation site — the cleanup in `cmd_reset_phase_state` (`scripts/lib/plan-cmd.sh`) defensively clears stale markers that would arise if `critic-code` ever ran while the plan phase was `review`.
