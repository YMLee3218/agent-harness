# Language

@reference/language.md
@reference/anti-hallucination.md

@local.md

# Layer rules

@reference/layers.md

# Commands

<!-- TEMPLATE: initializing-project overwrites this section -->
<!-- Fill in after running /initializing-project -->
- Test: _(run `/initializing-project` to fill this in)_
- Integration test: _(run `/initializing-project` to fill this in)_

# Operations

Plan files: `plans/{slug}.md`; commands: `scripts/plan-file.sh`; markers: `@reference/markers.md`.
Phase enforcement and env vars: `@reference/phase-gate-config.md`.
Autonomous run: `CLAUDE_NONINTERACTIVE=1 CLAUDE_PLAN_FILE=plans/{slug}.md claude --permission-mode auto -p "/running-dev-cycle"`.
Pre-flight: `scripts/preflight.sh` (missing items write `[BLOCKED] preflight:` and halt the run).

# Local overrides

Project vocabulary + framework notes: create `.claude/local.md` (imported via `@local.md` above). See `examples/local.md` for the template. `.claude/local.md` is gitignored (machine-local). Shared domain rules belong in `reference/`.

User-local settings delta (additional MCP servers, personal permissions, env vars): `.claude/settings.local.json`. Arrays merge with `.claude/settings.json` per Claude Code rules — do not duplicate entries already in `settings.json`.
