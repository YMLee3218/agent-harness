#!/usr/bin/env bash
# Layer boundary checker for TypeScript/JavaScript projects.
# Usage: ts.sh <domain_root> <infra_root> <features_root>
#
# Preferred: uses dependency-cruiser (depcruise) if available.
# Fallback:  grep-based heuristics.

domain="${1:-src/domain}"
infra="${2:-src/infrastructure}"
features="${3:-src/features}"

EXCLUDES="--exclude-dir=node_modules --exclude-dir=dist --exclude-dir=build --exclude-dir=.next --exclude-dir=coverage"

echo "=== TypeScript/JavaScript layer boundary check ==="

# ── Preferred: dependency-cruiser JSON output ─────────────────────────────────
if command -v depcruise >/dev/null 2>&1; then
  echo "--- dependency-cruiser violations ---"
  # Run against src/ using project .dependency-cruiser config if present,
  # otherwise use inline forbidden rules for layer boundaries.
  if [ -f ".dependency-cruiser.js" ] || [ -f ".dependency-cruiser.cjs" ] || [ -f ".dependency-cruiser.json" ]; then
    depcruise --output-type json src/ 2>/dev/null \
      | node -e "
const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
const v=(d.modules||[]).flatMap(m=>(m.dependencies||[]).filter(dep=>dep.valid===false).map(dep=>
  \`\${m.source} → \${dep.resolved} [\${(dep.rules||[]).map(r=>r.name).join(',')}]\`));
v.forEach(l=>console.log(l));
if(!v.length)console.log('(none)');
" 2>/dev/null || echo "(depcruise json parse failed — see grep fallback below)"
  else
    echo "(no .dependency-cruiser config found — skipping depcruise, using grep fallback)"
  fi
  echo ""
fi

# ── Fallback / supplemental: grep heuristics ─────────────────────────────────

echo "--- domain/ must not import infrastructure/ or features/ ---"
grep -rn $EXCLUDES \
  -e "from[[:space:]]*['\"].*infrastructure" \
  -e "require[[:space:]]*(['\"].*infrastructure" \
  -e "from[[:space:]]*['\"].*features" \
  -e "require[[:space:]]*(['\"].*features" \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- domain/ must not call external systems ---"
grep -rn $EXCLUDES \
  -e "fetch(" \
  -e "axios" \
  -e "prisma" \
  -e "mongoose" \
  -e "pg\." \
  -e "redis" \
  -e "http\." \
  -e "https\." \
  -e "knex" \
  -e "drizzle" \
  -e "kysely" \
  -e "typeorm" \
  -e "sequelize" \
  "$domain/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- infrastructure/ must not import features/ ---"
grep -rn $EXCLUDES \
  -e "from[[:space:]]*['\"].*features" \
  -e "require[[:space:]]*(['\"].*features" \
  "$infra/" 2>/dev/null | grep -v "^Binary" || echo "(none)"

echo "--- features/ large feature domain direct calls ---"
grep -rn $EXCLUDES \
  -e "from[[:space:]]*['\"].*domain" \
  -e "require[[:space:]]*(['\"].*domain" \
  "$features/" 2>/dev/null | grep -v "^Binary" || echo "(none — verify manually if large features exist)"
