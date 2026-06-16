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

# Load KEY_FILES from the single-source manifest (deployed alongside this hook).
MANIFEST="$REPO_ROOT/.claude-harness/scripts/lib/harness-key-files.txt"
if [ -f "$MANIFEST" ]; then
  mapfile -t KEY_FILES < "$MANIFEST"
else
  KEY_FILES=(
    scripts/phase-gate.sh
    scripts/lib/validate-history-line.sh
    scripts/lib/sandbox-lib.sh
    settings.json
  )
fi

# Check only staged files inside .claude-harness/ that match a KEY_FILE.
staged=$(git diff --cached --name-only -- ".claude-harness/" 2>/dev/null || true)
[ -z "$staged" ] && exit 0

exit_code=0
for f in "${KEY_FILES[@]}"; do
  # Skip KEY_FILEs not in this commit's staged set.
  printf '%s\n' "$staged" | grep -qF ".claude-harness/$f" || continue

  # If the file doesn't exist in main yet, it's a net-new addition — allow it.
  git cat-file -e "main:.claude-harness/$f" 2>/dev/null || continue

  # Compare staged index blob against main blob.
  if ! cmp -s \
    <(git show "main:.claude-harness/$f" 2>/dev/null) \
    <(git show ":0:.claude-harness/$f" 2>/dev/null); then
    echo "BLOCKED [harness-copy-mirror]: $f modified directly on branch '$current_branch'" >&2
    echo "  Apply changes to ~/harness-builder/workspace/ then run sync-harness.sh on main." >&2
    exit_code=2
  fi
done

exit "$exit_code"
