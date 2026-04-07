#!/usr/bin/env bash
# Shim for claude-remote-approver — resolves node via mise at runtime,
# independent of the installed node version number.
exec mise x node@lts -- bash -c \
  'exec node "$(npm root -g)/claude-remote-approver/bin/cli.mjs" hook "$@"' _ "$@"
