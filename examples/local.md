<!--
INSTRUCTIONS FOR USE:
1. Copy this file to .claude/local.md
2. Fill in each section; delete sections that don't apply
3. Add .claude/local.md to .gitignore (contains machine-local paths; builder repo only: see INSTALL.md for subtree rationale)

This file is imported at the top of .claude/CLAUDE.md via @local.md.
It provides project-specific context: language version, framework,
domain vocabulary, team conventions, and pointers to external systems.
-->

# Project overview

One-paragraph description of what this project does and who it serves.

# Language and runtime

- Language:
- Version:
- Package manager:
- Framework:

# Shell commands

- Test: `<command>`
- Lint: `<command>`
- Build: `<command>`
- Integration test: `<command>`

# Domain vocabulary

| Term | Definition |
|------|-----------|
|  |  |

# External systems

<!--
Reference pointers used by the harness (e.g. Linear, Grafana, Slack).
Format: - System name: URL or identifier and its purpose
-->

# Phase gate layout overrides

<!--
Uncomment and set if your project layout differs from the defaults in reference/phase-gate-config.md.
export PHASE_GATE_SRC_GLOB="src/*:app/*"
export PHASE_GATE_TEST_GLOB="tests/*:*.test.ts"
-->

# Notes

Additional team conventions, architectural decisions, or constraints.
