#!/usr/bin/env bash
# Layer boundary checker for Rust projects.
# Usage: rust.sh <domain_root> <infra_root> <features_root>

domain="${1:-src/domain}"
infra="${2:-src/infrastructure}"
features="${3:-src/features}"

EXCLUDES="--exclude-dir=target"

echo "=== Rust layer boundary check ==="

echo "--- domain/ must not import infrastructure/ or features/ ---"
grep -rn $EXCLUDES \
  -e "^use[[:space:]].*::infrastructure" \
  -e "^use[[:space:]].*::features" \
  -e "^mod[[:space:]]*infrastructure" \
  -e "^mod[[:space:]]*features" \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- domain/ must not call external systems ---"
grep -rn $EXCLUDES \
  -e "^use[[:space:]]*reqwest" \
  -e "^use[[:space:]]*sqlx" \
  -e "^use[[:space:]]*tokio_postgres" \
  -e "^use[[:space:]]*mongodb" \
  -e "^use[[:space:]]*redis::" \
  -e "^use[[:space:]]*aws_sdk" \
  -e "^use[[:space:]]*sea_orm" \
  -e "^use[[:space:]]*diesel" \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- infrastructure/ must not import features/ ---"
grep -rn $EXCLUDES \
  -e "^use[[:space:]].*::features" \
  -e "^mod[[:space:]]*features" \
  "$infra/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- features/ large feature domain direct calls ---"
grep -rn $EXCLUDES \
  -e "^use[[:space:]].*::domain" \
  -e "^mod[[:space:]]*domain" \
  "$features/" 2>/dev/null | grep -v "^Binary" || echo "(none — verify manually if large features exist)"
