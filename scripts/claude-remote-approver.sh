#!/usr/bin/env bash
# PLACEHOLDER — this file is not active in the bundle.
# The active version belongs in ~/.claude/hooks/claude-remote-approver.sh on each developer's machine.
# See workspace/CLAUDE.md "Prerequisites (global settings)" for the install instructions.
#
# This shim resolves node via mise at runtime, independent of the installed node version number.
exec mise x node@lts -- bash -c \
  'exec node "$(npm root -g)/claude-remote-approver/bin/cli.mjs" hook "$@"' _ "$@"
