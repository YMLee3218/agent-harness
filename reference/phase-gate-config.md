# Phase Gate Configuration

The phase gate checks `src/` and `tests/` paths based on built-in heuristics. Override per project if your layout differs.

## Environment variables

```bash
# Colon-separated glob patterns — set in your project's .env or shell profile
export PHASE_GATE_SRC_GLOB="src/domain/*:src/features/*:src/infrastructure/*:app/*:internal/*"
export PHASE_GATE_TEST_GLOB="tests/*:*_test.*:test_*.*:*.test.*:*.spec.*:*_spec.*"
```

> **Source of truth for default glob patterns**: `scripts/phase-policy.sh`. If you change the patterns there, update examples in this file to match. Override in `initializing-project` for non-standard layouts.

```bash
PHASE_GATE_STRICT=1
```

When set, the phase gate blocks all writes if no active plan file exists (fail-closed). **Default is `1` (fail-closed).** Override to `0` in downstream projects that need fail-open behaviour.

```bash
CLAUDE_PLAN_FILE=/path/to/plans/feature-slug.md
```

Pins the active plan file for `plan-file.sh find-active`. Highest priority override — use when multiple features run in parallel on the same branch, or in CI where branch-based lookup is unreliable.

```bash
CLAUDE_CRITIC_SESSION_TIMEOUT=3600
```

Per-session timeout (seconds) for each `claude` CLI invocation in `run-critic-loop.sh`. Default: `3600` (1 hour). Raise when a single critic run is expected to exceed 1 hour (e.g., very large codebases). If the timeout fires, `run-critic-loop.sh` exits 1 and appends `[BLOCKED] {agent}: session-timeout after {N}s — increase CLAUDE_CRITIC_SESSION_TIMEOUT or re-run` to `## Open Questions` (where `{N}` is the value of `CLAUDE_CRITIC_SESSION_TIMEOUT`).

```bash
CLAUDE_CRITIC_LOOP_CEILING=5
```

Maximum critic loop iterations per run (runs 1–N allowed; the (N+1)th triggers `[BLOCKED-CEILING]`). Default: `5`. Must be a numeric integer ≥ 2; invalid values or values below 2 fall back to 5. See `@reference/critics.md` for how PARSE_ERROR verdicts count toward the ceiling.

```bash
CLAUDE_CRITIC_LOOP_MODEL=opus
```

Model for the orchestration session spawned by `run-critic-loop.sh`. Default: `opus`. The orchestration session runs the one-shot iteration logic (skill invocation, `record-verdict`, ultrathink audit per `@reference/critics.md §Critic one-shot iteration`). Critic subagents use their own `model:` field from their agent definition (e.g., `agents/critic-code.md` specifies `sonnet`), so this variable controls only the parent session — not the critic review itself.

```bash
CLAUDE_STOP_CHECK_TIMEOUT=600
```

Per-test-run timeout (seconds) for `scripts/stop-check.sh`. Default: `600` (10 minutes). Raise when test suites are expected to exceed 10 minutes. Set to `0` to disable the timeout cap (requires `gtimeout` or `timeout` to be absent, or use `CLAUDE_STOP_CHECK_TIMEOUT=0` when no timeout binary is available). The stop-check hook runs in the `green` and `integration` phases only (non-interactive runs: `CLAUDE_NONINTERACTIVE=1`).

```bash
MAX_CONSECUTIVE_NOOP=2
```

Maximum number of consecutive critic-loop iterations allowed where the plan file is unchanged (i.e., the critic session produced no verdicts). Default: `2`. If the plan file hash is unchanged for this many consecutive iterations, `run-critic-loop.sh` writes `[BLOCKED] {agent}: plan unchanged for {N} consecutive iterations — critic is not writing to plan file; check session logs` to `## Open Questions` and exits 1. This fires when a critic session silently exits without writing to the plan file. Increase only if your critic is expected to produce multiple plan-unchanged iterations (unusual).

## Phase enforcement rules

Source of truth: `scripts/phase-policy.sh` (`phase_blocks_src`, `phase_blocks_test`, `list_phases`). Update `phase-policy.sh` to change phase predicates — this file does not restate them.

> **Note:** Phase gating applies only to `src/` and test paths. Writes to `docs/`, `plans/`, `reference/`, and other non-source paths are always permitted in every phase.

`implement` is the coder subagent execution phase — source writes are permitted; test files remain frozen. Freeze is enforced by two independent hooks (`phase-gate.sh` and `pretooluse-bash.sh`); both must be adjusted together if fail-open behaviour is needed.

## Hook execution order with `--permission-mode auto`

`PreToolUse` hooks (`phase-gate.sh`, `pretooluse-bash.sh`) run *before* the auto-classifier evaluates a permission request. A phase-gate `FAIL` (exit 2) aborts the tool call even in auto mode — the classifier never sees it. In non-interactive pipelines a phase-gate block therefore terminates the current step rather than prompting.

To avoid spurious aborts, set `CLAUDE_PLAN_FILE` and advance the plan to the correct phase before launching:
```bash
CLAUDE_NONINTERACTIVE=1 \
CLAUDE_PLAN_FILE="$(pwd)/plans/{slug}.md" \
  claude --permission-mode auto -p "/running-dev-cycle"
```

`run-critic-loop.sh` adds `--dangerously-skip-permissions` to each internal `claude` invocation so that critic sessions never block on a permission prompt. This flag is appropriate only for autonomous subagent calls inside the critic loop, where the parent session already owns the plan file lock and phase gate.
