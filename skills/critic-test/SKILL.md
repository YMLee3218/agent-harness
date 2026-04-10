---
name: critic-test
description: >
  Review failing tests for scenario coverage and correct mocking levels.
  Trigger: after writing-tests completes, before implementing starts.
user-invocable: false
context: fork
agent: critic-test
allowed-tools: [Read, Glob, Bash]
effort: high
paths: ["src/**", "tests/**", "docs/**", "plans/**"]
---

@reference/critic-test-body.md
