#!/usr/bin/env bash
set -euo pipefail
BATS=$(command -v bats 2>/dev/null || true)
[[ -z "$BATS" ]] && { echo "ERROR: install bats (brew install bats-core)" >&2; exit 1; }
cd "$(dirname "$0")/.."
# trap-lint enforcement — reject trap body interpolation violations before running tests
bash scripts/dev-tools/lint-traps.sh scripts/ || { echo "BLOCKED: trap-lint failed — fix trap body interpolation violations first" >&2; exit 1; }
exec "$BATS" tests/bats/ tests/integration/
