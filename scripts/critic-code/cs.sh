#!/usr/bin/env bash
# Layer boundary checker for C# projects.
# Usage: cs.sh <domain_root> <infra_root> <features_root>

domain="${1:-src/domain}"
infra="${2:-src/infrastructure}"
features="${3:-src/features}"

echo "=== C# layer boundary check ==="

echo "--- domain/ must not use infrastructure/ or features/ namespaces ---"
grep -rn \
  -e "^using.*\.Infrastructure" \
  -e "^using.*\.Features" \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- domain/ must not call external systems ---"
grep -rn \
  -e "^using System\.Net\." \
  -e "^using Microsoft\.EntityFrameworkCore" \
  -e "^using Dapper" \
  -e "^using StackExchange\.Redis" \
  -e "^using RestSharp" \
  -e "^using Refit" \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- infrastructure/ must not use features/ namespaces ---"
grep -rn \
  -e "^using.*\.Features" \
  "$infra/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- features/ large feature domain direct calls ---"
grep -rn \
  -e "^using.*\.Domain" \
  "$features/" 2>/dev/null | grep -v "^Binary" || echo "(none — verify manually if large features exist)"
