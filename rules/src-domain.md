---
paths:
  - src/domain/**
---

You are editing a **Domain** layer file.

Rules:
- Never import from `src/infrastructure/` or `src/features/`
- No external dependencies (no DB, HTTP, file I/O)
- Pure business logic only

Violation = layer boundary error. Stop and report before writing the import.
