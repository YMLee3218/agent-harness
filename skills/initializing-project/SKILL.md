---
name: initializing-project
description: >
  Sets up the VSA+DDD directory structure and generates a project-level CLAUDE.md. Trigger whenever
  the user starts a new project, says "set up the project", "initialise", "create the project structure",
  or provides docs files and wants to begin development. Also trigger when no src/ directory exists yet.
---

# Project Initialisation

Layer rules: @reference/layers.md

## Step 1 — Extract domain concepts

Use `EnterPlanMode`, then:
- `Read` all files in `docs/` if present
- `Glob` for any existing source structure

Use `AskUserQuestion` if docs/ is absent:
- "What are the core business concepts in this system?"
- "What actions does the system perform?"
- "What is the tech stack (language, framework, test runner)?"
- "What are the test and lint commands?"

## Step 2 — Propose structure

Write the plan to the plan file:

```
src/
├── features/
├── domain/
│   └── {concept}/
│       └── spec.md     ← draft from docs/
└── infrastructure/
tests/
└── integration/
docs/
└── requirements/       ← append-only
plans/                  ← plan files live here
```

List proposed `domain/*/spec.md` drafts and initial domain concept names.

Call `ExitPlanMode` to request approval.

## Step 3 — Scaffold directories and generate CLAUDE.md

After approval, create the directory structure:

```bash
mkdir -p src/features src/domain src/infrastructure tests/integration docs/requirements plans
```

For each approved domain concept:
```bash
mkdir -p src/domain/{concept}
```

Write draft `src/domain/{concept}/spec.md` (empty Feature block):
```gherkin
Feature: {concept name}

  # Scenarios to be written by writing-spec skill
```

**Write `docs/{concept}.md` for each domain concept** (this is the SOT that critics use for contradiction checks):

```markdown
# {Concept Name}

## Definition
{One-paragraph description of what this concept is and is not}

## Rules
- {Invariant or business rule}

## Vocabulary
- **{term}**: {definition}
```

If docs/ already contains relevant files, read and preserve them. If docs/ is absent and the user provided no domain documentation, use `AskUserQuestion`:
- "What are the core rules and constraints for {concept}? I'll use this to create docs/{concept}.md."

Write `CLAUDE.md` at project root:

```markdown
# {Project Name}

## Project Context
{One-sentence description}

## Tech Stack
- Runtime: {language + version}
- Framework: {if applicable}
- Database: {if applicable}
- Test runner: {tool}

## Commands
- Dev: `{command}`
- Test: `{command}`
- Integration test: `{command}`
- Lint: `{command}`

## Domain Knowledge
@docs/{filename}.md

## Architecture Decisions
- {decision}
```

Create initial plan file `plans/{project-slug}.md`:

```markdown
---
feature: {project-slug}
phase: brainstorm
---

## Vision
{one-sentence goal}

## Scenarios

## Test Manifest

## Phase
brainstorm

## Phase Transitions
- brainstorm → (initial)

## Critic Verdicts

## Open Questions
```
