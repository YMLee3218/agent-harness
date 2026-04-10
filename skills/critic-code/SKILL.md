---
name: critic-code
description: >
  Review implementation for spec compliance and layer boundary violations after each milestone.
  Trigger: "critic", "architecture review", "check the implementation", after completing a small feature,
  a domain concept, or a significant chunk. Covers spec adherence and architecture rules.
user-invocable: false
context: fork
agent: critic-code
allowed-tools: [Read, Grep, Glob, Bash]
effort: high
paths: ["src/**", "tests/**", "docs/**", "plans/**"]
---

@reference/critic-code-body.md
