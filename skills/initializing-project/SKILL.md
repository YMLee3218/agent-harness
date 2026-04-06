---
name: initializing-project
description: >
  Sets up the VSA+DDD directory structure and generates a project-level CLAUDE.md. Trigger whenever the user starts a new project, says "set up the project", "initialise", "create the project structure", or provides docs files and wants to begin development. Also trigger when no src/ directory exists yet.
---

# Project Initialisation

## Step 1 — Extract Domain Concepts

Use `EnterPlanMode`, then:
- `Read` all files in `docs/` if present
- `Glob` for any existing source structure

Use `AskUserQuestion` if docs/ is absent:
- "What are the core business concepts in this system?"
- "What actions does the system perform?"
- "What is the tech stack (language, framework, test runner)?"

## Step 2 — Propose Structure

Write the plan to the plan file, then call `ExitPlanMode`:

```
src/
├── features/           ← empty
├── domain/
│   └── {concept}/
│       └── spec.md     ← draft from docs/
└── infrastructure/     ← empty
tests/
└── integration/        ← empty
docs/
└── requirements/       ← append-only
```

List proposed `domain/*/spec.md` drafts in the plan.

## Step 3 — Generate Project CLAUDE.md

After approval, write `CLAUDE.md` at project root:

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
- Lint: `{command}`

## Domain Knowledge
@docs/{filename}.md

## Architecture Decisions
- {decision}
```
