#!/usr/bin/env bash
# harness-copy-mirror.sh — staged-file guard for deployed harness KEY_FILES.
# Blocks commits on non-main branches that directly modify KEY_FILES under .claude-harness/.
# Feature branches must receive harness changes via sync-harness.sh on main, then merge.
#
# Run manually:  bash .claude/hooks/harness-copy-mirror.sh
# Installed by:  bash ~/harness-builder/install.sh <PROJECT_ROOT>

set -euo pipefail

# Skip on main — sync-harness.sh commits the harness there; blocking would self-deadlock.
current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$current_branch" = "main" ] && exit 0

REPO_ROOT=$(git rev-parse --show-toplevel)

# Check staged files first — fast exit for non-harness commits (agent repo, unrelated commits).
staged=$(git diff --cached --name-only -- ".claude-harness/" 2>/dev/null || true)
[ -z "$staged" ] && exit 0

# Load KEY_FILES from manifest (single source of truth — no hardcoded fallback).
MANIFEST="$REPO_ROOT/.claude-harness/scripts/lib/harness-key-files.txt"
if [ ! -s "$MANIFEST" ]; then
  echo "BLOCKED [harness-copy-mirror]: manifest absent or empty: $MANIFEST" >&2
  echo "  Deployment is damaged — run sync-harness.sh to restore." >&2
  exit 2
fi
mapfile -t KEY_FILES < <(grep -vE '^[[:space:]]*(#|$)' "$MANIFEST")
[ "${#KEY_FILES[@]}" -gt 0 ] || { echo "BLOCKED [harness-copy-mirror]: manifest has no usable entries: $MANIFEST" >&2; exit 2; }

# Verify main exists — writer always has it; fail-loud if somehow missing.
if ! git rev-parse --verify main >/dev/null 2>&1; then
  echo "BLOCKED [harness-copy-mirror]: branch 'main' not found — cannot verify harness copy equality." >&2
  exit 2
fi

exit_code=0
for f in "${KEY_FILES[@]}"; do
  # Skip KEY_FILEs not in this commit's staged set (exact-line match prevents .bak partial hits).
  printf '%s\n' "$staged" | grep -qxF ".claude-harness/$f" || continue

  # If the file doesn't exist in main yet, it's a net-new addition — allow it.
  git cat-file -e "main:.claude-harness/$f" 2>/dev/null || continue

  # Compare staged index blob against main blob.
  if ! cmp -s \
    <(git show "main:.claude-harness/$f" 2>/dev/null) \
    <(git show ":0:.claude-harness/$f" 2>/dev/null); then
    echo "BLOCKED [harness-copy-mirror]: $f modified directly on branch '$current_branch'" >&2
    echo "  Apply changes in the harness-builder workspace, then run sync-harness.sh on main." >&2
    exit_code=2
  fi
done

exit "$exit_code"
