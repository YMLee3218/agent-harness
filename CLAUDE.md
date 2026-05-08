# Language

@reference/language.md
@reference/anti-hallucination.md
@reference/effort.md

@local.md

# Layer rules

@reference/layers.md

# Commands

<!-- TEMPLATE: initializing-project overwrites this section -->
<!-- Fill in after running /initializing-project -->
- Test: _(run `/initializing-project` to fill this in)_
- Integration test: _(run `/initializing-project` to fill this in)_

# Operations

Never append `&` to Bash commands. For long-running scripts, use the `run_in_background=true` Bash tool parameter instead — `&` orphans the process.
Plan files: `plans/{slug}.md`; commands: `scripts/plan-file.sh`; markers: `@reference/markers.md`.
Phase enforcement and env vars: `@reference/phase-gate-config.md`.
Autonomous run: `CLAUDE_NONINTERACTIVE=1 CLAUDE_PLAN_FILE="$(pwd)/plans/{slug}.md" claude --permission-mode auto -p "/running-dev-cycle"`.
Pre-flight: `scripts/preflight.sh` (missing items write `[BLOCKED] preflight:` and halt the run).
Dev cycle: invoke `run-dev-cycle.sh` via `/running-dev-cycle` and `run-integration.sh` via `/running-integration-tests` — both SKILL.md wrappers use `run_in_background=true` (scripts may run for hours). After launching, end the turn immediately — the completion notification drives the next turn. Read `## Open Questions` for markers and proceed per exit code. Do not call `run-critic-loop.sh` directly in the normal dev cycle — it is invoked internally by these scripts. Exception: recovery cascades (e.g. `@reference/phase-ops.md §DOCS CONTRADICTION cascade`) use direct `--nested` invocations.

# Local overrides

Project vocabulary + framework notes: create `.claude/local.md` (imported via `@local.md` above). See `examples/local.md` for the template. Shared domain rules belong in `reference/`.

User-local settings delta (additional MCP servers, personal permissions, env vars): `.claude/settings.local.json`. Arrays merge with `.claude/settings.json` per Claude Code rules — do not duplicate entries already in `settings.json`.
