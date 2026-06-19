---
name: critic-quality
description: >
  Placeholder SKILL.md for critic-quality. The actual review is fan-out per angle
  in skills/critic-quality/angles/. run-critic-loop.sh detects angles/ and runs
  each angle file as a separate codex prompt, then aggregates into one verdict.
user-invocable: false
context: fork
agent: critic-quality
allowed-tools: [Bash]
paths: ["src/**", "tests/**", "docs/**", "plans/**"]
---
This file is a placeholder. The runner detects skills/critic-quality/angles/*.md
and builds per-angle prompts from those files using build_review_prompt.
