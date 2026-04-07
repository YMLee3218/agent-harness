---
name: critic-spec
description: >
  Adversarially review spec.md for missing failure scenarios, boundary gaps, and structural errors.
  Trigger: after spec.md is written, before writing-tests begins.
context: fork
agent: critic-spec
allowed-tools: [Read, Glob]
model: sonnet
effort: high
---

@reference/critic-spec-body.md
