#!/usr/bin/env bash
# Layer boundary checker for Ruby projects.
# Usage: rb.sh <domain_root> <infra_root> <features_root>

domain="${1:-src/domain}"
infra="${2:-src/infrastructure}"
features="${3:-src/features}"

EXCLUDES="--exclude-dir=vendor --exclude-dir=tmp --exclude-dir=log"

echo "=== Ruby layer boundary check ==="

echo "--- domain/ must not require infrastructure/ or features/ ---"
grep -rn $EXCLUDES \
  -e "^require[[:space:]].*infrastructure" \
  -e "^require_relative[[:space:]].*infrastructure" \
  -e "^require[[:space:]].*features" \
  -e "^require_relative[[:space:]].*features" \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- domain/ must not call external systems ---"
grep -rn $EXCLUDES \
  -e "Net::HTTP" \
  -e "Faraday" \
  -e "HTTParty" \
  -e "ActiveRecord" \
  -e "Sequel" \
  -e "Redis" \
  -e "Mongo" \
  -e "Aws::" \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- infrastructure/ must not require features/ ---"
grep -rn $EXCLUDES \
  -e "^require[[:space:]].*features" \
  -e "^require_relative[[:space:]].*features" \
  "$infra/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- features/ large feature domain direct calls ---"
grep -rn $EXCLUDES \
  -e "^require[[:space:]].*domain" \
  -e "^require_relative[[:space:]].*domain" \
  "$features/" 2>/dev/null | grep -v "^Binary" || echo "(none — verify manually if large features exist)"
