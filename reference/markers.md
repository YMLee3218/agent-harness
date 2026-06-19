# Marker Registry

Single source of truth for all machine-readable markers used in plan files.
Includes per-marker Write/Read/Clear/gc lifecycle and operation→marker reverse lookup.

> **Single source of truth**: which markers Claude cannot clear is defined by the `HUMAN_MUST_CLEAR_MARKERS` array in `scripts/phase-policy.sh`. `plan-file.sh` Ring C blocks `unblock` without `CLAUDE_PLAN_CAPABILITY=human`. When adding a new human-must-clear kind, update the array first, then update the table below. Enforcement uses the `marker_present_human_must_clear` helper (also in `phase-policy.sh`), called by `scripts/phase-gate.sh` (`_guard_human_must_clear`, Write/Edit/MultiEdit/NotebookEdit), `scripts/pretooluse-bash.sh` (Bash writes and codex invocations), `scripts/pretooluse-agent.sh` (Agent subagent spawning), and `scripts/pretooluse-skill.sh` (Skill invocations targeting codex:*).

## Stop marker taxonomy

All stop markers use the unified prefix `[BLOCKED:{kind}]`. The `{kind}` encodes **where to fix** the problem (fix-level prefix), and the clearance axis determines **who clears** it.

### Standard format

```
[BLOCKED:{kind}] {scope}: {sub-kind} — {detail}
```

- `{kind}` — one of the 9 values in the table below.
- `{scope}` — identifies the emitter: critic agent name (`critic-code`, `critic-spec`, …), coder task (`coder:{task-id}`), or an agent-less identifier (`preflight:{tool}`, `integration`, `smoke`, `sidecar`, `run-dev-cycle`).
- `{sub-kind}` — first token of the body; identifies the specific condition (e.g., `ENVELOPE_MISMATCH`, `session-timeout`, `tests-failing`).
- `{detail}` — human-readable short explanation.

### Stop marker kinds

| Kind | Fix location | Clearance | exit |
|------|-------------|-----------|------|
| `[BLOCKED:envelope]` | Spec's Operating Envelope section | human-must | 1 |
| `[BLOCKED:docs]` | docs/spec/test — ground truth decision needed → cascade | human-must | 1 |
| `[BLOCKED:spec]` | Spec gap or ambiguity — human answer needed | human-must | 1 |
| `[BLOCKED:code]` | Code/test root cause (coder, integration, smoke) | human-must | 1 |
| `[BLOCKED:env]` | Environment/session/tool (persistent or recurring) | human-must | 1 |
| `[BLOCKED:harness]` | Harness call path, sidecar integrity, or reference data (enum/axis) extension | human-must | 1 |
| `[BLOCKED:ceiling]` | Critic loop ceiling exceeded → `reset-milestone` | human-must | 2 |
| `[BLOCKED:transient]` | **1-time transient state** (session timeout, lock clash) | **auto** — harness self-retries; never requires `unblock` | 1,3 |
| `[BLOCKED:merge-approval]` | Merge gate passed — awaiting human merge approval | human-must (merge action from main checkout) | 3 |

> **`[BLOCKED:merge-approval]` is stderr-only** — it is never written to `plan.md` and not in `HUMAN_MUST_CLEAR_MARKERS`; the pending state is tracked via `${PLAN%.md}.state/merge-approval.pending`. Exit 3 is the harness signal.

> **`[BLOCKED:transient]` is sidecar-only** — it is never written to `plan.md`. If one appears in `## Open Questions`, it was written incorrectly; `unblock` intentionally does not clear it. See §Transient auto-handling.

### Examples

```
[BLOCKED:envelope] coder:feat-x: ENVELOPE_MISMATCH — envelope declares single-tenant but DB is multi-tenant
[BLOCKED:docs] critic-spec: contradiction — docs may be stale, ground truth ambiguous; apply cascade
[BLOCKED:spec] critic-code: ambiguous — which encoding should be used for foo?
[BLOCKED:code] critic-code: parse — second consecutive PARSE_ERROR — fix critic output format
[BLOCKED:code] coder:feat-x: merge-conflict — resolve and re-run implementing
[BLOCKED:code] integration: tests-failing — after 1 fix attempt(s); manual review required
[BLOCKED:code] smoke: tests-failing — full suite not passing after all tiers
[BLOCKED:env] preflight:jq: not-installed — install via brew install jq
[BLOCKED:env] critic-code: no-timeout-binary — install GNU coreutils (brew install coreutils)
[BLOCKED:env] critic-code: session-timeout — recurred 3 times: after 3600s
[BLOCKED:harness] critic-code: protocol-violation — invoked outside run-critic-loop.sh context
[BLOCKED:harness] sidecar: corrupt-check — manual sidecar repair required
[BLOCKED:harness] writing-spec: reference-extension — axis Actors has no value for anonymous IoT device fleet; proposed addition: 'device-fleet'
[BLOCKED:harness] critic-code: reference-extension — category enum has no value covering "performance regression"; proposed addition: 'PERFORMANCE'
[BLOCKED:ceiling] critic-code: implement/critic-code exceeded 100 runs — manual review required
```

Transient (sidecar only, never plan.md):
```
[BLOCKED:transient] critic-code: session-timeout — after 3600s
[BLOCKED:transient] critic-code: loop-lock — critic loop already running
[BLOCKED:transient] critic-code: thinking-block-api-error — Claude API 400: thinking blocks modified in multi-turn session
```

## Clearing stop markers

**`unblock` — the single human command** (Ring C — `CLAUDE_PLAN_CAPABILITY=human` required):

```bash
export CLAUDE_PLAN_CAPABILITY=human
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" unblock "$CLAUDE_PROJECT_DIR/plans/{slug}.md"
```

Clears all 7 human-must kinds (`envelope`, `docs`, `spec`, `code`, `env`, `harness`, `ceiling`) from `## Open Questions` in one pass and sets `cleared_at` on their open sidecar records. `[BLOCKED:transient]` is intentionally excluded — it has its own auto lifecycle. Non-stop markers (`[UNVERIFIED CLAIM]`, `[INFO]`, `[AUTO-DECIDED]`, etc.) are also left untouched.

After resolving the root cause, run `unblock` then restart the autonomous run. Exception: for `[BLOCKED:ceiling]`, do **not** use `unblock` alone — use `reset-milestone {agent}` (Ring B — `export CLAUDE_PLAN_CAPABILITY=harness` required, not `=human`) instead (see the note below).

> **Ceiling block only**: for `[BLOCKED:ceiling]`, always use `reset-milestone {agent}` — never `unblock` alone. `reset-milestone` both clears the ceiling marker and increments `milestone_seq` so the next run's ordinal count starts at 0. `unblock` alone does not increment `milestone_seq`, so the next run recomputes `run_ordinal` from the same verdict history, finds it still exceeds the ceiling, and immediately re-blocks.

## Transient auto-handling

`[BLOCKED:transient]` markers are managed by `_record_transient` in `scripts/lib/sidecar.sh`. They **never** write to `plan.md`.

**Mechanism**:

1. Each `(agent, sub-kind)` pair has a counter in `plans/{slug}.state/transient_counters.json`.
2. Below threshold K (`CLAUDE_TRANSIENT_THRESHOLD`, default 3): counter increments; no plan.md write; the caller retries or exits (session-timeout exits run-critic-loop with 1; loop-lock exits with 3; thinking-block-api-error retries the session via loop continue). Re-run the harness — no `plan-file.sh unblock` needed since no blocked marker is written.
3. At K-th occurrence: `[BLOCKED:env] {agent}: {sub-kind} — recurred {K} times: {detail}` is written to `## Open Questions`; counter resets.
4. Counter reset also on: any completed critic session (successful session exit), `reset-milestone` (target agent's counters only — uses `_clear_transient_for`), `reset-for-rollback` (all agents' counters — uses `_reset_all_transient_counters`).
5. `unblock` does not touch transient counters — they have their own lifecycle.

**Transient sub-kinds** (closed set — additions require explicit policy review):
- `session-timeout` — critic session hit `CLAUDE_CRITIC_SESSION_TIMEOUT` wall
- `loop-lock` — critic loop already running (lock file conflict)
- `thinking-block-api-error` — transient critic infrastructure failure; two distinct root causes share this counter: (1) Claude API 400: thinking/redacted_thinking blocks modified between turns, (2) Codex empty output or CODEX-INFRA-FAILURE sentinel; session retried automatically in both cases

## Non-loop stop markers (written to `## Open Questions`)

Written by scripts outside the critic convergence protocol.

| Marker | Emitter | Clear path | Survives gc? |
|--------|---------|------------|-------------|
| `[BLOCKED:envelope] {scope}: {sub-kind} — {detail}` | Skills (worker context — envelope itself wrong, per effort.md) | `plan-file.sh unblock` | Yes |
| `[BLOCKED:docs] {scope}: {sub-kind} — {detail}` | Skills (parent context); `run-integration.sh` (integration `docs conflict` category) | `plan-file.sh unblock` then cascade | Yes |
| `[BLOCKED:spec] {scope}: {sub-kind} — {detail}` | Skills (parent context) | `plan-file.sh unblock` | Yes |
| `[BLOCKED:code] {scope}: {sub-kind} — {detail}` | Various scripts | `plan-file.sh unblock` | Yes |
| `[BLOCKED:env] {scope}: {sub-kind} — {detail}` | `preflight.sh`, `run-critic-loop.sh`, scripts | `plan-file.sh unblock` | Yes |
| `[BLOCKED:harness] {scope}: {sub-kind} — {detail}` | `plan-cmd.sh`, `run-critic-loop.sh` | `plan-file.sh unblock` | Yes |
| `[BLOCKED:ceiling] {scope}: {sub-kind} — {detail}` | `plan-loop-helpers.sh _record_loop_state` | `plan-file.sh reset-milestone {agent}` | Yes |
| `[STOP-BLOCKED @ts] phase={p} — {reason}` | `stop-check.sh` | Informational — survives `gc-events` | Yes |

## Integration test markers (written to `## Integration Failures`)

Written by `running-integration-tests`; do not interact with the critic convergence protocol.

| Marker | Emitter | Effect | Clear path |
|--------|---------|--------|------------|
| `[AUTO-CATEGORIZED-INTEGRATION] {test name}: {category}` | running-integration-tests | Failure category inferred; fix skill invoked | Log entry — persists in `## Integration Failures`; not processed by `gc-events` |

## Audit and run markers

Written to `## Critic Verdicts`; not subject to `gc-events`.

| Marker | Section | Emitter | Effect |
|--------|---------|---------|--------|
| `[MILESTONE-BOUNDARY @ts] {scope}:` | `## Critic Verdicts` | `reset-milestone`, `reset-pr-review` | Breaks trailing-PASS streak; prior milestone verdicts do not count toward new streak |

## Inline plan-file markers

| Marker | Emitter | Survives `gc-events`? | Effect |
|--------|---------|----------------------|--------|
| `[UNVERIFIED CLAIM]` | brainstorming skill | Yes | Provisional assumption that was not web-verified; critic-spec will flag it |
| `[AUTO-DECIDED] {skill}/{step}: {decision}` | implementing skill | No | Architectural choice made without asking |
| `[INFO] {message}` | Various skills | Yes | Informational log entry |
| `[IMPLEMENTED: {feat-slug}]` | `plan-file.sh mark-implemented` (Ring B) | Yes | Records a completed feature slug; authoritative state is in `plans/{slug}.state/implemented.json` |
| `[RECURRING] {agent}: {msg}` | `plan-file.sh record-verdict` (consecutive same-category FAIL) | No | Advisory: next Codex fix must address root cause of all {category} findings, not only the latest |

## Sidecar control state

Persistent harness state lives in `plans/{slug}.state/` — written only by harness scripts, never by agent Write/Edit tool calls (blocked by `settings.json` deny rules) or redirect-type Bash writes (blocked by `pretooluse-bash.sh`'s `block_sidecar_writes`). Accepted bypass gap: no-destination Bash commands such as `mkdir` and `touch` are not intercepted — same accepted bypass gap as source and test paths (see `reference/phase-gate-config.md §Phase enforcement rules`). The transient critic lock file (`plans/{slug}.md.critic.lock`) is also harness-exclusive (Write/Edit tool calls blocked by `settings.json` deny rules; redirect-type Bash writes not applicable since it is not inside `.state/`). Same accepted bypass gap applies: no-destination Bash commands such as `touch` are not intercepted.

### Key sidecar files

| File | Format | Written by | Read by | Lifecycle |
|------|--------|------------|---------|-----------|
| `convergence/{phase}__{agent}.json` | JSON | `_record_loop_state` (via `record-verdict-direct` in `run-critic-loop.sh` for critic-spec/test/code/cross/quality; via SubagentStop hook for critic-feature) | `is-converged` (`run-dev-cycle.sh`, `run-critic-loop.sh`) | Created on first verdict or first `reset-milestone`/`reset-pr-review`/`clear-converged` call; `reset-milestone`/`reset-pr-review` also increment `milestone_seq`; `converged=true` requires ≥2 consecutive PASSes |
| `verdicts.jsonl` | JSONL (append-only) | `_record_loop_state` | `_record_loop_state` (streak input) | Appended per verdict; no automatic GC |
| `blocked.jsonl` | JSONL (append-only) | `_record_loop_state` (ceiling), `cmd_record_verdict` (parse), `cmd_append_note` (BLOCKED mirror), `_record_transient` (transient) | `is-blocked` (`stop-check.sh`, `run-critic-loop.sh`, `run-dev-cycle.sh`) | `cleared_at:null` = open; non-transient kinds cleared by `unblock`; kind enum: `envelope\|docs\|spec\|code\|env\|harness\|ceiling\|transient` (transient `cleared_at` is set by `_record_transient` at threshold promotion, not by `unblock` or `_clear_transient_for` — see §Transient auto-handling) |
| `implemented.json` | JSON | `mark-implemented` | `is-implemented` (`run-dev-cycle.sh`) | Feature slugs accumulate; never cleared |
| `transient_counters.json` | JSON | `_record_transient` in `sidecar.sh` | `_record_transient`, `_clear_transient_for`, `_reset_all_transient_counters` | Counter per `{agent}__{sub-kind}` key; cleared on any completed session; reset-milestone clears target agent only; reset-for-rollback clears all |

### Block-state queries (Ring A — agent-callable)

```bash
# Returns 0 if any uncleared block record exists; 1 if none
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" is-blocked "$CLAUDE_PROJECT_DIR/plans/{slug}.md"

# Filter by kind
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" is-blocked "$CLAUDE_PROJECT_DIR/plans/{slug}.md" spec
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" is-blocked "$CLAUDE_PROJECT_DIR/plans/{slug}.md" ceiling
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" is-blocked "$CLAUDE_PROJECT_DIR/plans/{slug}.md" env

# Returns 0 if sidecar convergence file says converged=true; 1 otherwise
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" is-converged "$CLAUDE_PROJECT_DIR/plans/{slug}.md" implement critic-code
```

`is-blocked` reads `blocked.jsonl` as its primary source. If `blocked.jsonl` is absent (no blocks ever written), corrupt (parse error), or reports 0 active records, `is-blocked` applies the divergence safety check: if `## Open Questions` in the plan file still contains active `[BLOCKED:*]` lines, `is-blocked` treats the state as blocked and logs a DIVERGENCE warning; otherwise returns "not blocked". `is-converged` reads `convergence/{phase}__{agent}.json` as its primary source and returns "not converged" if the file is absent. When the sidecar reports `converged=true`, two additional guards run: (1) **plan.md divergence guard** — if the last `{phase}/{agent}` verdict in `## Critic Verdicts` is FAIL, treats as not-converged; (2) **spec-fingerprint guard** — if the spec set has changed since convergence was recorded (or the sidecar lacks a `spec_fingerprint` field), treats as not-converged (fail-safe; populates on next verdict).

## HTML verdict envelopes
Format and rules: `@reference/critics.md §Verdict format` (single source of truth).

## Coder status signals

The coder agent emits a plain-text signal (not an HTML comment) to its output log:
- `coder-status: complete` — task finished successfully
- `coder-status: abort` — task could not be completed

Detected by `implement-helpers.sh` (`verify_task`) via `grep 'coder-status:' "$log" | tail -1`.

## Audit outcome words
Written by parent-context ultrathink audit to `## Verdict Audits` via `plan-file.sh append-audit`. Full protocol and outcome table: `@reference/ultrathink.md §Audit outcomes`.
Category enum values and priority: `@reference/severity.md §Category priority`

## Phase-scoped convergence markers

Cleared agent-wide by `plan-file.sh reset-milestone {agent}` (invokes `cmd_reset_milestone` in `scripts/lib/plan-cmd.sh`, which calls `cmd_clear_marker` + `_clear_all_ceiling_sidecar_entries_for_agent`): `[BLOCKED:ceiling]`. Both clears are agent-wide (all scopes for the agent) — symmetric with the plan.md marker clear. All markers require `{phase}` to equal the current plan phase — stale markers from prior phases do not satisfy a check.

| Phase | Agent | Invocation site |
|-------|-------|-----------------|
| `brainstorm` | `critic-feature` | `scripts/run-dev-cycle.sh` (feature brainstorm phase) |
| `spec` | `critic-spec` | `scripts/run-dev-cycle.sh` (Phase 1: per-feature spec pre-pass) |
| `spec` | `critic-cross` | `scripts/run-dev-cycle.sh` (Phase 2: cross-feature spec consistency review, once per plan) |
| `red` | `critic-test` | `scripts/run-dev-cycle.sh` (Phase 3: per-feature test/implement loop) |
| `implement` | `critic-code` | `scripts/run-dev-cycle.sh` (Phase 3: per-feature test/implement loop) |
| `review` | `pr-review` | `scripts/run-dev-cycle.sh` (always called with `--phase review`; `reset-pr-review` also clears `implement/pr-review` defensively) |

Markers written under `{phase}/{agent}` use the phase value from the plan file at the time `record-verdict` runs — not the agent's conceptual owner phase. (`critic-code` runs at scope `implement/critic-code` — `cmd_reset_phase_state` clears this scope's ceiling entry; it also defensively clears `review/critic-code` for stale entries that would arise if `critic-code` ever ran while the plan phase was `review`.)
