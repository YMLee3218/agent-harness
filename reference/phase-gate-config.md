# Phase Gate Configuration

The phase gate checks `src/` and `tests/` paths based on built-in heuristics. Override per project if your layout differs.

## Environment variables

```bash
# Colon-separated glob patterns — set in your project's .env or shell profile
export PHASE_GATE_SRC_GLOB="src/domain/*:src/features/*:src/infrastructure/*:app/*:internal/*"
export PHASE_GATE_TEST_GLOB="tests/*:*_test.*:test_*.*:*.test.*:*.spec.*:*_spec.*"
```

> **Source of truth for default glob patterns**: `scripts/phase-policy.sh`. Setting `PHASE_GATE_SRC_GLOB` or `PHASE_GATE_TEST_GLOB` replaces the built-in detection entirely — include all source/test path patterns relevant to your layout. The example above covers a standard VSA project layout; for other layouts (Go `cmd/*`/`pkg/*`, Rust `crates/*/src/*`, multi-module `packages/*/src/*`, etc.) see the built-in fallback patterns in `scripts/phase-policy.sh`. Override in `initializing-project` for non-standard layouts.

```bash
PHASE_GATE_STRICT=1
```

When set, the phase gate blocks `src/` and test writes if no plan file exists at all (fail-closed); writes to `docs/`, `plans/`, `reference/`, and other non-source paths remain permitted (see §Phase enforcement rules). A done-phase plan applies done-phase policy regardless of this setting. **Default is `1` (fail-closed).** Override to `0` in downstream projects that need fail-open behaviour when no plan file is present.

```bash
CLAUDE_PLAN_FILE=/path/to/plans/feature-slug.md
```

Pins the active plan file for `plan-file.sh find-active`. Highest priority override — use when multiple features run in parallel on the same branch, or in CI where branch-based lookup is unreliable.

```bash
CLAUDE_CRITIC_SESSION_TIMEOUT=3600
```

Per-session timeout (seconds) for each `claude` CLI invocation in `run-critic-loop.sh`. Default: `3600` (1 hour). Raise when a single critic run is expected to exceed 1 hour (e.g., very large codebases). If the timeout fires, `run-critic-loop.sh` records a transient event (sidecar only); after K occurrences (`CLAUDE_TRANSIENT_THRESHOLD`, default 3) it promotes to `[BLOCKED:env] {agent}: session-timeout — recurred {K} times: after {N}s` in `## Open Questions`. Set to `0` to disable the timeout cap — `gtimeout 0` / `timeout 0` is treated as "no timeout" by GNU coreutils. When neither `gtimeout` nor `timeout` is installed, `run-critic-loop.sh` BLOCKs at start with `[BLOCKED:env] {agent}: no-timeout-binary — install GNU coreutils (brew install coreutils) or set CLAUDE_CRITIC_SESSION_TIMEOUT=0 to disable the cap`.

```bash
CLAUDE_CRITIC_LOOP_CEILING=20
```

Maximum critic loop iterations per run (runs 1–N allowed; the (N+1)th triggers `[BLOCKED:ceiling]`). Default: `20`. Must be a numeric integer ≥ 2; invalid values or values below 2 fall back to 20. See `@reference/critics.md` for how PARSE_ERROR verdicts count toward the ceiling.

```bash
CLAUDE_CRITIC_LOOP_MODEL=opus
```

Model for the orchestration session spawned by `run-critic-loop.sh`. Default: `opus`. The orchestration session runs the one-shot iteration logic (skill invocation, `record-verdict`, ultrathink audit per `@reference/critics.md §Critic one-shot iteration`). Critic subagents use their own `model:` field from their agent definition (e.g., `agents/critic-code.md` specifies `sonnet`), so this variable controls only the parent session — not the critic review itself.

```bash
CLAUDE_STOP_CHECK_TIMEOUT=600
```

Per-test-run timeout (seconds) for `scripts/stop-check.sh`. Default: `600` (10 minutes). Raise when test suites are expected to exceed 10 minutes. Set to `0` to disable the timeout cap — `gtimeout 0` / `timeout 0` is treated as "no timeout" by GNU coreutils, and the script's no-binary fallback also runs uncapped when `_timeout=0`. The stop-check hook runs in the `green` and `integration` phases only (non-interactive runs: `CLAUDE_NONINTERACTIVE=1`).

## Phase enforcement rules

Source of truth: `scripts/phase-policy.sh` (`phase_blocks_src`, `phase_blocks_test`, `list_phases`). Update `phase-policy.sh` to change phase predicates — this file does not restate them.

> **Note:** Phase gating applies only to source and test paths (`src/` and language-equivalent directories such as `internal/*`, `cmd/*`, `pkg/*`, `app/*`, `lib/*`, `crates/*/src/*`, `apps/*/src/*` — see `scripts/phase-policy.sh:phase_blocks_src` for the full list). Writes to `docs/`, `plans/`, `reference/`, and other non-source paths are always permitted in every phase. Exception: Ring C files in `reference/` (and other Ring C paths) are blocked by the capability gate in both `phase-gate.sh` and `pretooluse-bash.sh` unless `CLAUDE_PLAN_CAPABILITY=human` — this is a capability restriction, not a phase restriction. Exception: direct edits to `plans/*.md` touching `## Phase` or `phase:` frontmatter are blocked by the Ring B gate in `phase-gate.sh` (Write/Edit tools) unless `CLAUDE_PLAN_CAPABILITY=human` or `harness` — use `plan-file.sh transition` or `set-phase` instead. Exception: `phase-gate.sh` `_guard_human_must_clear` blocks **all** writes (including non-source paths) when any human-must-clear marker (`[BLOCKED:{kind}]`) is present in the active plan — this is a marker-state restriction, not a phase restriction; clear the marker from a human terminal before writing. Note: `pretooluse-bash.sh` applies a stricter restriction — it blocks **all** agent Bash writes to `plans/*.md` (not just phase/frontmatter writes), reserving all plan file mutations for `plan-file.sh` harness commands.

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
