#!/usr/bin/env bash
# harness-copy-mirror.sh — byte-equality guard for deployed harness copies.
# Installed as part of the pre-commit hook chain via ~/harness-builder/install.sh.
# Blocks commits if key harness files diverge between the main .claude-harness/
# copy and any active worktree copies.
#
# Run manually:  bash .claude/hooks/harness-copy-mirror.sh
# Installed by:  bash ~/harness-builder/install.sh <PROJECT_ROOT>

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
MAIN_HARNESS="$REPO_ROOT/.claude-harness"

# Core harness files that must be byte-identical across all copies.
KEY_FILES=(
  scripts/phase-gate.sh
  scripts/lib/validate-history-line.sh
  scripts/lib/sandbox-lib.sh
  settings.json
)

exit_code=0
shopt -s nullglob

for wt_harness in "$MAIN_HARNESS/worktrees"/*/.claude-harness; do
  [ -d "$wt_harness" ] || continue
  wt_name=$(basename "$(dirname "$wt_harness")")
  for f in "${KEY_FILES[@]}"; do
    main_f="$MAIN_HARNESS/$f"
    wt_f="$wt_harness/$f"
    [ -f "$main_f" ] || continue
    [ -f "$wt_f" ]   || continue
    if ! cmp -s "$main_f" "$wt_f"; then
      echo "BLOCKED [harness-copy-mirror]: $f diverged between main and worktree/$wt_name" >&2
      echo "  Fix: run sync-harness.sh from ~/harness-builder/ to synchronize copies" >&2
      exit_code=2
    fi
  done
done

exit "$exit_code"
