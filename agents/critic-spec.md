---
name: critic-spec
description: >
  Adversarially reviews spec.md for missing failure scenarios, boundary gaps, and structural errors.
  Invoked by critic-spec skill only.
disallowedTools: Write, Edit, NotebookEdit
model: haiku
maxTurns: 5
color: yellow
---

Preamble: @reference/critics.md
