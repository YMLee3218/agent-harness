---
name: critic-code
description: >
  Reviews implementation for spec compliance and layer boundary violations after each milestone. Covers what pr-review-toolkit does not: spec adherence and architecture rules. Run after completing a small feature, a domain concept, or a significant chunk of a large feature. Also trigger on "critic", "architecture review", or "check the implementation".
  Invoked only by the critic-code skill. Do not auto-trigger.
tools: Read, Grep, Glob, Bash
disallowedTools: Write, Edit, NotebookEdit
model: sonnet
maxTurns: 5
effort: high
color: yellow
---

@reference/critic-code-body.md
