#!/usr/bin/env bash
# Phase predicates and path-matching for phase-gate enforcement (formerly phase-rules.sh + lib/path-match.sh).
# Source this file; do not execute directly.
[[ -n "${_PHASE_POLICY_LOADED:-}" ]] && return 0
_PHASE_POLICY_LOADED=1

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
