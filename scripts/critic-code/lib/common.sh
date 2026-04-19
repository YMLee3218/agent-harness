#!/usr/bin/env bash
# Shared helpers for layer boundary checker scripts.
# Source this file after setting $domain, $infra, $features in the caller
# (or leave them empty and call init_layer_check to apply defaults).
#
# init_layer_check <lang-label> <excludes-flags>
#   Applies default values for $domain/$infra/$features if unset,
#   sets $EXCLUDES, and prints the === header.
#
# try_preferred_tool <tool-cmd> <label> <run-fn>
#   If <tool-cmd> is available, prints label, calls <run-fn>, prints blank line.
#   <run-fn> is a shell function defined by the caller.
#
# check_layer <label> <dir> <none_msg> [-e pattern ...]
#   Prints a labelled grep result block.
#   $EXCLUDES is read from the caller's environment (word-splits intentionally).
#
# run_layer_checks
#   Runs all four standard boundary checks using caller-defined pattern arrays:
#     DOMAIN_PATTERNS  — imports that domain/ must NOT contain (infra/features refs)
#     STDLIB_PATTERNS  — external system calls that domain/ must NOT use
#     INFRA_PATTERNS   — imports that infrastructure/ must NOT contain (features refs)
#     FEATURE_PATTERNS — domain direct calls that large features/ must NOT make

# Optional preferred-tool hook — set by language conf files before sourcing common.sh
# or before calling run_layer_checks. If PREFERRED_TOOL_CMD is non-empty,
# run_layer_checks calls try_preferred_tool before the grep-based checks.
PREFERRED_TOOL_CMD=""
PREFERRED_TOOL_LABEL=""
PREFERRED_TOOL_FN=""

# Built-in preferred-tool implementations (called via PREFERRED_TOOL_FN).

# run_depcruise: dependency-cruiser JSON output for TypeScript/JavaScript projects.
run_depcruise() {
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
}

# run_ruff: ruff --select TID (banned imports) for Python projects.
run_ruff() {
  ruff check --select TID --output-format json "$domain/" "$infra/" "$features/" 2>/dev/null \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
for d in data:
    print(f\"{d['filename']}:{d['location']['row']} [{d['code']}] {d['message']}\")
" 2>/dev/null || echo "(ruff json parse failed — see grep fallback below)"
}

# init_layer_check <lang-label> <excludes-flags>
init_layer_check() {
  local lang_label="$1"; shift
  EXCLUDES="$*"
  domain="${domain:-src/domain}"
  infra="${infra:-src/infrastructure}"
  features="${features:-src/features}"
  echo "=== $lang_label layer boundary check ==="
}

# try_preferred_tool <tool-cmd> <label> <run-fn>
# <run-fn> is a shell function name (no args) defined by the caller.
try_preferred_tool() {
  local tool_cmd="$1" label="$2" run_fn="$3"
  if command -v "$tool_cmd" >/dev/null 2>&1; then
    echo "--- $label ---"
    "$run_fn"
    echo ""
  fi
}

# report_hit <severity> <message>
# Prints a severity-tagged line. severity: FAIL or WARN.
report_hit() {
  local severity="$1"; shift
  printf '[%s] %s\n' "$severity" "$*"
}

check_layer() {
  local label="$1" dir="$2" none_msg="$3"; shift 3
  echo "--- $label ---"
  # shellcheck disable=SC2086
  grep -rn $EXCLUDES "$@" "$dir" 2>/dev/null | grep -v "^Binary" || echo "$none_msg"
}

# check_layer_tagged <severity> <label> <dir> <none_msg> [-e pattern ...]
# Like check_layer but prefixes each hit with [FAIL] or [WARN].
check_layer_tagged() {
  local severity="$1" label="$2" dir="$3" none_msg="$4"; shift 4
  echo "--- $label ---"
  local hits
  # shellcheck disable=SC2086
  hits=$(grep -rn $EXCLUDES "$@" "$dir" 2>/dev/null | grep -v "^Binary" || true)
  if [ -z "$hits" ]; then
    echo "$none_msg"
  else
    while IFS= read -r line; do
      report_hit "$severity" "$line"
    done <<< "$hits"
  fi
}

run_layer_checks() {
  [ -n "$PREFERRED_TOOL_CMD" ] && try_preferred_tool "$PREFERRED_TOOL_CMD" "$PREFERRED_TOOL_LABEL" "$PREFERRED_TOOL_FN"
  check_layer "domain/ must not import infrastructure/ or features/" \
    "$domain" "(none)" "${DOMAIN_PATTERNS[@]}"
  check_layer_tagged "FAIL" "domain/ must not call external systems" \
    "$domain" "(none)" "${STDLIB_PATTERNS[@]}"
  check_layer "infrastructure/ must not import features/" \
    "$infra" "(none)" "${INFRA_PATTERNS[@]}"
  check_layer_tagged "WARN" "features/ large feature domain direct calls (verify: small=allowed, large=violation)" \
    "$features" "(none — verify manually if large features exist)" "${FEATURE_PATTERNS[@]}"
}
