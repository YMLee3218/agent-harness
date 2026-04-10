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
initialPrompt: "Before reviewing, read the active plan file phase and last 3 critic verdicts so you have current pipeline context."
---

@reference/critic-feature-body.md
