#!/usr/bin/env bash
# Phase predicates and path-matching for phase-gate enforcement (formerly phase-rules.sh + lib/path-match.sh).
# Source this file; do not execute directly.
[[ -n "${_PHASE_POLICY_LOADED:-}" ]] && return 0
_PHASE_POLICY_LOADED=1
command -v die >/dev/null 2>&1 || die() { echo "ERROR: $*" >&2; exit 1; }

# ── Path-matching predicates ─────────────────────────────────────────────────
# If you change the default VSA layer paths or glob lists, update reference/layers.md and
# reference/phase-gate-config.md examples to match.

# VSA layer paths — mirrors reference/layers.md §Layers.
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
  # Framework-specific source paths (non-VSA)
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
  # Always exclude BDD spec files — writing-spec must write features/{name}/spec.md in all phases.
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
# phase_blocks_src       <phase>  — returns 0 (true) if the phase forbids source writes
# phase_blocks_test      <phase>  — returns 0 (true) if the phase forbids test writes
# phase_runs_stop_check  <phase>  — returns 0 (true) if the stop-check hook enforces tests in this phase
# list_phases                     — echoes canonical phase order (consumed by plan-lib.sh)

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

# Canonical phase order — single source of truth consumed by plan-lib.sh.
list_phases() {
  echo "brainstorm spec red implement review green integration done"
}

# apply_phase_block <path> <phase> [label]
# Returns 2 and prints to stderr if the path is blocked in this phase; returns 0 if allowed.
# Requires: is_source_path, is_test_path, VSA_LAYER_PATHS_LABEL (defined above)
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

# Markers that require human intervention to clear.
# Single source of truth: sourced by pretooluse-bash.sh to enforce the clear-marker block.
# When adding a new human-must-clear marker: add an entry here, then update reference/markers.md.
HUMAN_MUST_CLEAR_MARKERS=(
  "BLOCKED-AMBIGUOUS"
  "BLOCKED-CEILING"
  "BLOCKED] protocol-violation:"
  "BLOCKED] category:"
  "BLOCKED] parse:"
  "BLOCKED] integration:"
  "BLOCKED] preflight:"
  "BLOCKED] coder:"
  "BLOCKED] post-implement smoke test"
  ": session-timeout"
  ": script-failure"
  ": no timeout binary"
  ": plan unchanged"
)

# Sidecar protected path globs — used by is_sidecar_path() for resolved-path checks.
# Full-command-text patterns (for interpreter/redirect detection) remain inline in pretooluse-bash.sh.
# Any resolved destination path matching these globs is blocked: the sidecar is harness-exclusive.
SIDECAR_PROTECTED_GLOBS=(
  "*/plans/*.state/*"
  "plans/*.state/*"
  "plans/*.state"
)

# is_sidecar_path PATH — returns 0 if PATH matches any sidecar protected glob
is_sidecar_path() {
  local p="$1" glob
  for glob in "${SIDECAR_PROTECTED_GLOBS[@]}"; do
    case "$p" in $glob) return 0 ;; esac
  done
  return 1
}

# Walk PPID chain (up to 10 levels) looking for a harness script ancestor.
_ppid_chain_is_harness() {
  local pid="$$"
  local depth=0
  while [[ $depth -lt 10 ]]; do
    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]') || return 1
    [[ -z "$pid" || "$pid" -le 1 ]] && return 1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    local cmd
    cmd=$(ps -ww -p "$pid" -o args= 2>/dev/null || true)
    case "$cmd" in
      *run-critic-loop.sh*|*run-dev-cycle.sh*|*run-implement.sh*|\
      *run-integration.sh*|*stop-check.sh*) return 0 ;;
    esac
    depth=$((depth + 1))
  done
  return 1
}

# require_capability CMD [RING]
# RING=B (default): allow if CLAUDE_PLAN_CAPABILITY=harness, PPID chain is harness, or stdin is TTY.
# RING=C: allow if CLAUDE_PLAN_CAPABILITY=human or stdin is TTY.
# Provides defence-in-depth: env-var (primary), PPID chain (secondary), TTY (human fallback).
require_capability() {
  local cmd="$1" ring="${2:-B}"
  if [[ "$ring" == "C" ]]; then
    [[ "${CLAUDE_PLAN_CAPABILITY:-}" == "human" ]] && return 0
    [[ -t 0 ]] && return 0
    die "[$cmd] is human-only — run from terminal (or set CLAUDE_PLAN_CAPABILITY=human)"
  fi
  # Ring B: env-var, PPID chain, or TTY
  [[ "${CLAUDE_PLAN_CAPABILITY:-}" == "harness" ]] && return 0
  _ppid_chain_is_harness && return 0
  [[ -t 0 ]] && return 0
  die "[$cmd] requires CLAUDE_PLAN_CAPABILITY=harness"
}
