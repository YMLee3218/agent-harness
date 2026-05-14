# Layer Definitions (VSA + DDD)

This file is the single source of truth for layer rules. CLAUDE.md, skills, and critics reference it via `@reference/layers.md`.

## Layers

| Layer | Path | Purpose | Allowed imports |
|-------|------|---------|-----------------|
| **Features** | `src/features/` | Orchestrates business flows; composes domain decisions and infrastructure calls | `src/domain/` (small features only — see §Feature size classification), `src/infrastructure/` |
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
| **Large feature** | Higher-level flow; composes features | Small features, and other large features when the composed feature is a self-contained sub-pipeline (not a peer business flow) — never domain directly |

**Large→large sub-pipeline rule**: a large feature may compose another large feature when the composed feature encapsulates a complete, reusable sub-pipeline that is called as a unit across multiple business flows. This is distinct from peer large features that should remain independent. Any large→large dependency must be documented in the calling feature's spec.

## Naming conventions

- Features: `{verb}-{noun}` kebab-case (e.g., `add-todo`, `send-notification`)
- Domain concepts: `{noun}` singular kebab-case (e.g., `todo`, `user`, `notification`)
- Spec files: top-level directories, not under `src/`
- Infrastructure concepts: `{noun}` singular kebab-case (e.g., `noop-deploy`, `postgres-store`)
- Branches: `feature/{feature-name}` where `{feature-name}` matches the feature folder name; created by brainstorming skill (see `skills/brainstorming/SKILL.md`)
- Layer-to-spec-path mapping (canonical for all skills and critics):

  | Layer | Spec path |
  |-------|-----------|
  | Domain | `domain/{concept}/spec.md` |
  | Infrastructure | `infrastructure/{concept}/spec.md` |
  | Feature (small or large) | `features/{verb}-{noun}/spec.md` |

## Acceptable import exceptions

The following patterns produce grep hits in boundary checkers but are **not** violations:

| Pattern | Reason |
|---------|--------|
| `infrastructure/` imports a type, interface, or enum **defined in** `domain/` | Infrastructure depends on domain contracts (allowed) |
| `features/` (small) imports a value object or enum from `domain/` | Small features compose domain — value objects are not logic |
| `features/` (large) imports a value object or enum from `domain/` for a type annotation or enum comparison only | Structural type reference, not a domain logic call; the large-feature "never domain directly" rule applies to domain logic calls, not to type imports |
| Language-generated code (e.g., protobuf, ORM stubs) auto-importing across layers | Generated; not authored violations |

These exceptions apply to both run-implement.sh / codex (layer enforcement) and critic-code (Angle 2 boundary checker). When in doubt, flag as `[WARN]` rather than `[CRITICAL]`.

## Test mocking levels

| Test scope | Mock rule | Violation → `[FAIL]` |
|-----------|-----------|----------------------|
| Domain test | No mocks; no external dependencies | Any mock present |
| Small feature test | Mock domain layer only | Infrastructure mocked directly |
| Large feature test | Mock small features; domain not called directly | Domain called directly |
| Integration test (`tests/integration/`) | No mocks; real connections | Any mock present |
