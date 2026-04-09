---
paths:
  - src/infrastructure/**
---

You are editing an **Infrastructure** layer file.

Rules:
- Never import from `src/features/`
- May import from `src/domain/` (interfaces only — no concrete domain logic)
- Handles technical execution: DB, HTTP, queues, file I/O

Violation = layer boundary error. Stop and report before writing the import.
