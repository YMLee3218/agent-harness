#!/usr/bin/env bash
# critic-helpers.sh — shell-side critic loop utilities for Codex-driven critics.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_CRITIC_HELPERS_LOADED:-}" ]] && return 0
_CRITIC_HELPERS_LOADED=1

_CRITIC_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CRITIC_WS_ROOT="$(cd "${_CRITIC_HELPERS_DIR}/../.." && pwd)"

# Agents that use the new shell-driven Codex path (no B-session Claude per iteration).
_CODEX_DRIVEN_AGENTS="critic-spec critic-test critic-code critic-cross"

_is_codex_driven_agent() {
  local _a="$1"
  local _ca
  for _ca in $_CODEX_DRIVEN_AGENTS; do [[ "$_a" == "$_ca" ]] && return 0; done
  return 1
}

# _sed_rval VAL — escape a string for use as a sed replacement value when | is the delimiter.
# Escapes: \ (must come first), & (means "matched text" in sed replacement), | (delimiter).
_sed_rval() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g' -e 's/|/\\|/g'; }

# build_review_prompt AGENT OUT_FILE
# Extracts the Codex prompt template from skills/{agent}/SKILL.md (strips YAML frontmatter),
# substitutes placeholders, writes filled prompt to OUT_FILE.
build_review_prompt() {
  local _agent="$1" _out="$2"
  local _skill="${_CRITIC_WS_ROOT}/skills/${_agent}/SKILL.md"
  [[ -f "$_skill" ]] || { echo "[critic-helpers] ERROR: skill file not found: $_skill" >&2; return 1; }

  # Strip YAML frontmatter (content between the first and second '---' lines)
  local _template
  _template=$(awk '
    /^---$/ && !started { started=1; next }
    /^---$/ && started  { past_fm=1; next }
    past_fm             { print }
  ' "$_skill")

  [[ -z "$_template" ]] && { echo "[critic-helpers] ERROR: no content after frontmatter in $_skill" >&2; return 1; }

  printf '%s\n' "$_template" | sed \
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
    -e "s|\${PROJECT_DIR}|$(_sed_rval "${CLAUDE_PROJECT_DIR:-}")|g" \
    > "$_out"
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
# Writes the Claude decision/audit prompt for a FAIL verdict to OUT_FILE.
build_decision_prompt() {
  local _agent="$1" _log="$2" _plan="$3" _out="$4"
  local _spec_path="${CRITIC_SPEC_PATH:-${CRITIC_ALL_SPEC_PATHS:-}}"
  local _docs_paths="${CRITIC_DOCS_PATHS:-}"

  cat > "$_out" <<DECISION_PROMPT
ultrathink

Perform a comprehensive verdict audit for a FAIL verdict from ${_agent}.

Review log: ${_log}
${_spec_path:+Spec: ${_spec_path}}
${_docs_paths:+Docs: ${_docs_paths}}

Apply all 6 §Audit checklist items:
1. For each blocking finding in the Citation Summary: Read the cited file:line. Excerpt absent → FALSE-POSITIVE. [MISSING]: Read the spec, search for scenario keywords; found → FALSE-POSITIVE.
2. Coverage gaps: Read the spec. Are there Scenarios/Scenario Outlines the review did not address?
3. Fix direction: does the proposed fix target the root cause?
4. False positive/negative risk.
5. Category accuracy — does \`<!-- category: X -->\` use the highest-priority enum value present (ENVELOPE_MISMATCH > PROPAGATED_VALUE_OUT_OF_SYNC > ENVELOPE_OVERREACH > LAYER_VIOLATION > CROSS_FEATURE_CONTRADICTION > DOCS_CONTRADICTION > UNVERIFIED_CLAIM > SPEC_COMPLIANCE > MISSING_SCENARIO > TEST_INTEGRITY > TEST_QUALITY > STRUCTURAL)?
6. Per-finding classification:
   - GENUINE: cited excerpt IS present at file:line AND fix direction is determinable from the reviewed files (spec, docs, review log)
   - FALSE-POSITIVE: (a) excerpt absent from cited file:line, OR (b) [MISSING] finding whose scenario keywords are confirmed present in the spec
   - AMBIGUOUS: excerpt present and finding real, but correct fix requires evidence NOT available in the reviewed files — use BLOCKED-AMBIGUOUS

Output (shell-parsed exactly):
AUDIT: ACCEPT
GENUINE: [F1: tag + description, or "none"]
FALSE-POSITIVE: [F2: reason, or "none"]
FIX-PLAN:
  - file: {path}, change: {concrete description}

Special cases:
- All FALSE-POSITIVE → AUDIT: ACCEPT-OVERRIDE, omit FIX-PLAN.
- Any AMBIGUOUS → AUDIT: BLOCKED-AMBIGUOUS; FIX-PLAN for GENUINE only; add per AMBIGUOUS:
  [BLOCKED:spec] ${_agent}: ambiguous — {one-sentence human question}
  Exception — DOCS_CONTRADICTION finding where docs may be stale and fix direction is unclear: emit instead:
  [BLOCKED:docs] ${_agent}: contradiction — docs may be stale, ground truth ambiguous; apply cascade
DECISION_PROMPT
}

# build_fix_prompt AGENT LOG_PATH FIX_PLAN_TEXT SPEC_REF PLAN_PATH OUT_FILE
# Writes a Codex fix prompt to OUT_FILE based on the parsed FIX-PLAN from the decision agent.
build_fix_prompt() {
  local _agent="$1" _log="$2" _fix_plan="$3" _spec_ref="$4" _plan="$5" _out="$6"

  cat > "$_out" <<FIX_PROMPT
Fix the following issues found by ${_agent}. Apply ALL items in the fix plan comprehensively.

Plan: ${_plan}
Spec reference: ${_spec_ref}
Review log (evidence): ${_log}

## Fix plan — address every item below

${_fix_plan}

## Evidence rule
Read the exact cited file:line before modifying any file. If the cited excerpt is not present at that line, skip that item.

## Completion
After applying all fixes, output a summary of every change made.
FIX_PROMPT
}

# build_pass_audit_prompt AGENT LOG_PATH PLAN_PATH OUT_FILE
# Writes a minimal REJECT-PASS check prompt to OUT_FILE.
build_pass_audit_prompt() {
  local _agent="$1" _log="$2" _plan="$3" _out="$4"
  local _spec_path="${CRITIC_SPEC_PATH:-${CRITIC_ALL_SPEC_PATHS:-}}"

  cat > "$_out" <<PASS_PROMPT
Perform the PASS convergence check for ${_agent}.

Review log: ${_log}
${_spec_path:+Spec: ${_spec_path}}

Read the review log and spec. Apply:
2. Coverage gaps: Read the spec. Is every Scenario and Scenario Outline addressed in the review?
   List any scenario the reviewer did not examine.
4. PASS comprehensiveness: is this PASS a genuine clean slate, or did the reviewer skip angles?

Be conservative — only reject if there is a clearly unreviewed scenario or skipped angle.

Output exactly one of:
VERDICT: ACCEPT
or
VERDICT: REJECT-PASS — {one-sentence description of the unreviewed scenario or skipped angle}
PASS_PROMPT
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
