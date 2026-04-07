#!/usr/bin/env bash
# Layer boundary checker for Kotlin projects.
# Usage: kotlin.sh <domain_root> <infra_root> <features_root>

domain="${1:-src/domain}"
infra="${2:-src/infrastructure}"
features="${3:-src/features}"

echo "=== Kotlin layer boundary check ==="

echo "--- domain/ must not import infrastructure/ or features/ ---"
grep -rn \
  -e "^import.*\.infrastructure\." \
  -e "^import.*\.features\." \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- domain/ must not call external systems ---"
grep -rn \
  -e "import io\.ktor\." \
  -e "import org\.jetbrains\.exposed\." \
  -e "import org\.springframework\.data\." \
  -e "import java\.net\." \
  -e "import java\.sql\." \
  -e "import okhttp3\." \
  -e "import retrofit2\." \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- infrastructure/ must not import features/ ---"
grep -rn \
  -e "^import.*\.features\." \
  "$infra/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- features/ large feature domain direct calls ---"
grep -rn \
  -e "^import.*\.domain\." \
  "$features/" 2>/dev/null | grep -v "^Binary" || echo "(none — verify manually if large features exist)"
