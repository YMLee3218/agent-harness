#!/usr/bin/env bash
# Layer boundary checker for Java projects.
# Usage: java.sh <domain_root> <infra_root> <features_root>

domain="${1:-src/domain}"
infra="${2:-src/infrastructure}"
features="${3:-src/features}"

echo "=== Java layer boundary check ==="

echo "--- domain/ must not import infrastructure/ or features/ ---"
grep -rn \
  -e "^import.*\.infrastructure\." \
  -e "^import.*\.features\." \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- domain/ must not call external systems ---"
grep -rn \
  -e "import java\.net\." \
  -e "import java\.sql\." \
  -e "import javax\.sql\." \
  -e "import org\.springframework\.web\." \
  -e "import org\.springframework\.data\." \
  -e "import jakarta\.persistence\." \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- infrastructure/ must not import features/ ---"
grep -rn \
  -e "^import.*\.features\." \
  "$infra/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- features/ large feature domain direct calls ---"
grep -rn \
  -e "^import.*\.domain\." \
  "$features/" 2>/dev/null | grep -v "^Binary" || echo "(none — verify manually if large features exist)"
