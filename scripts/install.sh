#!/usr/bin/env bash
# install.sh — bootstrap the agent bundle into a downstream project
#
# Usage:
#   bash .claude/scripts/install.sh [bundle-remote]
#
# When called without arguments, prints usage and the subtree commands
# to run manually. When BUNDLE_REMOTE is set (or passed as first arg),
# runs `git subtree add` automatically.
#
# Run from the downstream project root.

set -euo pipefail

BUNDLE_REMOTE="${1:-${BUNDLE_REMOTE:-}}"
PREFIX=".claude"

usage() {
  cat <<EOF
Usage: bash .claude/scripts/install.sh <bundle-remote-url>

  bundle-remote-url   git remote URL of the agent bundle repo
                      e.g. git@github.com:<user>/agent-bundle.git

Environment variables:
  BUNDLE_REMOTE       Alternative to passing the URL as an argument

Subtree commands (run manually if preferred):

  # Initial install:
  git subtree add --prefix=$PREFIX <bundle-remote> main --squash

  # Update to latest bundle:
  git subtree pull --prefix=$PREFIX <bundle-remote> main --squash

  # Push bundle fixes upstream:
  git subtree push --prefix=$PREFIX <bundle-remote> main

EOF
}

scaffold_local_md() {
  local target="$PREFIX/local.md"
  if [[ -f "$target" ]]; then
    echo "  $target already exists — skipping"
    return
  fi
  cp "$PREFIX/examples/local.md" "$target"
  echo "  created $target — fill in project details and commit"
}

if [[ -z "$BUNDLE_REMOTE" ]]; then
  usage
  exit 0
fi

if [[ ! -d "$PREFIX" ]]; then
  echo "==> Installing bundle from $BUNDLE_REMOTE"
  git subtree add --prefix="$PREFIX" "$BUNDLE_REMOTE" main --squash
  echo "==> Bundle installed at $PREFIX/"
else
  echo "==> $PREFIX/ already exists — running subtree pull"
  git subtree pull --prefix="$PREFIX" "$BUNDLE_REMOTE" main --squash
  echo "==> Bundle updated"
fi

echo "==> Scaffolding local.md"
scaffold_local_md

echo ""
echo "Done. Next steps:"
echo "  1. Edit $PREFIX/local.md with project-specific context"
echo "  2. git add $PREFIX/local.md && git commit -m 'chore: add local overlay'"
echo "  3. Copy templates from $PREFIX/examples/ for local skills/agents"
echo "     See $PREFIX/reference/local-overlay.md for details"
