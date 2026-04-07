#!/usr/bin/env bash
# Layer boundary checker for Python projects.
# Usage: python.sh <domain_root> <infra_root> <features_root>
# Prints violations to stdout. Exit 0 always (let critic-code interpret results).
#
# Preferred: uses ruff --select TID (banned imports) if available.
# Fallback:  grep-based heuristics.

domain="${1:-src/domain}"
infra="${2:-src/infrastructure}"
features="${3:-src/features}"

EXCLUDES="--exclude-dir=.venv --exclude-dir=venv --exclude-dir=__pycache__ --exclude-dir=.mypy_cache --exclude-dir=dist --exclude-dir=build"

echo "=== Python layer boundary check ==="

# ── Preferred: ruff TID (banned import paths) ────────────────────────────────
if command -v ruff >/dev/null 2>&1; then
  echo "--- ruff --select TID (banned-api / restricted-import violations) ---"
  ruff check --select TID --output-format json "$domain/" "$infra/" "$features/" 2>/dev/null \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
for d in data:
    print(f\"{d['filename']}:{d['location']['row']} [{d['code']}] {d['message']}\")
" 2>/dev/null || echo "(ruff json parse failed — see grep fallback below)"
  echo ""
fi

# ── Fallback / supplemental: grep heuristics ─────────────────────────────────

echo "--- domain/ must not import infrastructure/ or features/ ---"
grep -rn $EXCLUDES \
  -e "^from[[:space:]].*infrastructure" \
  -e "^import[[:space:]].*infrastructure" \
  -e "^from[[:space:]].*features" \
  -e "^import[[:space:]].*features" \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- domain/ must not call external systems ---"
grep -rn $EXCLUDES \
  -e "^import[[:space:]]*requests" \
  -e "^from[[:space:]]*requests" \
  -e "^import[[:space:]]*httpx" \
  -e "^from[[:space:]]*httpx" \
  -e "^import[[:space:]]*sqlalchemy" \
  -e "^from[[:space:]]*sqlalchemy" \
  -e "^import[[:space:]]*psycopg" \
  -e "^from[[:space:]]*psycopg" \
  -e "^import[[:space:]]*pymongo" \
  -e "^from[[:space:]]*pymongo" \
  -e "^import[[:space:]]*aiohttp" \
  -e "^from[[:space:]]*aiohttp" \
  -e "^import[[:space:]]*boto3" \
  -e "^from[[:space:]]*boto3" \
  -e "^import[[:space:]]*aiobotocore" \
  -e "^from[[:space:]]*aiobotocore" \
  -e "^import[[:space:]]*asyncpg" \
  -e "^from[[:space:]]*asyncpg" \
  -e "^import[[:space:]]*motor" \
  -e "^from[[:space:]]*motor" \
  -e "^import[[:space:]]*databases" \
  -e "^from[[:space:]]*databases" \
  -e "^import[[:space:]]*redis" \
  -e "^from[[:space:]]*redis" \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- infrastructure/ must not import features/ ---"
grep -rn $EXCLUDES \
  -e "^from[[:space:]].*features" \
  -e "^import[[:space:]].*features" \
  "$infra/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- features/ (large) must not call domain directly ---"
grep -rn $EXCLUDES \
  -e "^from[[:space:]].*domain" \
  -e "^import[[:space:]].*domain" \
  "$features/" 2>/dev/null | grep -v "^Binary" || echo "(none — verify manually if large features exist)"
