# Phase Gate Configuration

The phase gate checks `src/` and `tests/` paths based on built-in heuristics. Override per project if your layout differs.

## Environment variables

```bash
# Colon-separated glob patterns — set in your project's .env or shell profile
export PHASE_GATE_SRC_GLOB="src/domain/*:src/features/*:src/infrastructure/*:app/*:internal/*"
export PHASE_GATE_TEST_GLOB="tests/*:*_test.*:test_*.*:*.test.*:*.spec.*:*_spec.*"
```

> **Source of truth for default glob patterns**: `scripts/phase-policy.sh`. Setting `PHASE_GATE_SRC_GLOB` or `PHASE_GATE_TEST_GLOB` replaces the built-in glob patterns — include all source/test path patterns relevant to your layout. The example above covers a standard VSA project layout; for other layouts (Go `cmd/*`/`pkg/*`, Rust `crates/*/src/*`, multi-module `packages/*/src/*`, etc.) see the built-in fallback patterns in `scripts/phase-policy.sh`. Override in `initializing-project` for non-standard layouts. **Note**: `*.spec.md` files are always excluded from test detection regardless of `PHASE_GATE_TEST_GLOB` — they are harness-owned spec documents. This exclusion is a non-overridable guard in `scripts/phase-policy.sh` that runs before the glob patterns are evaluated. The `*.spec.*` pattern in the example above matches non-markdown test files (e.g. `user.spec.ts`) but not `*.spec.md`.

```bash
PHASE_GATE_STRICT=1
```

When set, the phase gate blocks `src/` and test writes if no plan file exists at all (fail-closed); writes to `docs/`, `plans/`, `reference/`, and other non-source paths remain permitted (see §Phase enforcement rules). A done-phase plan applies done-phase policy for Write/Edit operations regardless of this setting (phase-gate.sh uses `resolve_with_latest_fallback` which finds done-phase plans via `find-latest`). For Bash tool writes, the Bash hook has a separate limitation — see the §Phase enforcement rules note on `pretooluse-bash.sh` and `bootstrap_block_if_strict`. **Default is `1` (fail-closed).** Override to `0` in downstream projects that need fail-open behaviour when no plan file is present.

```bash
CLAUDE_PLAN_FILE=/path/to/plans/feature-slug.md
```

Pins the active plan file for `plan-file.sh find-active`. Highest priority override — use when multiple features run in parallel on the same branch, or in CI where branch-based lookup is unreliable.

```bash
CLAUDE_CRITIC_SESSION_TIMEOUT=3600
```

Per-run timeout (seconds) applied to each reviewer subprocess in `run-critic-loop.sh` — wraps both the `codex exec --dangerously-bypass-approvals-and-sandbox` review invocation and any `claude` CLI orchestration sessions. Default: `3600` (1 hour). Raise when a single critic run is expected to exceed 1 hour (e.g., very large codebases). If the timeout fires, `run-critic-loop.sh` records a transient event (sidecar only); after K occurrences (`CLAUDE_TRANSIENT_THRESHOLD`, default 3) it promotes to `[BLOCKED:env] {agent}: session-timeout — recurred {K} times: after {N}s` in `## Open Questions`. Set to `0` to disable the timeout cap — `gtimeout 0` / `timeout 0` is treated as "no timeout" by GNU coreutils. When neither `gtimeout` nor `timeout` is installed, `run-critic-loop.sh` BLOCKs at start with `[BLOCKED:env] {agent}: no-timeout-binary — install GNU coreutils (brew install coreutils) or set CLAUDE_CRITIC_SESSION_TIMEOUT=0 to disable the cap`.

```bash
CLAUDE_CRITIC_LOOP_CEILING=100
```

Maximum critic loop iterations per milestone (ordinals 1–N allowed; the (N+1)th triggers `[BLOCKED:ceiling]`; counter accumulates across harness restarts — resets only on `reset-milestone`). Default: `100`. Must be a numeric integer ≥ 2; invalid values or values below 2 fall back to 100. See `@reference/critics.md` for how PARSE_ERROR verdicts count toward the ceiling.

```bash
CLAUDE_CRITIC_LOOP_MODEL=opus
```

Model for the orchestration session spawned by `run-critic-loop.sh`. Default: `opus`. The orchestration session runs the one-shot iteration logic (skill invocation, `record-verdict`, ultrathink audit per `@reference/critics.md §Critic one-shot iteration`). For `critic-spec/test/code/cross`, reviews are executed via `codex exec --dangerously-bypass-approvals-and-sandbox` (worker.sb provides Tier 1 confinement) — codex manages its own model independently of Claude. For `critic-feature`, the review is a Claude fork that uses `model:` from `agents/critic-feature.md`. In both cases `CRITIC_LOOP_MODEL` controls only the orchestration session and does not affect the critic review itself. For shell-driven critics (`critic-spec/test/code/cross`), the FAIL decision audit is a separate one-shot `claude --model sonnet` invocation (see `run-critic-loop.sh:261`) that uses a dynamically built prompt from `build_decision_prompt` in `scripts/lib/critic-helpers.sh` — it does not consult the agent file's `model:` field. The `model:` field in `agents/critic-{code,spec,test,cross}.md` applies only when those agents are launched directly as Claude skill wrappers, which does not occur in the automated shell-driven loop.

```bash
CLAUDE_STOP_CHECK_TIMEOUT=600
```

Per-test-run timeout (seconds) for `scripts/stop-check.sh`. Default: `600` (10 minutes). Raise when test suites are expected to exceed 10 minutes. Set to `0` to disable the timeout cap — `gtimeout 0` / `timeout 0` is treated as "no timeout" by GNU coreutils; when neither binary is available, the fallback runs uncapped regardless of `_timeout` (no binary to enforce the cap). The stop-check hook runs in the `green` and `integration` phases only (non-interactive runs: `CLAUDE_NONINTERACTIVE=1`).

## Phase enforcement rules

Source of truth: `scripts/phase-policy.sh` (`phase_blocks_src`, `phase_blocks_test`, `list_phases`). Update `phase-policy.sh` to change phase predicates — this file does not restate them.

> **Note:** Phase gating applies only to source and test paths (`src/` and language-equivalent directories such as `internal/*`, `cmd/*`, `pkg/*`, `app/*`, `lib/*`, `crates/*/src/*`, `apps/*/src/*` — see `scripts/phase-policy.sh:is_source_path` for the full list). Writes to `docs/`, `plans/`, `reference/`, and other non-source paths are always permitted in every phase. Exception: Ring C files in `reference/` (and other Ring C paths) are blocked by the capability gate in both `phase-gate.sh` and `pretooluse-bash.sh` unless `CLAUDE_PLAN_CAPABILITY=human` — this is a capability restriction, not a phase restriction. Exception: direct edits to `plans/*.md` touching `## Phase` or `phase:` frontmatter are blocked by the Ring B gate in `phase-gate.sh` (Write/Edit tools) unless `CLAUDE_PLAN_CAPABILITY=human` or `harness` — use `plan-file.sh transition` or `set-phase` instead. (Same no-active-plan gap as pretooluse-bash.sh: when `get_active_phase` finds no active plan, `_guard_no_plan` exits 0 before `_guard_plan_phase_mutation` runs.) Exception: `phase-gate.sh` `_guard_human_must_clear` blocks **all** writes (including non-source paths) when any human-must-clear marker (`[BLOCKED:{kind}]`) is present in the active plan — this is a marker-state restriction, not a phase restriction; clear the marker from a human terminal before writing. Note: `pretooluse-bash.sh` applies a stricter restriction — it blocks **all** agent Bash writes to `plans/*.md` (not just phase/frontmatter writes), reserving all plan file mutations for `plan-file.sh` harness commands. Note: `pretooluse-bash.sh` intercepts Bash tool calls by inspecting shell redirect/output destinations; any Bash command that does not use redirect/tee/cp/mv/sed-i/dd/awk-i syntax — including `git checkout`, `git switch`, `touch`, `mkdir`, and similar — produces no redirect destination and bypasses the hook; these commands can mutate source or test files in the working tree without triggering phase enforcement. Sidecar dirs are protected against redirect-detected writes (by `block_sidecar_writes` earlier in the hook) but not against no-destination commands (e.g., `mkdir`, `touch`) — the same accepted bypass gap that applies to source and test paths. `plans/*.md` are additionally protected by `block_plan_revert` when a human-must-clear marker is active. Note: `pretooluse-bash.sh` uses `resolve_active_plan_and_phase` (no find-latest fallback) rather than `resolve_with_latest_fallback` used by `phase-gate.sh`; when `CLAUDE_PLAN_FILE` is not explicitly set and `find-active` returns no active plan (e.g. the plan is in `done` phase), the Bash hook falls back to `bootstrap_block_if_strict` — meaning HMC marker enforcement and done-phase policy are not applied to Bash-tool writes in this scenario. (If an active plan exists in `plans/`, `find-active` finds it and both hooks behave identically — this gap applies only to the no-active-plan case.) The harness always sets `CLAUDE_PLAN_FILE` before launching agent sessions (see §Hook execution order), so this gap only affects ad-hoc invocations — either without an explicitly pinned plan file, or with `CLAUDE_PLAN_FILE` set to a plan that has already transitioned to `done` phase (because `active-plan.sh` falls through to `find-active` for done-phase plans, and if `find-active` returns nothing, the Bash hook has no plan).

`implement` is the codex execution phase (via run-implement.sh) — source writes are permitted; test files remain frozen. Freeze is enforced by two independent hooks (`phase-gate.sh` and `pretooluse-bash.sh`); both must be adjusted together if fail-open behaviour is needed.

## Hook execution order with `--permission-mode auto`

`PreToolUse` hooks (`phase-gate.sh`, `pretooluse-bash.sh`) run *before* the auto-classifier evaluates a permission request. A phase-gate `FAIL` (exit 2) aborts the tool call even in auto mode — the classifier never sees it. In non-interactive pipelines a phase-gate block therefore terminates the current step rather than prompting.

To avoid spurious aborts, set `CLAUDE_PLAN_FILE` and advance the plan to the correct phase before launching:
```bash
CLAUDE_NONINTERACTIVE=1 \
CLAUDE_PLAN_FILE="$(pwd)/plans/{slug}.md" \
  claude --permission-mode auto -p "/running-dev-cycle"
```

`run-critic-loop.sh` adds `--dangerously-skip-permissions` to each internal `claude` invocation so that critic sessions never block on a permission prompt. `run-dev-cycle.sh` and `run-integration.sh` use the same flag in their `run_llm` helpers for the same reason. This flag is used for all autonomous subagent invocations in the harness — in each context the parent session already owns the plan file lock and phase gate, so permission prompts would only stall the pipeline.
