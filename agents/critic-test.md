---
name: critic-test
description: >
  Reviews failing tests for scenario coverage and correct mocking levels before implementation begins. Run after writing-tests completes, before implementing starts.
  Invoked only by the critic-test skill. Do not auto-trigger.
tools: Read, Glob, Bash
model: sonnet
---

@reference/critic-test-body.md
