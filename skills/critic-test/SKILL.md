---
name: critic-test
description: >
  Reviews failing tests for scenario coverage and correct mocking levels before implementation begins.
  Run after writing-tests completes, before implementing starts.
context: fork
agent: critic-test
allowed-tools: [Read, Glob, Bash]
model: sonnet
effort: high
---

@reference/critic-test-body.md
