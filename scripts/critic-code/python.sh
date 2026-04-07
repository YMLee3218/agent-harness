#!/usr/bin/env bash
# Layer boundary checker for Python projects.
# Usage: python.sh <domain_root> <infra_root> <features_root>
# Prints violations to stdout. Exit 0 always (let critic-code interpret results).

domain="${1:-src/domain}"
infra="${2:-src/infrastructure}"
features="${3:-src/features}"

echo "=== Python layer boundary check ==="

echo "--- domain/ must not import infrastructure/ or features/ ---"
grep -rn \
  -e "from.*infrastructure" \
  -e "import.*infrastructure" \
  -e "from.*features" \
  -e "import.*features" \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- domain/ must not call external systems ---"
grep -rn \
  -e "requests\." \
  -e "httpx" \
  -e "sqlalchemy" \
  -e "psycopg" \
  -e "pymongo" \
  -e "aiohttp" \
  -e "boto3" \
  -e "redis\." \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- infrastructure/ must not import features/ ---"
grep -rn \
  -e "from.*features" \
  -e "import.*features" \
  "$infra/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- features/ (large) must not call domain directly (check for direct domain imports in large feature files) ---"
grep -rn \
  -e "from.*domain" \
  -e "import.*domain" \
  "$features/" 2>/dev/null | grep -v "^Binary" || echo "(none — verify manually if large features exist)"
