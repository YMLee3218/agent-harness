---
name: local-skill
description: >
  One-sentence description — used by Claude to decide when to invoke this skill.
  Be specific: mention the trigger condition and what the skill does.
disable-model-invocation: true
---

<!--
INSTRUCTIONS FOR USE:
1. Copy this directory to .claude/skills/local-<your-name>/
2. Rename: mv local-skill local-<your-name>
3. Edit the frontmatter (name, description)
4. Replace the body below with your skill prompt

INVOCATION:
  disable-model-invocation: true  — user must invoke via /skill-name (default; safest)
  omit or set to false            — Claude decides when to invoke based on description match

FRONTMATTER FIELDS:
  name                       — must match the directory name (used in /skill-name invocation)
  description                — shown in skill list and used for auto trigger matching
  disable-model-invocation   — true = manual only (recommended default)
-->

# Skill: local-skill

Describe what this skill does, step by step.

## Steps

1. Step one
2. Step two
3. Step three

## Output

Describe what the skill produces or changes.
