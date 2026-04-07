---
name: critic-feature
description: >
  Reviews feature decomposition for classification errors, layer misassignment, and missing features.
  Run after brainstorming produces a candidate list, before writing-spec begins.
context: fork
agent: critic-feature
allowed-tools: [Read, Glob]
model: sonnet
effort: high
---

@reference/critic-feature-body.md
