---
name: critic-test
description: >
  Reviews failing tests for scenario coverage and correct mocking levels before implementation begins. Run after writing-tests completes, before implementing starts.
  Invoked only by the critic-test skill. Do not auto-trigger.
tools: Read, Glob, Bash
disallowedTools: Write, Edit, NotebookEdit
model: sonnet
maxTurns: 5
effort: high
color: yellow
---

@reference/critic-test-body.md
