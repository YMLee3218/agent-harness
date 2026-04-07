#!/usr/bin/env bash
# Layer boundary checker for Rust projects.
# Usage: rust.sh <domain_root> <infra_root> <features_root>

domain="${1:-src/domain}"
infra="${2:-src/infrastructure}"
features="${3:-src/features}"

EXCLUDES="--exclude-dir=target"

echo "=== Rust layer boundary check ==="

echo "--- domain/ must not import infrastructure/ or features/ ---"
# Match: bare use, pub use, indented use, and crate:: direct path references
grep -rn $EXCLUDES \
  -e "[[:space:]]*use[[:space:]].*::infrastructure" \
  -e "[[:space:]]*use[[:space:]].*::features" \
  -e "^[[:space:]]*pub[[:space:]]*use[[:space:]].*::infrastructure" \
  -e "^[[:space:]]*pub[[:space:]]*use[[:space:]].*::features" \
  -e "^[[:space:]]*mod[[:space:]]*infrastructure" \
  -e "^[[:space:]]*mod[[:space:]]*features" \
  -e "crate::infrastructure" \
  -e "crate::features" \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- domain/ must not call external systems ---"
grep -rn $EXCLUDES \
  -e "[[:space:]]*use[[:space:]]*reqwest" \
  -e "[[:space:]]*use[[:space:]]*sqlx" \
  -e "[[:space:]]*use[[:space:]]*tokio_postgres" \
  -e "[[:space:]]*use[[:space:]]*mongodb" \
  -e "[[:space:]]*use[[:space:]]*redis::" \
  -e "[[:space:]]*use[[:space:]]*aws_sdk" \
  -e "[[:space:]]*use[[:space:]]*sea_orm" \
  -e "[[:space:]]*use[[:space:]]*diesel" \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- infrastructure/ must not import features/ ---"
grep -rn $EXCLUDES \
  -e "[[:space:]]*use[[:space:]].*::features" \
  -e "^[[:space:]]*pub[[:space:]]*use[[:space:]].*::features" \
  -e "^[[:space:]]*mod[[:space:]]*features" \
  -e "crate::features" \
  "$infra/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- features/ large feature domain direct calls ---"
grep -rn $EXCLUDES \
  -e "[[:space:]]*use[[:space:]].*::domain" \
  -e "^[[:space:]]*pub[[:space:]]*use[[:space:]].*::domain" \
  -e "^[[:space:]]*mod[[:space:]]*domain" \
  -e "crate::domain" \
  "$features/" 2>/dev/null | grep -v "^Binary" || echo "(none — verify manually if large features exist)"
