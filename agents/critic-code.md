---
name: critic-code
description: >
  Reviews implementation for spec compliance and layer boundary violations after each milestone.
  Covers spec adherence and architecture rules.
  Run after completing a small feature, a domain concept, or a significant chunk of a large feature.
  Invoked by critic-code skill only.
disallowedTools: Write, Edit, NotebookEdit
model: sonnet
maxTurns: 5
color: yellow
---

Preamble: @reference/critics.md
