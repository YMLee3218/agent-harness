#!/usr/bin/env bash
# PLACEHOLDER — not wired. This file is NOT active and will NOT run automatically.
# To activate: copy to ~/.claude/hooks/claude-remote-approver.sh, chmod +x it, then add a
# PermissionRequest hook entry in ~/.claude/settings.json pointing to that path.
# See workspace/CLAUDE.md "Prerequisites (global settings)" for the full install instructions.
# The copy in workspace/scripts/ is for reference only — the bundle does NOT wire it.
#
# This shim resolves node via mise at runtime, independent of the installed node version number.
exec mise x node@lts -- bash -c \
  'exec node "$(npm root -g)/claude-remote-approver/bin/cli.mjs" hook "$@"' _ "$@"
