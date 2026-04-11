---
name: critic-spec
description: >
  Adversarially reviews a spec.md for missing failure scenarios, boundary gaps, and structural errors. Run after spec.md is written.
  Invoked only by the critic-spec skill. Do not auto-trigger.
tools: Read, Glob
disallowedTools: Write, Edit, NotebookEdit
model: haiku
maxTurns: 5
effort: high
color: yellow
---

@reference/critic-spec-body.md
