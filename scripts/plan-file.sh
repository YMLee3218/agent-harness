#!/usr/bin/env bash
# Dispatcher — exit codes: 0=success 1=error 2=not-found/blocked 3=ambiguous(find-active) 4=malformed(find-active)
# Marker side-effects: reference/markers.md §Operation → markers reverse lookup
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/plan-lib.sh"
. "$SCRIPT_DIR/lib/plan-loop-helpers.sh"
. "$SCRIPT_DIR/lib/plan-cmd.sh"

[ $# -ge 1 ] || die "Usage: plan-file.sh <command> [args...]"

# Capability ring gate
case "$1" in
  # Ring A — agent-callable: read-only or narrative-safe
  init|get-phase|find-active|find-latest|context|append-note|tier-safe|is-converged|is-blocked|has-blocked|is-implemented) ;;

  # Ring B — harness or human: state mutators
  set-phase|transition|commit-phase|add-task|update-task|reset-milestone|reset-pr-review|\
  reset-for-rollback|clear-converged|record-verdict|record-verdict-guarded|append-review-verdict|\
  gc-events|gc-verdicts|record-task-completed|record-stop-block|append-audit|mark-implemented|\
  inter-feature-reset)
    require_capability "$1" B
    if [ "$1" = "append-review-verdict" ] && [ $# -ge 2 ] && [ ! -f "$2.critic.lock" ]; then
      die "BLOCKED: ${2##*/}.critic.lock absent — append-review-verdict requires run-critic-loop.sh context"
    fi
    if [ "$1" = "record-verdict" ]; then
      _rv_plan=$(cmd_find_active 2>/dev/null) || _rv_plan=""
      if [ -n "$_rv_plan" ] && [ ! -f "${_rv_plan}.critic.lock" ]; then
        die "BLOCKED: ${_rv_plan##*/}.critic.lock absent — record-verdict requires run-critic-loop.sh context"
      fi
    fi
    ;;

  # Ring C — human-only
  unblock|clear-marker)
    require_capability "$1" C ;;

  *)
    die "[$1] is not registered in any capability ring — add to Ring A/B/C in the case block above" ;;
esac

case "$1" in
  init)                 [ $# -ge 2 ] || die "Usage: plan-file.sh init <plan-file> [mode]"; cmd_init "$2" "${3:-}" ;;
  get-phase)            [ $# -eq 2 ] || die "Usage: plan-file.sh get-phase <plan-file>"; cmd_get_phase "$2" ;;
  set-phase)            [ $# -eq 3 ] || die "Usage: plan-file.sh set-phase <plan-file> <phase>"; cmd_set_phase "$2" "$3" ;;
  append-audit)         [ $# -eq 5 ] || die "Usage: plan-file.sh append-audit <plan-file> <agent> <ACCEPT|ACCEPT-OVERRIDE|REJECT-PASS|BLOCKED-AMBIGUOUS> <summary>"; cmd_append_audit "$2" "$3" "$4" "$5" ;;
  append-note)          [ $# -eq 3 ] || die "Usage: plan-file.sh append-note <plan-file> <note>"; cmd_append_note "$2" "$3" ;;
  find-active)          cmd_find_active ;;
  find-latest)          cmd_find_latest ;;
  record-verdict)         cmd_record_verdict ;;
  record-verdict-guarded)   cmd_record_verdict_guarded ;;
  record-task-completed)  cmd_record_task_completed ;;
  context)              cmd_context ;;
  gc-events)            cmd_gc_events ;;
  gc-verdicts)          [ $# -eq 2 ] || die "Usage: plan-file.sh gc-verdicts <plan-file>"; cmd_gc_verdicts "$2" ;;
  add-task)             [ $# -eq 4 ] || die "Usage: plan-file.sh add-task <plan-file> <task-id> <layer>"; cmd_add_task "$2" "$3" "$4" ;;
  update-task)          [ $# -ge 4 ] || die "Usage: plan-file.sh update-task <plan-file> <task-id> <status> [commit-sha]"; cmd_update_task "$2" "$3" "$4" "${5:--}" ;;
  append-review-verdict) [ $# -eq 4 ] || die "Usage: plan-file.sh append-review-verdict <plan-file> <agent> PASS|FAIL"; cmd_append_review_verdict "$2" "$3" "$4" ;;
  record-stop-block)    [ $# -eq 4 ] || die "Usage: plan-file.sh record-stop-block <plan-file> <phase> <reason>"; cmd_record_stop_block "$2" "$3" "$4" ;;
  clear-marker)         [ $# -eq 3 ] || die "Usage: plan-file.sh clear-marker <plan-file> <marker-text>"; cmd_clear_marker "$2" "$3" ;;
  unblock)              [ $# -eq 2 ] || die "Usage: plan-file.sh unblock <agent>"; cmd_unblock "$2" ;;
  clear-converged)      [ $# -eq 3 ] || die "Usage: plan-file.sh clear-converged <plan-file> <agent>"; cmd_clear_converged "$2" "$3" ;;
  reset-milestone)      [ $# -eq 3 ] || die "Usage: plan-file.sh reset-milestone <plan-file> <agent>"; cmd_reset_milestone "$2" "$3" ;;
  reset-pr-review)      [ $# -eq 2 ] || die "Usage: plan-file.sh reset-pr-review <plan-file>"; cmd_reset_pr_review "$2" ;;
  reset-for-rollback)   [ $# -eq 3 ] || die "Usage: plan-file.sh reset-for-rollback <plan-file> <target-phase>"; cmd_reset_phase_state "$2" "$3" ;;
  transition)           [ $# -eq 4 ] || die "Usage: plan-file.sh transition <plan-file> <to-phase> <reason>"; cmd_transition "$2" "$3" "$4" ;;
  commit-phase)         [ $# -eq 3 ] || die "Usage: plan-file.sh commit-phase <plan-file> <commit-message>"; cmd_commit_phase "$2" "$3" ;;
  tier-safe)            [ $# -ge 3 ] || die "Usage: plan-file.sh tier-safe <plan-file> <task-id>..."; cmd_tier_safe "$2" "${@:3}" ;;
  is-converged)         [ $# -eq 4 ] || die "Usage: plan-file.sh is-converged <plan-file> <phase> <agent>"; cmd_is_converged "$2" "$3" "$4" ;;
  is-implemented)       [ $# -eq 3 ] || die "Usage: plan-file.sh is-implemented <plan-file> <feat-slug>"; cmd_is_implemented "$2" "$3" ;;
  mark-implemented)     [ $# -eq 3 ] || die "Usage: plan-file.sh mark-implemented <plan-file> <feat-slug>"; cmd_mark_implemented "$2" "$3" ;;
  is-blocked|has-blocked) [ $# -ge 2 ] || die "Usage: plan-file.sh is-blocked <plan-file> [kind]"; cmd_is_blocked "$2" "${3:-}" ;;
  inter-feature-reset)  [ $# -eq 2 ] || die "Usage: plan-file.sh inter-feature-reset <plan-file>"; cmd_inter_feature_reset "$2" ;;
  *) die "Unknown command: $1" ;;
esac
