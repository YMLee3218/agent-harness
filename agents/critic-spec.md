---
name: critic-spec
description: >
  Adversarially reviews a spec.md for missing failure scenarios, boundary gaps, and structural errors. Run after spec.md is written.
  Invoked only by the critic-spec skill. Do not auto-trigger.
tools: Read, Glob
model: haiku
---

@reference/critic-spec-body.md
