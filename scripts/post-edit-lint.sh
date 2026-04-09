#!/usr/bin/env bash
# PostToolUse hook — runs project linter on the edited file (advisory, never blocks).
#
# Dispatches by file extension to the project's linter via mise tasks when available,
# then falls back to well-known CLI tools. Silent skip if no linter is installed.
#
# NOTE: This is NOT a security boundary. It is a convenience gate for fast feedback.
#       Exit is always 0 — lint findings go to stderr for visibility only.
#
# Called after Write|Edit tool use. Reads the tool payload from stdin.

set -euo pipefail

input=$(cat)

file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
[ -z "$file_path" ] && exit 0
[ -f "$file_path" ] || exit 0

ext="${file_path##*.}"

# Emit lint output with a prefix so it's identifiable in the hook stream.
_lint_output() { sed 's/^/[post-edit-lint] /' >&2 || true; }

case "$ext" in
  ts|tsx|mts|cts|js|jsx|mjs|cjs)
    if command -v mise >/dev/null 2>&1 && mise task list 2>/dev/null | grep -q "^lint"; then
      mise run lint -- "$file_path" 2>&1 | _lint_output || true
    elif command -v eslint >/dev/null 2>&1; then
      eslint "$file_path" 2>&1 | _lint_output || true
    fi
    ;;
  py)
    if command -v mise >/dev/null 2>&1 && mise task list 2>/dev/null | grep -q "^lint"; then
      mise run lint -- "$file_path" 2>&1 | _lint_output || true
    elif command -v ruff >/dev/null 2>&1; then
      ruff check "$file_path" 2>&1 | _lint_output || true
    elif command -v flake8 >/dev/null 2>&1; then
      flake8 "$file_path" 2>&1 | _lint_output || true
    fi
    ;;
  go)
    if command -v gofmt >/dev/null 2>&1; then
      diff <(gofmt "$file_path") "$file_path" 2>/dev/null | _lint_output || true
    fi
    if command -v go >/dev/null 2>&1; then
      go vet "$(dirname "$file_path")/..." 2>&1 | _lint_output || true
    fi
    ;;
  rs)
    if command -v rustfmt >/dev/null 2>&1; then
      rustfmt --check "$file_path" 2>&1 | _lint_output || true
    fi
    ;;
  kt|kts)
    if command -v ktlint >/dev/null 2>&1; then
      ktlint "$file_path" 2>&1 | _lint_output || true
    fi
    ;;
  rb)
    if command -v rubocop >/dev/null 2>&1; then
      rubocop --no-color --format simple "$file_path" 2>&1 | _lint_output || true
    fi
    ;;
  java)
    if command -v mise >/dev/null 2>&1 && mise task list 2>/dev/null | grep -q "^lint"; then
      mise run lint -- "$file_path" 2>&1 | _lint_output || true
    fi
    ;;
  cs)
    if command -v mise >/dev/null 2>&1 && mise task list 2>/dev/null | grep -q "^lint"; then
      mise run lint -- "$file_path" 2>&1 | _lint_output || true
    fi
    ;;
  sh|bash)
    if command -v shellcheck >/dev/null 2>&1; then
      shellcheck "$file_path" 2>&1 | _lint_output || true
    fi
    ;;
esac

exit 0
