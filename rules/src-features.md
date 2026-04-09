---
paths:
  - src/features/**
---

You are editing a **Features** layer file.

Rules:
- Small features: may call `src/domain/` and `src/infrastructure/` directly
- Large features: must compose small features only — never call `src/domain/` directly
- Determine feature size: single responsibility = small; higher-level flow = large

Violation = layer boundary error. Stop and report before writing the import.
