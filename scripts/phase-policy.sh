#!/usr/bin/env bash
# Phase predicates and path-matching for phase-gate enforcement.
# Capability functions (require_capability, _ppid_chain_is_harness) live in capability.sh.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_PHASE_POLICY_LOADED:-}" ]] && return 0
_PHASE_POLICY_LOADED=1
declare -F die >/dev/null 2>&1 || die() { echo "ERROR: $*" >&2; exit 1; }

# ── Path-matching predicates ─────────────────────────────────────────────────
# If you change the default VSA layer paths or built-in glob fallbacks, update reference/layers.md.

VSA_LAYER_PATHS=(
  "src/domain"
  "src/features"
  "src/infrastructure"
)
VSA_LAYER_PATHS_LABEL="src/domain/, src/features/, src/infrastructure/"

is_source_path() {
  local p="$1"
  if [ -n "${PHASE_GATE_SRC_GLOB:-}" ]; then
    local pattern
    while IFS= read -r pattern; do
      case "$p" in $pattern) return 0 ;; esac
    done < <(printf '%s\n' "$PHASE_GATE_SRC_GLOB" | tr ':' '\n')
    return 1
  fi
  local layer_path
  for layer_path in "${VSA_LAYER_PATHS[@]}"; do
    case "$p" in
      "${layer_path}/"*) return 0 ;;
      *"/${layer_path}/"*) return 0 ;;
    esac
  done
  case "$p" in
    src/main/kotlin/*|src/main/java/*|src/main/scala/*|\
    packages/*/src/*|\
    internal/*|cmd/*|pkg/*|\
    app/*|app/models/*|app/controllers/*|app/services/*|\
    lib/*|\
    crates/*/src/*|\
    apps/*/src/*)
      return 0 ;;
    *) return 1 ;;
  esac
}

is_test_path() {
  local p="$1"
  case "$p" in *.spec.md) return 1 ;; esac
  if [ -n "${PHASE_GATE_TEST_GLOB:-}" ]; then
    local pattern
    while IFS= read -r pattern; do
      case "$p" in $pattern) return 0 ;; esac
    done < <(printf '%s\n' "$PHASE_GATE_TEST_GLOB" | tr ':' '\n')
    return 1
  fi
  case "$p" in
    tests/*|*_test.*|test_*.*|*.test.*|*.spec.*|*_spec.*) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Phase predicates ─────────────────────────────────────────────────────────

phase_blocks_src() {
  case "$1" in
    brainstorm|spec|red|done) return 0 ;;
    *) return 1 ;;
  esac
}

phase_blocks_test() {
  case "$1" in
    brainstorm|spec|implement|review|green|integration|done) return 0 ;;
    *) return 1 ;;
  esac
}

phase_runs_stop_check() {
  case "$1" in
    green|integration) return 0 ;;
    *) return 1 ;;
  esac
}

list_phases() {
  echo "brainstorm spec red implement review green integration done"
}

# apply_phase_block <path> <phase> [label]
# Returns 2 and prints to stderr if the path is blocked in this phase; returns 0 if allowed.
apply_phase_block() {
  local path="$1" phase="$2" label="${3:-phase-gate}"

  if is_source_path "$path" && phase_blocks_src "$phase"; then
    case "$phase" in
      brainstorm|spec)
        echo "BLOCKED [$label]: Phase is '$phase'. Writing source files is not allowed before Red phase. Complete /writing-spec and /writing-tests first." >&2 ;;
      red)
        echo "BLOCKED [$label]: Phase is 'red'. Writing source files in ${VSA_LAYER_PATHS_LABEL} is not allowed during Red phase. Write tests only." >&2 ;;
      done)
        echo "BLOCKED [$label]: Phase is 'done' and '$path' is a source/test path. Run /brainstorming to start a new feature (creates a new plan file), or set CLAUDE_PLAN_FILE=plans/{new-slug}.md before writing." >&2 ;;
    esac
    return 2
  fi

  if is_test_path "$path" && phase_blocks_test "$phase"; then
    case "$phase" in
      brainstorm|spec)
        echo "BLOCKED [$label]: Phase is '$phase'. Writing test files is not allowed before spec is approved. Complete /writing-spec first, then advance to Red phase with /writing-tests." >&2 ;;
      done)
        echo "BLOCKED [$label]: Phase is 'done' and '$path' is a source/test path. Run /brainstorming to start a new feature (creates a new plan file), or set CLAUDE_PLAN_FILE=plans/{new-slug}.md before writing." >&2 ;;
      *)
        echo "BLOCKED [$label]: Phase is '$phase'. Test-file freeze in effect — see reference/phase-gate-config.md §Phase enforcement rules." >&2 ;;
    esac
    return 2
  fi

  return 0
}

# NOTE: [INFO] falls through to user_memos in gc-events.
# [BLOCKED] category:/parse: — persists across phase rollback; requires explicit clear-marker.
# [BLOCKED-AMBIGUOUS] — persists across phase rollback; embedded question requires human input.
#   Recipe: resolve, then plan-file.sh clear-marker "[BLOCKED-AMBIGUOUS] {agent}" and re-run.
# Markers that require human intervention to clear.
HUMAN_MUST_CLEAR_MARKERS=(
  "[BLOCKED-AMBIGUOUS]"
  "[BLOCKED-CEILING]"
  "[ESCALATION]"
  "[BLOCKED] protocol-violation:"
  "[BLOCKED] category:"
  "[BLOCKED] parse:"
  "[BLOCKED] integration:"
  "[BLOCKED] preflight:"
  "[BLOCKED] coder:"
  "[BLOCKED] script-failure:"
  "[BLOCKED] post-implement smoke test"
  ": session-timeout"
  ": script-failure"
  ": no timeout binary"
  ": plan unchanged"
)

# Echoes the first matching HUMAN_MUST_CLEAR_MARKERS entry if any is present in $1
# (plan file path). Returns 1 if none found.
# Markers beginning with '[' must appear at the start of a line (line-anchored ERE)
# so historical audit prose containing the same text mid-sentence does not trigger.
# Colon-prefixed markers (": session-timeout" etc.) are sub-patterns of a
# "[BLOCKED] {agent}: ..." line and are matched as substrings.
marker_present_human_must_clear() {
  local plan_file="$1" marker escaped
  [[ -f "$plan_file" ]] || return 1
  for marker in "${HUMAN_MUST_CLEAR_MARKERS[@]}"; do
    if [[ "$marker" == \[* ]]; then
      escaped=$(printf '%s' "$marker" | sed 's/[][\\.*^$(){}?+|]/\\&/g')
      grep -qE "^[[:space:]]*${escaped}" "$plan_file" 2>/dev/null || continue
    else
      grep -qF "$marker" "$plan_file" 2>/dev/null || continue
    fi
    printf '%s\n' "$marker"; return 0
  done
  return 1
}

SIDECAR_PROTECTED_GLOBS=(
  "*/plans/*.state/*"
  "plans/*.state/*"
)

is_sidecar_path() {
  local p="$1" glob
  for glob in "${SIDECAR_PROTECTED_GLOBS[@]}"; do
    case "$p" in $glob) return 0 ;; esac
  done
  return 1
}

# Source capability module (provides require_capability and _ppid_chain_is_harness).
_PHASE_POLICY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${_CAPABILITY_LOADED:-}" ]] || . "$_PHASE_POLICY_DIR/capability.sh"
