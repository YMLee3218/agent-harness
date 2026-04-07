# Layer rules

Full VSA + DDD layer definitions and dependency rules: @reference/layers.md

Summary:
- `src/features/` — business flow orchestration (may call domain + infrastructure)
- `src/domain/` — pure business rules (no external dependencies)
- `src/infrastructure/` — technical execution layer (DB, HTTP, file I/O)

Dependency direction: `features → domain`, `features → infrastructure`, `infrastructure → domain (interfaces only)`.
`domain` and `infrastructure` never import from `features`. `domain` never imports from `infrastructure`.

# Commands

<!-- Fill in after running /initializing-project -->
- Test: _(run `/initializing-project` to fill this in)_
- Integration test: _(run `/initializing-project` to fill this in)_

# Phase gate overrides

The phase gate checks src/ and test/ paths based on built-in heuristics. Override per project if your layout differs:

```bash
# In your project's .env or shell profile — colon-separated glob patterns
export PHASE_GATE_SRC_GLOB="src/domain/*:src/features/*:src/infrastructure/*:app/*:internal/*"
export PHASE_GATE_TEST_GLOB="tests/*:*_test.*:*.test.*:*.spec.ts:*.spec.js"
```

Defaults cover Maven (`src/main/kotlin/`, `src/main/java/`), standard JS/Python (`src/{domain,features,infrastructure}/`), monorepos (`packages/*/src/`, `apps/*/src/`), Go (`internal/`, `cmd/`), Rails (`app/`), Rust (`crates/*/src/`), and generic `lib/`. Set these in `initializing-project` step for projects with non-standard layouts.

`PHASE_GATE_STRICT=1` — when set, the phase gate blocks all writes if no active plan file exists (fail-closed mode). **Default in this bundle is `1` (fail-closed).** Override to `0` in downstream projects that need fail-open behaviour.

`CLAUDE_PLAN_FILE=/path/to/plan.md` — pins the active plan file for `plan-file.sh find-active`. Highest priority override — use when multiple features run in parallel on the same branch, or in CI where branch-based lookup is unreliable.

# Prerequisites (global settings)

The following belong in **each developer's `~/.claude/settings.json`**, not in the bundle (`workspace/`).

- **Stop hook** — `afplay /System/Library/Sounds/Glass.aiff` + `~/.claude/hooks/notify-stop.sh`
- **PermissionRequest hook** — `~/.claude/hooks/claude-remote-approver.sh hook`
  - Install: copy `workspace/scripts/claude-remote-approver.sh` to `~/.claude/hooks/claude-remote-approver.sh` and `chmod +x` it.
  - The copy in `workspace/scripts/` is a placeholder; the active version must live in the user dir.
- **model** — personal model preference (e.g. `opusplan`)
- **skipDangerousModePermissionPrompt** — per-machine setting

Example:
```json
{
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "~/.claude/hooks/notify-stop.sh"}]}],
    "PermissionRequest": [{"hooks": [{"type": "command", "command": "~/.claude/hooks/claude-remote-approver.sh hook"}]}]
  },
  "model": "opusplan",
  "skipDangerousModePermissionPrompt": true
}
```

# Plan files

Feature work state is preserved in `plans/{feature-slug}.md`. Phase can be recovered after `/compact`.

Frontmatter (optional fields for multi-plan disambiguation):
```yaml
---
feature: {feature-slug}
phase: brainstorm
session_id: {optional — pin with CLAUDE_PLAN_FILE env for parallel sessions}
---
```

Structure:
```
## Vision
## Scenarios
## Test Manifest
## Phase       (brainstorm | spec | red | green | refactor | integration | done)
## Phase Transitions
## Critic Verdicts
## Open Questions
```

Phase transitions are made via:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" {phase}
```

`find-active` resolution order: `CLAUDE_PLAN_FILE` env → branch-slug match → newest non-done plan (warns to stderr when falling back).

**Parallel features**: when running multiple features concurrently, use a separate git worktree per feature (`git worktree add .worktrees/feature-x feature/x`) or pin `CLAUDE_PLAN_FILE` to avoid the fallback picking the wrong plan.

# Library documentation

Look up library/framework APIs with context7: `/context7-plugin:docs {library-name}`

# Harness tests

```bash
bash workspace/scripts/tests/phase-gate.test.sh
bash workspace/scripts/tests/plan-file.test.sh
bash workspace/scripts/tests/pretooluse-bash.test.sh
# or:
make -C workspace test
```
