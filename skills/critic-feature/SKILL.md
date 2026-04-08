---
name: critic-feature
description: >
  Review feature decomposition: classification errors, layer misassignment, naming, missing features.
  Trigger: after brainstorming produces a candidate list, before writing-spec begins.
context: fork
agent: critic-feature
allowed-tools: [Read, Glob]
effort: high
paths: ["src/**", "tests/**", "docs/**", "plans/**"]
---

@reference/critic-feature-body.md
