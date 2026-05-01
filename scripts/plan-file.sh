#!/usr/bin/env bash
# Dispatcher — exit codes: 0=success 1=error 2=not-found/blocked 3=ambiguous(find-active) 4=malformed(find-active)
# Marker side-effects: reference/markers.md §Operation → markers reverse lookup
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/plan-lib.sh"

[ $# -ge 1 ] || die "Usage: plan-file.sh <command> [args...]"

case "$1" in
  init)                 [ $# -ge 2 ] || die "Usage: plan-file.sh init <plan-file> [mode]"; cmd_init "$2" "${3:-}" ;;
  get-phase)            [ $# -eq 2 ] || die "Usage: plan-file.sh get-phase <plan-file>"; cmd_get_phase "$2" ;;
  set-phase)            [ $# -eq 3 ] || die "Usage: plan-file.sh set-phase <plan-file> <phase>"; cmd_set_phase "$2" "$3" ;;
  append-audit)         [ $# -eq 5 ] || die "Usage: plan-file.sh append-audit <plan-file> <agent> <ACCEPT|REJECT-PASS|BLOCKED-AMBIGUOUS> <summary>"; cmd_append_audit "$2" "$3" "$4" "$5" ;;
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
  record-stop-block)          [ $# -eq 4 ] || die "Usage: plan-file.sh record-stop-block <plan-file> <phase> <reason>"; cmd_record_stop_block "$2" "$3" "$4" ;;
  clear-marker)               [ $# -eq 3 ] || die "Usage: plan-file.sh clear-marker <plan-file> <marker-text>"; cmd_clear_marker "$2" "$3" ;;
  clear-converged)            [ $# -eq 3 ] || die "Usage: plan-file.sh clear-converged <plan-file> <agent>"; cmd_clear_converged "$2" "$3" ;;
  reset-milestone)            [ $# -eq 3 ] || die "Usage: plan-file.sh reset-milestone <plan-file> <agent>"; cmd_reset_milestone "$2" "$3" ;;
  reset-pr-review)            [ $# -eq 2 ] || die "Usage: plan-file.sh reset-pr-review <plan-file>"; cmd_reset_pr_review "$2" ;;
  reset-for-rollback)         [ $# -eq 3 ] || die "Usage: plan-file.sh reset-for-rollback <plan-file> <target-phase>"; cmd_reset_for_rollback "$2" "$3" ;;
  transition)                 [ $# -eq 4 ] || die "Usage: plan-file.sh transition <plan-file> <to-phase> <reason>"; cmd_transition "$2" "$3" "$4" ;;
  commit-phase)               [ $# -eq 3 ] || die "Usage: plan-file.sh commit-phase <plan-file> <commit-message>"; cmd_commit_phase "$2" "$3" ;;
  tier-safe)                  [ $# -ge 3 ] || die "Usage: plan-file.sh tier-safe <plan-file> <task-id>..."; cmd_tier_safe "$2" "${@:3}" ;;
  *) die "Unknown command: $1" ;;
esac
