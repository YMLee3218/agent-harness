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

## Phase enforcement rules

| Phase | src/ writes | test/ writes |
|-------|------------|--------------|
| `brainstorm`, `spec` | Blocked | Blocked |
| `red` | Blocked | Allowed |
| `implement` | Allowed | Blocked (tests frozen) |
| `review` | Allowed | Blocked (tests frozen) |
| `green`, `integration` | Allowed | Blocked (tests frozen) |
| `done` | Blocked | Blocked |

> **Note:** Phase gating applies only to `src/` and test paths. Writes to `docs/`, `plans/`, `reference/`, and other non-source paths are always permitted in every phase.

`implement` is the coder subagent execution phase — source writes are permitted; test files remain frozen so coder worktrees cannot alter test baselines.

> **Note:** The `implement`-phase test-file freeze is enforced by two independent hooks:
> - `phase-gate.sh` blocks Write/Edit tool calls to test paths.
> - `pretooluse-bash.sh` blocks Bash-tool redirects (`>`, `>>`) to test paths.
> Setting `PHASE_GATE_STRICT=0` or overriding only one hook does not disable both — both must be adjusted if fail-open behaviour is needed for `implement`.

## Hook execution order with `--permission-mode auto`

`PreToolUse` hooks (`phase-gate.sh`, `pretooluse-bash.sh`) run *before* the auto-classifier evaluates a permission request. A phase-gate `FAIL` (exit 2) aborts the tool call even in auto mode — the classifier never sees it. In non-interactive pipelines a phase-gate block therefore terminates the current step rather than prompting.

To avoid spurious aborts, set `CLAUDE_PLAN_FILE` and advance the plan to the correct phase before launching:
```bash
CLAUDE_PLAN_FILE="$(pwd)/plans/{slug}.md" \
  claude --permission-mode auto -p "/running-dev-cycle"
```
