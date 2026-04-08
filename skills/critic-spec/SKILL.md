---
name: critic-spec
description: >
  Adversarially review spec.md for missing failure scenarios, boundary gaps, and structural errors.
  Trigger: after spec.md is written, before writing-tests begins.
context: fork
agent: critic-spec
allowed-tools: [Read, Glob]
effort: high
paths: ["src/**", "tests/**", "docs/**", "plans/**"]
---

@reference/critic-spec-body.md
