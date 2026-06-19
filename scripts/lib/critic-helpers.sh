#!/usr/bin/env bash
# critic-helpers.sh — shell-side critic loop utilities for Codex-driven critics.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_CRITIC_HELPERS_LOADED:-}" ]] && return 0
_CRITIC_HELPERS_LOADED=1

_CRITIC_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CRITIC_WS_ROOT="$(cd "${_CRITIC_HELPERS_DIR}/../.." && pwd)"
_PROMPTS_DIR="${_CRITIC_HELPERS_DIR}/../prompts"
# Role → engine routing table (single source of truth for engine selection).
[[ -n "${_ENGINE_REGISTRY_LOADED:-}" ]] || . "$_CRITIC_HELPERS_DIR/engine-registry.sh"

# An agent uses the shell-driven Codex path iff its engine resolves to codex; otherwise it
# takes the B-session Claude path. Routing is delegated to the registry so engine selection
# lives in exactly one place (no hard-coded agent-name branch here).
_is_codex_driven_agent() {
  [[ "$(engine_for "$1" 2>/dev/null)" == "codex" ]]
}

# _sed_rval VAL — escape a string for use as a sed replacement value when | is the delimiter.
# Escapes: \ (must come first), & (means "matched text" in sed replacement), | (delimiter).
_sed_rval() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g' -e 's/|/\\|/g'; }

# render_prompt SRC OUT [key=value]...
# Low-level prompt renderer shared by every engine-agnostic prompt (.md template):
#   1. Strips YAML frontmatter (content between the first and second '---' lines).
#   2. Substitutes the standard env-driven CRITIC_* / ${PROJECT_DIR} placeholders.
#   3. Substitutes any caller-supplied {key} tokens with their value (handles multi-line
#      values, e.g. a FIX-PLAN block — bash replacement avoids sed's newline limitation).
# A template that contains none of a given token class simply leaves that pass a no-op, so
# the same renderer serves SKILL.md review templates and the prompts/*.md builders.
render_prompt() {
  local _src="$1" _out="$2"; shift 2
  [[ -f "$_src" ]] || { echo "[critic-helpers] ERROR: prompt template not found: $_src" >&2; return 1; }

  local _template
  _template=$(awk '
    /^---$/ && !started { started=1; next }
    /^---$/ && started  { past_fm=1; next }
    past_fm             { print }
  ' "$_src")

  [[ -z "$_template" ]] && { echo "[critic-helpers] ERROR: no content after frontmatter in $_src" >&2; return 1; }

  local _rendered
  _rendered=$(printf '%s\n' "$_template" | sed \
    -e "s|{spec_path}|$(_sed_rval "${CRITIC_SPEC_PATH:-}")|g" \
    -e "s|{docs_paths}|$(_sed_rval "${CRITIC_DOCS_PATHS:-}")|g" \
    -e "s|{plan_path}|$(_sed_rval "${CRITIC_PLAN_PATH:-}")|g" \
    -e "s|{test_files}|$(_sed_rval "${CRITIC_TEST_FILES:-}")|g" \
    -e "s|{test_command}|$(_sed_rval "${CRITIC_TEST_COMMAND:-}")|g" \
    -e "s|{all_spec_paths}|$(_sed_rval "${CRITIC_ALL_SPEC_PATHS:-}")|g" \
    -e "s|{language}|$(_sed_rval "${CRITIC_LANGUAGE:-}")|g" \
    -e "s|{domain_root}|$(_sed_rval "${CRITIC_DOMAIN_ROOT:-}")|g" \
    -e "s|{infra_root}|$(_sed_rval "${CRITIC_INFRA_ROOT:-}")|g" \
    -e "s|{features_root}|$(_sed_rval "${CRITIC_FEATURES_ROOT:-}")|g" \
    -e "s|\${PROJECT_DIR}|$(_sed_rval "${CLAUDE_PROJECT_DIR:-}")|g")

  # bash 5.2+ enables patsub_replacement by default, which makes a bare & in a
  # ${var//pat/repl} replacement expand to the matched text. We want literal substitution
  # (values may legitimately contain &), so disable it for the loop and restore afterward.
  # On bash < 5.2 the option does not exist, so the guard simply skips toggling it.
  local _kv _k _v _patsub_was_set=0
  if shopt -q patsub_replacement 2>/dev/null; then _patsub_was_set=1; shopt -u patsub_replacement; fi
  for _kv in "$@"; do
    _k="${_kv%%=*}"; _v="${_kv#*=}"
    _rendered="${_rendered//"{$_k}"/$_v}"
  done
  [[ $_patsub_was_set -eq 1 ]] && shopt -s patsub_replacement

  printf '%s\n' "$_rendered" > "$_out"
}

# build_review_prompt AGENT OUT_FILE [SKILL_FILE]
# Renders the Codex review prompt from skills/{agent}/SKILL.md (or an explicit angle file).
build_review_prompt() {
  local _agent="$1" _out="$2" _skill="${3:-}"
  [[ -z "$_skill" ]] && _skill="${_CRITIC_WS_ROOT}/skills/${_agent}/SKILL.md"
  render_prompt "$_skill" "$_out"
}

# extract_all_findings LOG_PATH → prints one blocking finding per line to stdout
extract_all_findings() {
  local _log="$1"
  [[ -f "$_log" ]] || return 0
  grep -E '^\[(CRITICAL|MISSING|MANIFEST-GAP|FAIL|DOCS CONTRADICTION|UNVERIFIED CLAIM)\]' \
    "$_log" 2>/dev/null || true
}

# parse_verdict_from_log LOG_PATH → prints "verdict|category" to stdout
# Extracts only from the last ### Verdict block to prevent cross-pairing across blocks.
parse_verdict_from_log() {
  local _log="$1"
  [[ -f "$_log" ]] || { printf '|'; return; }
  local _v _c _start _block
  _start=$(grep -n "^### Verdict" "$_log" 2>/dev/null | tail -1 | cut -d: -f1)
  if [[ -z "$_start" ]]; then
    printf '|'; return
  fi
  _block=$(tail -n +"$_start" "$_log" 2>/dev/null)
  _v=$(printf '%s' "$_block" | grep -oE '<!--[[:space:]]*verdict:[[:space:]]*[A-Z]+[[:space:]]*-->' | tail -1 \
       | sed -E 's/<!--[[:space:]]*verdict:[[:space:]]*//; s/[[:space:]]*-->//' || true)
  _c=$(printf '%s' "$_block" | grep -oE '<!--[[:space:]]*category:[[:space:]]*[A-Z_]+[[:space:]]*-->' | tail -1 \
       | sed -E 's/<!--[[:space:]]*category:[[:space:]]*//; s/[[:space:]]*-->//' || true)
  printf '%s|%s' "${_v:-}" "${_c:-}"
}

# build_decision_prompt AGENT LOG_PATH PLAN_PATH OUT_FILE
# Renders the Claude decision/audit prompt (prompts/critic-decision.md) for a FAIL verdict.
# Conditional Spec/Docs lines are computed here and passed as whole-line tokens (empty → blank line).
build_decision_prompt() {
  local _agent="$1" _log="$2" _plan="$3" _out="$4"
  local _spec_path="${CRITIC_SPEC_PATH:-${CRITIC_ALL_SPEC_PATHS:-}}"
  local _docs_paths="${CRITIC_DOCS_PATHS:-}"
  local _spec_line="" _docs_line=""
  [[ -n "$_spec_path" ]] && _spec_line="Spec: ${_spec_path}"
  [[ -n "$_docs_paths" ]] && _docs_line="Docs: ${_docs_paths}"
  render_prompt "${_PROMPTS_DIR}/critic-decision.md" "$_out" \
    "agent=${_agent}" "log=${_log}" "spec_line=${_spec_line}" "docs_line=${_docs_line}"
}

# build_fix_prompt AGENT LOG_PATH FIX_PLAN_TEXT SPEC_REF PLAN_PATH OUT_FILE
# Renders a Codex fix prompt (prompts/critic-fix.md) from the parsed FIX-PLAN.
build_fix_prompt() {
  local _agent="$1" _log="$2" _fix_plan="$3" _spec_ref="$4" _plan="$5" _out="$6"
  render_prompt "${_PROMPTS_DIR}/critic-fix.md" "$_out" \
    "agent=${_agent}" "plan=${_plan}" "spec_ref=${_spec_ref}" "log=${_log}" "fix_plan=${_fix_plan}"
}

# build_pass_audit_prompt AGENT LOG_PATH PLAN_PATH OUT_FILE
# Renders the minimal REJECT-PASS check prompt (prompts/critic-pass-audit.md).
build_pass_audit_prompt() {
  local _agent="$1" _log="$2" _plan="$3" _out="$4"
  local _spec_path="${CRITIC_SPEC_PATH:-${CRITIC_ALL_SPEC_PATHS:-}}"
  local _spec_line=""
  [[ -n "$_spec_path" ]] && _spec_line="Spec: ${_spec_path}"
  render_prompt "${_PROMPTS_DIR}/critic-pass-audit.md" "$_out" \
    "agent=${_agent}" "log=${_log}" "spec_line=${_spec_line}"
}

# parse_audit_outcome DECISION_OUTPUT → prints ACCEPT | ACCEPT-OVERRIDE | BLOCKED-AMBIGUOUS
# Returns empty string on parse failure — caller must check and handle.
parse_audit_outcome() {
  local _out="$1"
  printf '%s' "$_out" | grep -oE '^AUDIT:[[:space:]]*(ACCEPT-OVERRIDE|BLOCKED-AMBIGUOUS|ACCEPT)' | \
    head -1 | sed 's/AUDIT:[[:space:]]*//' || true
}

# parse_fix_plan DECISION_OUTPUT → prints FIX-PLAN section to stdout
parse_fix_plan() {
  local _out="$1"
  printf '%s' "$_out" | awk '
    /^FIX-PLAN:/ { in_plan=1; next }
    in_plan && /^(AUDIT:|GENUINE:|FALSE-POSITIVE:|\[BLOCKED:)/ { in_plan=0 }
    in_plan { print }
  ' | grep -v '^[[:space:]]*$' || true
}

# _category_priority CAT → prints numeric priority (1=highest). 99 for unknown.
_category_priority() {
  case "$1" in
    ENVELOPE_MISMATCH)            printf '1'  ;;
    PROPAGATED_VALUE_OUT_OF_SYNC) printf '2'  ;;
    ENVELOPE_OVERREACH)           printf '3'  ;;
    LAYER_VIOLATION)              printf '4'  ;;
    CROSS_FEATURE_CONTRADICTION)  printf '5'  ;;
    DOCS_CONTRADICTION)           printf '6'  ;;
    UNVERIFIED_CLAIM)             printf '7'  ;;
    SPEC_COMPLIANCE)              printf '8'  ;;
    MISSING_SCENARIO)             printf '9'  ;;
    TEST_INTEGRITY)               printf '10' ;;
    TEST_QUALITY)                 printf '11' ;;
    SECURITY)                     printf '12' ;;
    LOGIC_ROBUSTNESS)             printf '13' ;;
    MODULARITY)                   printf '14' ;;
    TYPE_DESIGN)                  printf '15' ;;
    PERFORMANCE)                  printf '16' ;;
    DUPLICATION)                  printf '17' ;;
    ANALYSABILITY)                printf '18' ;;
    STRUCTURAL)                   printf '19' ;;
    *)                            printf '99' ;;
  esac
}

# aggregate_angle_verdicts OUT_LOG ANGLE_LOG...
# Collects all blocking findings from angle logs, OR-reduces verdicts,
# picks highest-priority FAIL category, writes single ### Verdict block to OUT_LOG.
aggregate_angle_verdicts() {
  local _out_log="$1"; shift
  local _fail_found=0 _best_cat="" _best_prio _alog _vc _v _c _prio
  _best_prio=99

  : > "$_out_log"
  for _alog in "$@"; do
    [[ -f "$_alog" ]] || continue
    extract_all_findings "$_alog" >> "$_out_log" || true
  done

  for _alog in "$@"; do
    [[ -f "$_alog" ]] || continue
    _vc=$(parse_verdict_from_log "$_alog")
    _v="${_vc%%|*}"
    _c="${_vc##*|}"
    if [[ "$_v" == "FAIL" ]]; then
      _fail_found=1
      _prio=$(_category_priority "$_c")
      if [[ $_prio -lt $_best_prio ]]; then
        _best_cat="$_c"
        _best_prio=$_prio
      fi
    fi
  done

  if [[ $_fail_found -eq 1 ]]; then
    {
      printf '\n### Verdict\n'
      printf 'FAIL\n'
      printf '<!-- verdict: FAIL -->\n'
      printf '<!-- category: %s -->\n' "${_best_cat:-STRUCTURAL}"
    } >> "$_out_log"
  else
    {
      printf '\n### Verdict\n'
      printf 'PASS\n'
      printf '<!-- verdict: PASS -->\n'
      printf '<!-- category: NONE -->\n'
    } >> "$_out_log"
  fi
}
