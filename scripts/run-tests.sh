#!/usr/bin/env bash
set -euo pipefail
BATS=$(command -v bats 2>/dev/null || true)
[[ -z "$BATS" ]] && { echo "ERROR: install bats (brew install bats-core)" >&2; exit 1; }
cd "$(dirname "$0")/.."
exec "$BATS" tests/bats/ tests/integration/
