#!/usr/bin/env bash
# Layer boundary checker for TypeScript/JavaScript projects.
# Usage: ts.sh <domain_root> <infra_root> <features_root>

domain="${1:-src/domain}"
infra="${2:-src/infrastructure}"
features="${3:-src/features}"

echo "=== TypeScript/JavaScript layer boundary check ==="

echo "--- domain/ must not import infrastructure/ or features/ ---"
grep -rn \
  -e "from.*['\"].*infrastructure" \
  -e "require.*infrastructure" \
  -e "from.*['\"].*features" \
  -e "require.*features" \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- domain/ must not call external systems ---"
grep -rn \
  -e "fetch(" \
  -e "axios" \
  -e "prisma" \
  -e "mongoose" \
  -e "pg\." \
  -e "redis" \
  -e "http\." \
  -e "https\." \
  -e "knex" \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- infrastructure/ must not import features/ ---"
grep -rn \
  -e "from.*['\"].*features" \
  -e "require.*features" \
  "$infra/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- features/ large feature domain direct calls ---"
grep -rn \
  -e "from.*['\"].*domain" \
  -e "require.*domain" \
  "$features/" 2>/dev/null | grep -v "^Binary" || echo "(none — verify manually if large features exist)"
