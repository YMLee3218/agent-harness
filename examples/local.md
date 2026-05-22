<!--
INSTRUCTIONS FOR USE:
1. Copy this file to .claude/local.md
2. Fill in each section; delete sections that don't apply

This file is imported at the top of .claude/CLAUDE.md via @local.md.
It provides project-specific context: language version, framework,
domain vocabulary, team conventions, and pointers to external systems.
Commit it alongside the rest of the project.
-->

# Project overview

One-paragraph description of what this project does and who it serves.

# Language and runtime

- Language:
- Version:
- Package manager:
- Framework:

# Shell commands

<!--
NOTE: The harness scripts (`run-dev-cycle.sh`, `run-integration.sh`, `stop-check.sh`) read
Test, Lint, and Integration-test commands from the project-root `CLAUDE.md` `# Commands`
section — not from this file. Run `/initializing-project` to fill those in automatically,
or edit project CLAUDE.md directly. These fields below are for project documentation only
and are not read by any harness script at runtime.
-->

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
