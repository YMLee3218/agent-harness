#!/usr/bin/env bash
# Layer boundary checker for Java projects.
# Usage: java.sh <domain_root> <infra_root> <features_root>

domain="${1:-src/domain}"
infra="${2:-src/infrastructure}"
features="${3:-src/features}"

EXCLUDES="--exclude-dir=target --exclude-dir=build --exclude-dir=.gradle"

echo "=== Java layer boundary check ==="

echo "--- domain/ must not import infrastructure/ or features/ ---"
# Allow optional leading whitespace (some formatters indent imports)
grep -rn $EXCLUDES \
  -e "^[[:space:]]*import[[:space:]].*\.infrastructure\." \
  -e "^[[:space:]]*import[[:space:]].*\.features\." \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- domain/ must not call external systems ---"
grep -rn $EXCLUDES \
  -e "^[[:space:]]*import[[:space:]]*java\.net\." \
  -e "^[[:space:]]*import[[:space:]]*java\.sql\." \
  -e "^[[:space:]]*import[[:space:]]*javax\.sql\." \
  -e "^[[:space:]]*import[[:space:]]*jakarta\.persistence\." \
  -e "^[[:space:]]*import[[:space:]]*org\.springframework\.web\." \
  -e "^[[:space:]]*import[[:space:]]*org\.springframework\.data\." \
  -e "^[[:space:]]*import[[:space:]]*org\.springframework\.jdbc\." \
  -e "^[[:space:]]*import[[:space:]]*io\.r2dbc\." \
  -e "^[[:space:]]*import[[:space:]]*com\.mongodb\." \
  -e "^[[:space:]]*import[[:space:]]*redis\.clients\." \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- infrastructure/ must not import features/ ---"
grep -rn $EXCLUDES \
  -e "^[[:space:]]*import[[:space:]].*\.features\." \
  "$infra/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- features/ large feature domain direct calls ---"
grep -rn $EXCLUDES \
  -e "^[[:space:]]*import[[:space:]].*\.domain\." \
  "$features/" 2>/dev/null | grep -v "^Binary" || echo "(none — verify manually if large features exist)"
