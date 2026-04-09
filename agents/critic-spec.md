---
name: critic-spec
description: >
  Adversarially reviews a spec.md for missing failure scenarios, boundary gaps, and structural errors. Run after spec.md is written.
  Invoked only by the critic-spec skill. Do not auto-trigger.
tools: Read, Glob
model: haiku
maxTurns: 5
effort: high
color: yellow
initialPrompt: "Before reviewing, read the active plan file phase and last 3 critic verdicts so you have current pipeline context."
---

@reference/critic-spec-body.md
