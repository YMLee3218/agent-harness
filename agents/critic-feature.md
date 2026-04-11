---
name: critic-feature
description: >
  Reviews feature decomposition for classification errors, layer misassignment, and missing features. Run after brainstorming produces a candidate list, before writing-spec begins.
  Invoked only by the critic-feature skill. Do not auto-trigger.
tools: Read, Glob
disallowedTools: Write, Edit, NotebookEdit
model: haiku
maxTurns: 5
effort: high
color: yellow
---

@reference/critic-feature-body.md
