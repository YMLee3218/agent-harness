#!/usr/bin/env bash
# Layer boundary checker for Go projects.
# Usage: go.sh <domain_root> <infra_root> <features_root>

domain="${1:-src/domain}"
infra="${2:-src/infrastructure}"
features="${3:-src/features}"

EXCLUDES="--exclude-dir=vendor --exclude-dir=testdata"

echo "=== Go layer boundary check ==="

echo "--- domain/ must not import infrastructure/ or features/ ---"
# Match import path strings only: tab-indented quoted paths (Go import block style)
# Avoids false positives from log messages or string literals containing these words
grep -rn $EXCLUDES \
  -e $'^\t"[^"]*infrastructure' \
  -e $'^\t"[^"]*features' \
  -e '^import[[:space:]]*"[^"]*infrastructure' \
  -e '^import[[:space:]]*"[^"]*features' \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- domain/ must not call external systems ---"
grep -rn $EXCLUDES \
  -e '"net/http"' \
  -e '"database/sql"' \
  -e 'gorm\.' \
  -e 'mongo-driver' \
  -e '"github.com/go-redis' \
  -e '"github.com/redis/go-redis' \
  -e '"cloud.google.com' \
  -e '"github.com/aws' \
  -e '"github.com/jackc/pgx' \
  -e '"go.mongodb.org' \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- infrastructure/ must not import features/ ---"
grep -rn $EXCLUDES \
  -e $'^\t"[^"]*features' \
  -e '^import[[:space:]]*"[^"]*features' \
  "$infra/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- features/ large feature domain direct calls ---"
grep -rn $EXCLUDES \
  -e $'^\t"[^"]*domain' \
  -e '^import[[:space:]]*"[^"]*domain' \
  "$features/" 2>/dev/null | grep -v "^Binary" || echo "(none — verify manually if large features exist)"
