# Layer Definitions (VSA + DDD)

This file is the single source of truth for layer rules. CLAUDE.md, skills, and critics reference it via `@reference/layers.md`.

## Layers

| Layer | Path | Purpose | Allowed imports |
|-------|------|---------|-----------------|
| **Features** | `src/features/` | Orchestrates business flows; composes domain decisions and infrastructure calls | `src/domain/`, `src/infrastructure/` |
| **Domain** | `src/domain/` | Business rules and decisions; pure logic only | Nothing — no external dependencies |
| **Infrastructure** | `src/infrastructure/` | Technical execution: DB, HTTP, queues, file I/O | `src/domain/` (interfaces only) |

## Forbidden imports

- `src/domain/` must **never** import from `src/infrastructure/` or `src/features/`
- `src/infrastructure/` must **never** import from `src/features/`
- `src/features/` (large) must **never** call `src/domain/` directly — compose small features instead

## Feature size classification

| Type | Definition | Allowed calls |
|------|-----------|---------------|
| **Small feature** | Single responsibility; calls one or a few domain concepts directly | `src/domain/`, `src/infrastructure/` |
| **Large feature** | Higher-level flow; composes small features | Small features only — never domain directly |

## Naming conventions

- Features: `{verb}-{noun}` kebab-case (e.g., `add-todo`, `send-notification`)
- Domain concepts: `{noun}` singular kebab-case (e.g., `todo`, `user`, `notification`)
- Spec files: `features/{name}/spec.md` (feature specs) and `domain/{concept}/spec.md` (domain specs) — top-level directories, not under `src/`

## Test mocking levels

| Test scope | Mock rule |
|-----------|-----------|
| Domain test | No mocks; no external dependencies |
| Small feature test | Mock domain layer only |
| Large feature test | Mock small features; domain not called directly |
| Integration test (`tests/integration/`) | No mocks; real connections |
