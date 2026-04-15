# Phase Gate Configuration

The phase gate checks `src/` and `test/` paths based on built-in heuristics. Override per project if your layout differs.

## Environment variables

```bash
# Colon-separated glob patterns — set in your project's .env or shell profile
export PHASE_GATE_SRC_GLOB="src/domain/*:src/features/*:src/infrastructure/*:app/*:internal/*"
export PHASE_GATE_TEST_GLOB="tests/*:*_test.*:*.test.*:*.spec.ts:*.spec.js"
```

**Defaults** cover Maven (`src/main/kotlin/`, `src/main/java/`), standard JS/Python (`src/{domain,features,infrastructure}/`), monorepos (`packages/*/src/`, `apps/*/src/`), Go (`internal/`, `cmd/`), Rails (`app/`), Rust (`crates/*/src/`), and generic `lib/`. Set these in `initializing-project` for projects with non-standard layouts.

```bash
PHASE_GATE_STRICT=1
```

When set, the phase gate blocks all writes if no active plan file exists (fail-closed). **Default is `1` (fail-closed).** Override to `0` in downstream projects that need fail-open behaviour.

```bash
CLAUDE_PLAN_FILE=/path/to/plans/feature-slug.md
```

Pins the active plan file for `plan-file.sh find-active`. Highest priority override — use when multiple features run in parallel on the same branch, or in CI where branch-based lookup is unreliable.

## Hook execution order with `--permission-mode auto`

`PreToolUse` hooks (`phase-gate.sh`, `pretooluse-bash.sh`) run *before* the auto-classifier evaluates a permission request. A phase-gate `FAIL` (exit 2) aborts the tool call even in auto mode — the classifier never sees it. In non-interactive pipelines a phase-gate block therefore terminates the current step rather than prompting.

To avoid spurious aborts, set `CLAUDE_PLAN_FILE` and advance the plan to the correct phase before launching:
```bash
claude --permission-mode auto -p "/running-dev-cycle"
```
