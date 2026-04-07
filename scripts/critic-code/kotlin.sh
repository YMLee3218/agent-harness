#!/usr/bin/env bash
# Layer boundary checker for Kotlin projects.
# Usage: kotlin.sh <domain_root> <infra_root> <features_root>

domain="${1:-src/domain}"
infra="${2:-src/infrastructure}"
features="${3:-src/features}"

EXCLUDES="--exclude-dir=target --exclude-dir=build --exclude-dir=.gradle"

echo "=== Kotlin layer boundary check ==="

echo "--- domain/ must not import infrastructure/ or features/ ---"
grep -rn $EXCLUDES \
  -e "^import.*\.infrastructure\." \
  -e "^import.*\.features\." \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- domain/ must not call external systems ---"
grep -rn $EXCLUDES \
  -e "^import io\.ktor\." \
  -e "^import org\.jetbrains\.exposed\." \
  -e "^import org\.springframework\.data\." \
  -e "^import org\.springframework\.web\." \
  -e "^import java\.net\." \
  -e "^import java\.sql\." \
  -e "^import javax\.sql\." \
  -e "^import jakarta\.persistence\." \
  -e "^import okhttp3\." \
  -e "^import retrofit2\." \
  -e "^import io\.r2dbc\." \
  -e "^import com\.mongodb\." \
  -e "^import redis\.clients\." \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- infrastructure/ must not import features/ ---"
grep -rn $EXCLUDES \
  -e "^import.*\.features\." \
  "$infra/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- features/ large feature domain direct calls ---"
grep -rn $EXCLUDES \
  -e "^import.*\.domain\." \
  "$features/" 2>/dev/null | grep -v "^Binary" || echo "(none — verify manually if large features exist)"
