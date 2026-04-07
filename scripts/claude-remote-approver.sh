#!/usr/bin/env bash
# Shim for claude-remote-approver — resolves node via mise at runtime,
# independent of the installed node version number.
exec mise x node@lts -- node "$(mise where node)/lib/node_modules/claude-remote-approver/bin/cli.mjs" hook "$@"
