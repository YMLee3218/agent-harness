#!/usr/bin/env bash
# Plan state-management commands: init, phase transitions, find-active.
# Source this file; do not execute directly.
set -euo pipefail
[[ -n "${_PLAN_CMD_STATE_LOADED:-}" ]] && return 0
_PLAN_CMD_STATE_LOADED=1

_PLAN_CMD_STATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${_PLAN_LIB_LOADED:-}" ]] || . "$_PLAN_CMD_STATE_DIR/plan-lib.sh"

cmd_init() {
  local plan_file="$1"
  local mode="${2:-}"
  local slug
  slug=$(basename "$plan_file" .md)
  if ! [[ "$slug" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]]; then
    die "cmd_init: plan slug '${slug}' contains illegal characters — must match ^[a-z0-9][a-z0-9_-]{0,63}$"
  fi
  if [ -f "$plan_file" ]; then
    if [ -n "$mode" ]; then
      local existing
      existing=$(awk '/^mode:/{print $2; exit}' "$plan_file" 2>/dev/null || true)
      if [ -n "$existing" ] && [ "$existing" != "$mode" ]; then
        echo "[plan-file] init: existing plan has mode='${existing}', requested='${mode}' — keeping existing" >&2
      fi
    fi
    echo "[plan-file] init: $plan_file already exists — skipping" >&2
    sc_ensure_dir "$plan_file" || die "ERROR: sidecar dir setup failed for $plan_file"
    return 0
  fi
  mkdir -p "$(dirname "$plan_file")"
  {
    printf -- '---\nfeature: %s\nphase: brainstorm\nschema: 2\n' "$slug"
    [ -n "$mode" ] && printf 'mode: %s\n' "$mode"
    printf -- '---\n\n## Vision\n\n## Scenarios\n\n## Test Manifest\n\n## Phase\nbrainstorm\n\n## Phase Transitions\n- brainstorm → (initial)\n\n## Critic Verdicts\n\n## Task Ledger\n\n## Integration Failures\n\n## Verdict Audits\n\n## Open Questions\n'
  } > "$plan_file"
  sc_ensure_dir "$plan_file" || die "ERROR: sidecar dir setup failed for $plan_file"
}

cmd_get_phase() {
  local plan_file="$1"
  require_file "$plan_file"
  local phase
  phase=$(awk '/^## Phase$/{found=1; next} found && /^[A-Za-z]/{print; exit} found && /^##/{exit}' "$plan_file" \
          | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  if [ -z "$phase" ]; then
    echo "ERROR: '## Phase' section not found or empty in $plan_file" >&2
    exit 2
  fi
  echo "$phase"
}

cmd_set_phase() {
  local plan_file="$1" phase="$2"
  require_file "$plan_file"
  _check_schema "$plan_file"
  local valid=0
  for p in $VALID_PHASES; do
    [ "$p" = "$phase" ] && valid=1 && break
  done
  [ "$valid" -eq 1 ] || die "invalid phase: $phase (must be one of: $VALID_PHASES)"
  _awk_replace_phase_body "$plan_file" "$phase"
}

_read_phase_quick() {
  local pf="$1" p=""
  p=$(awk '/^## Phase$/{found=1; next} found && /^[A-Za-z]/{print; exit}' "$pf" 2>/dev/null \
    | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]' || true)
  echo "$p"
}

cmd_find_active() {
  local plans_dir="${CLAUDE_PROJECT_DIR:-$PWD}/plans"

  if [ -n "${CLAUDE_PLAN_FILE:-}" ]; then
    if [ -f "$CLAUDE_PLAN_FILE" ]; then
      local envphase
      envphase=$(_read_phase_quick "$CLAUDE_PLAN_FILE")
      if [ -n "$envphase" ] && [ "$envphase" != "done" ]; then
        echo "$CLAUDE_PLAN_FILE"
        return 0
      fi
      if [ "$envphase" = "done" ]; then
        echo "[plan-file] CLAUDE_PLAN_FILE=$CLAUDE_PLAN_FILE is done; falling through to other strategies. Unset or pick a new plan if unintentional." >&2
      fi
    fi
  fi

  [ -d "$plans_dir" ] || { exit 2; }

  local branch
  branch=$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" symbolic-ref --short HEAD 2>/dev/null \
           | sed 's|^feature/||; s|/|-|g; s|[^A-Za-z0-9_-]|-|g' || true)
  if [ -n "$branch" ] && [ -f "$plans_dir/${branch}.md" ]; then
    local bphase
    bphase=$(_read_phase_quick "$plans_dir/${branch}.md")
    if [ -n "$bphase" ] && [ "$bphase" != "done" ]; then
      echo "$plans_dir/${branch}.md"
      return 0
    fi
  fi

  local found="" count=0 malformed=0
  while IFS= read -r -d '' f; do
    # Validate slug: skip files whose name does not match the enforced pattern
    local _fn; _fn=$(basename "$f" .md)
    if ! [[ "$_fn" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]]; then
      echo "[plan-file] WARNING: skipping plan file with non-slug name: $f" >&2
      continue
    fi
    local phase
    phase=$(_read_phase_quick "$f")
    if [ -z "$phase" ]; then
      echo "[plan-file] ERROR: plan file exists but phase cannot be read: $f (missing ## Phase section)" >&2
      malformed=$((malformed + 1))
    elif [ "$phase" != "done" ]; then
      count=$((count + 1))
      [ -z "$found" ] && found="$f"
    fi
  done < <(find "$plans_dir" -maxdepth 1 -name '*.md' -print0 2>/dev/null | sort -z)
  if [ "$malformed" -gt 0 ] && [ "$count" -eq 0 ]; then
    echo "ERROR: ${malformed} plan file(s) exist but phase is unreadable — repair the ## Phase section before stopping." >&2
    exit 4
  elif [ "$count" -eq 0 ]; then
    exit 2
  elif [ "$count" -ge 2 ]; then
    echo "ERROR: ${count} active plan files found with no CLAUDE_PLAN_FILE or branch-slug match. Set CLAUDE_PLAN_FILE=plans/{slug}.md or align branch name with plan file name." >&2
    exit 3
  else
    echo "[plan-file] WARNING: falling back to newest plan ($found). Set CLAUDE_PLAN_FILE or use worktrees to disambiguate when running multiple features in parallel." >&2
    echo "$found"
  fi
}

# _find_latest_by_mtime DIR PATTERN — POSIX-safe newest file by mtime.
# Avoids ls -t parsing (broken for filenames with newlines/spaces).
_find_latest_by_mtime() {
  local _dir="$1" _pat="$2"
  if command -v find >/dev/null 2>&1 && find "$_dir" -maxdepth 1 -name "$_pat" -printf '%T@ %p\n' \
      >/dev/null 2>&1; then
    # GNU find with -printf
    find "$_dir" -maxdepth 1 -name "$_pat" -printf '%T@ %p\n' 2>/dev/null | \
      sort -rn | head -1 | cut -d' ' -f2-
  else
    # macOS stat fallback
    find "$_dir" -maxdepth 1 -name "$_pat" -type f -exec stat -f '%m %N' {} \; 2>/dev/null | \
      sort -rn | head -1 | cut -d' ' -f2-
  fi
}

cmd_find_latest() {
  local plans_dir="${CLAUDE_PROJECT_DIR:-$PWD}/plans"
  [ -d "$plans_dir" ] || return 2
  local f _fn
  f=$(_find_latest_by_mtime "$plans_dir" '*.md' || true)
  [ -z "$f" ] && return 2
  _fn=$(basename "$f" .md)
  if ! [[ "$_fn" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]]; then
    echo "[plan-file] WARNING: find-latest: skipping file with non-slug name: $f" >&2
    return 2
  fi
  echo "$f"
}

# _require_phase PLAN_FILE LABEL → echoes phase or dies
_require_phase() {
  local _plan="$1" _label="$2" _phase
  _phase=$(cmd_get_phase "$_plan" 2>/dev/null) || die "$_label: cannot read phase from $_plan"
  [ -z "$_phase" ] || [ "$_phase" = "unknown" ] && die "$_label: phase unknown for $_plan"
  echo "$_phase"
}

cmd_transition() {
  local plan_file="$1" to_phase="$2" reason="$3"
  require_file "$plan_file"
  local from_phase
  from_phase=$(_require_phase "$plan_file" "cmd_transition") || exit $?
  cmd_set_phase "$plan_file" "$to_phase"
  _append_to_phase_transitions "$plan_file" "- ${from_phase} → ${to_phase} (reason: ${reason})"
}

cmd_commit_phase() {
  local plan_file="$1" message="$2"
  git add "$plan_file"
  git diff --cached --quiet || git commit -m "$message"
}
