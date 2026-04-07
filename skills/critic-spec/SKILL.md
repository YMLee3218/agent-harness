---
name: critic-spec
description: >
  Adversarially reviews a spec.md for missing failure scenarios, boundary gaps, and structural errors.
  Run after spec.md is written.
context: fork
agent: critic-spec
allowed-tools: [Read, Glob]
model: sonnet
effort: high
---

@reference/critic-spec-body.md
