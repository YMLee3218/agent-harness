#!/usr/bin/env bash
# Capability ring gate.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_CAPABILITY_LOADED:-}" ]] && return 0
_CAPABILITY_LOADED=1

declare -F die >/dev/null 2>&1 || die() { echo "ERROR: $*" >&2; exit 1; }

# Shared Ring C file pattern — used by phase-gate.sh (_guard_ring_c) and
# pretooluse-bash.sh (normal and unexpanded-path paths). One inner definition
# (_RING_C_INNER) sourced everywhere to prevent divergence.
_RING_C_INNER='(CLAUDE\.md|settings\.json|reference/(markers|critics|phase-gate-config|layers|effort|anti-hallucination|language|severity|phase-ops|ultrathink|pr-review-loop|bdd-templates|operating-envelope)\.md|scripts/[^/]+\.sh|scripts/lib/[^/]+\.sh|scripts/critic-code/[^/]+\.(sh|template)|scripts/critic-code/lib/[^/]+\.sh|scripts/critic-code/patterns/[^/]+|scripts/dev-tools/[^/]+\.sh)'
_RING_C_FILES="(\.claude(-harness)?/)?${_RING_C_INNER}"

# require_capability CMD [RING]
# RING=B (default): allow if CLAUDE_PLAN_CAPABILITY=harness.
# RING=C: allow if CLAUDE_PLAN_CAPABILITY=human.
# The env var cannot be set from an agent Bash tool call — block_capability in
# pretooluse-blocks.sh rejects any CLAUDE_PLAN_CAPABILITY assignment — so its
# presence proves a harness script or human terminal launched the process.
require_capability() {
  local cmd="$1" ring="${2:-B}"
  if [[ "$ring" == "C" ]]; then
    [[ "${CLAUDE_PLAN_CAPABILITY:-}" == "human" ]] && return 0
    die "[$cmd] is human-only — export CLAUDE_PLAN_CAPABILITY=human in the calling shell, then re-run"
  fi
  [[ "${CLAUDE_PLAN_CAPABILITY:-}" == "harness" ]] && return 0
  die "[$cmd] requires CLAUDE_PLAN_CAPABILITY=harness"
}
