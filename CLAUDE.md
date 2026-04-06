Respond to the user in Korean.

# Layer definitions:
- `features/` — orchestrates business flows using domain decisions
- `domain/` — business rules and decisions; no external dependencies
- `infrastructure/` — technical execution (DB, HTTP, file I/O)

# Feature classification:
- Small feature: calls one or a few domains directly; single responsibility
- Large feature: composes small features; never calls domain directly

# Allowed dependencies
- `features/` → `domain/`, `features/` → `infrastructure/`, `infrastructure/` → `domain/` (interface only).
- `domain/` and `infrastructure/` never import from `features/`. `domain/` never imports from `infrastructure/`.
