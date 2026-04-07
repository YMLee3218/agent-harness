---
name: critic-test
description: >
  Review failing tests for scenario coverage and correct mocking levels.
  Trigger: after writing-tests completes, before implementing starts.
context: fork
agent: critic-test
allowed-tools: [Read, Glob, Bash]
model: sonnet
effort: high
---

@reference/critic-test-body.md
