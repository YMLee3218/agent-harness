#!/usr/bin/env bash
# Layer boundary checker for TypeScript/JavaScript projects.
# Usage: ts.sh <domain_root> <infra_root> <features_root>

domain="${1:-src/domain}"
infra="${2:-src/infrastructure}"
features="${3:-src/features}"

EXCLUDES="--exclude-dir=node_modules --exclude-dir=dist --exclude-dir=build --exclude-dir=.next --exclude-dir=coverage"

echo "=== TypeScript/JavaScript layer boundary check ==="

echo "--- domain/ must not import infrastructure/ or features/ ---"
grep -rn $EXCLUDES \
  -e "from[[:space:]]*['\"].*infrastructure" \
  -e "require[[:space:]]*(['\"].*infrastructure" \
  -e "from[[:space:]]*['\"].*features" \
  -e "require[[:space:]]*(['\"].*features" \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- domain/ must not call external systems ---"
grep -rn $EXCLUDES \
  -e "fetch(" \
  -e "axios" \
  -e "prisma" \
  -e "mongoose" \
  -e "pg\." \
  -e "redis" \
  -e "http\." \
  -e "https\." \
  -e "knex" \
  -e "drizzle" \
  -e "kysely" \
  -e "typeorm" \
  -e "sequelize" \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- infrastructure/ must not import features/ ---"
grep -rn $EXCLUDES \
  -e "from[[:space:]]*['\"].*features" \
  -e "require[[:space:]]*(['\"].*features" \
  "$infra/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- features/ large feature domain direct calls ---"
grep -rn $EXCLUDES \
  -e "from[[:space:]]*['\"].*domain" \
  -e "require[[:space:]]*(['\"].*domain" \
  "$features/" 2>/dev/null | grep -v "^Binary" || echo "(none — verify manually if large features exist)"
