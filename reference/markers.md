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

Clears all 7 human-must kinds (`envelope`, `docs`, `spec`, `code`, `env`, `harness`, `ceiling`) from `## Open Questions` in one pass. It also appends `human-clear` facts to every events scope so `ev-blocked`/`ev-ceiling` recompute as cleared (the authoritative events state), and stamps `cleared_at` on the legacy `blocked.jsonl` records. `[BLOCKED:transient]` is intentionally excluded — it has its own auto lifecycle. Non-stop markers (`[UNVERIFIED CLAIM]`, `[INFO]`, `[AUTO-DECIDED]`, etc.) are left untouched.

After resolving the root cause, run `unblock` then restart the autonomous run. In events mode `unblock` clears `[BLOCKED:ceiling]` too (via a `human-clear(ceiling)` fact) — no separate `reset-milestone` step is required.

> **Ceiling block**: `[BLOCKED:ceiling]` fires when a stage's total attempt count exceeds the ceiling (`ev-ceiling`, a count predicate over the events log — not a stored flag). Because the count is input-hash-agnostic, merely editing the input does **not** clear it (that safety boundary stops a wiggling critic from self-clearing); resuming requires the `human-clear(ceiling)` fact that `unblock` appends.

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
| `[MILESTONE-BOUNDARY @ts] {scope}:` | `## Critic Verdicts` | `reset-milestone` | Render of a `milestone` fact; bounds the streak/ceiling recompute window in `events/` |

## Inline plan-file markers

| Marker | Emitter | Survives `gc-events`? | Effect |
|--------|---------|----------------------|--------|
| `[UNVERIFIED CLAIM]` | brainstorming skill | Yes | Provisional assumption that was not web-verified; critic-spec will flag it |
| `[AUTO-DECIDED] {skill}/{step}: {decision}` | implementing skill | No | Architectural choice made without asking |
| `[INFO] {message}` | Various skills | Yes | Informational log entry |
| `[IMPLEMENTED: {feat-slug}]` | implementing skill (render only) | Yes | Human-readable note; authoritative completion is recomputed by `ev-implemented` from the events log (no `implemented.json`) |
| `[RECURRING] {agent}: {msg}` | `plan-file.sh record-verdict` (consecutive same-category FAIL) | No | Advisory: next Codex fix must address root cause of all {category} findings, not only the latest |

## Sidecar control state

Persistent harness state lives in `plans/{slug}.state/` — written only by harness scripts, never by agent Write/Edit tool calls (blocked by `settings.json` deny rules) or redirect-type Bash writes (blocked by `pretooluse-bash.sh`'s `block_sidecar_writes`). Accepted bypass gap: no-destination Bash commands such as `mkdir` and `touch` are not intercepted — same accepted bypass gap as source and test paths (see `reference/phase-gate-config.md §Phase enforcement rules`). The transient critic lock file (`plans/{slug}.md.critic.lock`) is also harness-exclusive (Write/Edit tool calls blocked by `settings.json` deny rules; redirect-type Bash writes not applicable since it is not inside `.state/`). Same accepted bypass gap applies: no-destination Bash commands such as `touch` are not intercepted.

### Key sidecar files

| File | Format | Written by | Read by | Lifecycle |
|------|--------|------------|---------|-----------|
| `events/{scope}.jsonl` | JSONL (append-only) | `_record_loop_state` + `ev_record_*` (verdict/block/audit-reject/milestone/human-clear facts; via `record-verdict-direct`/`append-note` with `--unit`) | `ev-converged`/`ev-implemented`/`ev-blocked`/`ev-ceiling`/`stage-satisfied` — **pure recompute, never stored** | **Authoritative state.** One file per layer-qualified unit (+ `__brainstorm__`/`__cross__`/`__integration__` singletons). Convergence = streak ≥2 PASS at the current working-tree input hash; a spec/src edit changes the hash and auto-reopens the stage. Truncated past a size threshold by `ev_gc` (keeps last-N per stage + open blocks) |
| `convergence/{phase}__{agent}.json` | JSON | — (legacy; only unit-less critics, e.g. integration recovery) | — (**superseded by `events/`**) | No longer written in events mode; live convergence/ceiling are recomputed from the events log |
| `verdicts.jsonl` | JSONL (append-only) | `_record_loop_state` | legacy consecutive-FAIL / PARSE-error feed-forward only | Still appended; not the convergence source (events is) |
| `blocked.jsonl` | JSONL (append-only) | `cmd_append_note` (BLOCKED mirror), `_record_transient` (transient) | global `is-blocked` (`stop-check.sh`, `run-dev-cycle.sh`) — coarse "any block?" check | `cleared_at:null` = open; non-transient kinds cleared by `unblock`. Per-unit block state lives in `events/`; this remains the global aggregate |
| `implemented.json` | JSON | — (**removed**) | — (superseded; `ev-implemented` recomputes code∧quality convergence) | No longer written; feature completion is a pure function of the events log |
| `transient_counters.json` | JSON | `_record_transient` in `sidecar.sh` | `_record_transient`, `_clear_transient_for` | Counter per `{agent}__{sub-kind}`; cleared on any completed critic session |

### Block-state queries (Ring A — agent-callable)

```bash
# Returns 0 if any uncleared block record exists; 1 if none
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" is-blocked "$CLAUDE_PROJECT_DIR/plans/{slug}.md"

# Filter by kind
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" is-blocked "$CLAUDE_PROJECT_DIR/plans/{slug}.md" spec
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" is-blocked "$CLAUDE_PROJECT_DIR/plans/{slug}.md" ceiling
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" is-blocked "$CLAUDE_PROJECT_DIR/plans/{slug}.md" env

# Recompute convergence/skip from the events log (rc0 = converged/SKIP, rc1 = RUN)
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" ev-converged "$CLAUDE_PROJECT_DIR/plans/{slug}.md" features-add-todo code
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" stage-satisfied "$CLAUDE_PROJECT_DIR/plans/{slug}.md" features-add-todo code
```

`is-blocked` reads `blocked.jsonl` as its global "any block?" source; if it is absent/corrupt/empty, it falls back to a divergence check against active `[BLOCKED:*]` lines in `## Open Questions`. Per-unit block state lives in `events/` (`ev-blocked`). **Convergence is recomputed, not stored**: `ev-converged`/`stage-satisfied` read `events/{scope}.jsonl` and return converged when the streak is ≥2 PASS at the *current* working-tree input hash. A spec/src/test edit changes that hash, so past verdicts no longer match and the stage auto-reopens — this replaces the old stored `converged` flag, the plan.md divergence guard, and the spec-fingerprint guard (all removed). The frozen pass-audit hash and `audit-reject` facts break a streak when an audit overrides a 2nd PASS.

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

## Critic stages and units

Each critic reviews a logical **stage** for a layer-qualified **unit** (or a singleton scope); convergence is tracked per `(unit, stage)` in `events/{scope}.jsonl`. `ev-ceiling` (count > ceiling) replaces the stored ceiling flag; `human-clear`/`milestone` facts and working-tree input changes reopen a stage (there is no `reset-milestone`-driven convergence reset in events mode).

| Stage | Agent | Unit / scope |
|-------|-------|--------------|
| `brainstorm` | `critic-feature` | `__brainstorm__` singleton (plan.md authored sections + docs) |
| `spec` | `critic-spec` | per feature/domain/infra unit (`features-{slug}`, `domain-{slug}`, …) |
| `cross` | `critic-cross` | `__cross__` singleton (all specs) |
| `test` | `critic-test` | per unit (spec + test files) |
| `code` | `critic-code` | per unit (spec + test + src + `Depends-on` closure) |
| `quality` | `critic-quality` | per unit (src) |
| `integration` | runner (not a critic) | `__integration__` singleton; `done` gates on a single PASS at the all-src/test/spec hash |
