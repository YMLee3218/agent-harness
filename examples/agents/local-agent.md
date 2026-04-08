---
name: local-agent
description: >
  One-sentence description — used by Claude to decide when to spawn this subagent.
  Be specific about the domain and the task type this agent handles.
---

<!--
INSTRUCTIONS FOR USE:
1. Copy this file to .claude/agents/local-<your-name>.md
2. Edit the frontmatter (name, description)
3. Replace the body below with the agent's system prompt

FRONTMATTER FIELDS:
  name        — identifier used when spawning via Agent tool
  description — shown in agent list; used for automatic selection

BODY:
  The body is the system prompt given to the subagent at launch.
  Write it as instructions directed at the agent, not at the user.
-->

You are a specialized agent for [domain/task].

## Responsibilities

- Responsibility one
- Responsibility two

## Tools available

List the tools this agent should use and any constraints.

## Output format

Describe the expected output structure (e.g. JSON, markdown, pass/fail verdict).
