#!/usr/bin/env bash
# Hook input utility helpers — stdin-JSON field extraction and jq guard.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_HOOK_UTILS_LOADED:-}" ]] && return 0
_HOOK_UTILS_LOADED=1

# require_jq_or_block <label> [strict=1]
#   strict=1 → exit 2 with "BLOCKED [label]: jq is required but not found"
#   strict=0 → return 1 with advisory message; caller decides
require_jq_or_block() {
  local label="$1" strict="${2:-1}"
  command -v jq >/dev/null 2>&1 && return 0
  if [ "$strict" = "1" ]; then
    echo "BLOCKED [$label]: jq is required but not found" >&2
    exit 2
  fi
  echo "[$label] warning: jq not found" >&2
  return 1
}

# extract_tool_input_field <field> <json> → prints .tool_input[field] (empty if absent)
extract_tool_input_field() {
  printf '%s' "$2" | jq -r --arg f "$1" '.tool_input[$f] // empty' 2>/dev/null
}

# extract_tool_input_path <json>   → prints file_path or notebook_path (empty if absent)
extract_tool_input_path() {
  printf '%s' "$1" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null
}

# extract_tool_input_command <json> → prints .tool_input.command (empty if absent)
extract_tool_input_command() { extract_tool_input_field command "$1"; }
