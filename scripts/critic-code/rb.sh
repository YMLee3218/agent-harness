#!/usr/bin/env bash
# Layer boundary checker for Ruby projects.
# Usage: rb.sh <domain_root> <infra_root> <features_root>

domain="${1:-src/domain}"
infra="${2:-src/infrastructure}"
features="${3:-src/features}"

echo "=== Ruby layer boundary check ==="

echo "--- domain/ must not require infrastructure/ or features/ ---"
grep -rn \
  -e "require.*infrastructure" \
  -e "require_relative.*infrastructure" \
  -e "require.*features" \
  -e "require_relative.*features" \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- domain/ must not call external systems ---"
grep -rn \
  -e "Net::HTTP" \
  -e "Faraday" \
  -e "HTTParty" \
  -e "ActiveRecord" \
  -e "Sequel" \
  -e "Redis" \
  -e "Mongo" \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- infrastructure/ must not require features/ ---"
grep -rn \
  -e "require.*features" \
  -e "require_relative.*features" \
  "$infra/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- features/ large feature domain direct calls ---"
grep -rn \
  -e "require.*domain" \
  -e "require_relative.*domain" \
  "$features/" 2>/dev/null | grep -v "^Binary" || echo "(none — verify manually if large features exist)"
