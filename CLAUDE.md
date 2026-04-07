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

Defaults cover Maven (`src/main/kotlin/`, `src/main/java/`), standard JS/Python (`src/{domain,features,infrastructure}/`), and monorepos (`packages/*/src/`). Set these in `initializing-project` step for the project.

# Prerequisites (global settings)

The following belong in **each developer's `~/.claude/settings.json`**, not in the bundle (`workspace/`).

- **Stop hook** — `afplay /System/Library/Sounds/Glass.aiff` + `~/.claude/hooks/notify-stop.sh`
- **PermissionRequest hook** — `~/.claude/hooks/claude-remote-approver.sh hook`
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

Structure:
```
## Vision
## Scenarios
## Test Manifest
## Phase       (brainstorm | spec | red | green | refactor | integration | done)
## Critic Verdicts
## Open Questions
```

Phase transitions are made via:
```bash
bash "$CLAUDE_PROJECT_DIR/.claude/scripts/plan-file.sh" set-phase "plans/{slug}.md" {phase}
```

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
