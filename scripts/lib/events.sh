#!/usr/bin/env bash
# events.sh — append-only fact log + pure recomputation of stage state.
# Source this file; do not execute directly.
#
# Single source of truth: events/{scope}.jsonl under plans/{slug}.state/.
# Facts only (verdict / audit-reject / human-clear / block / milestone / task).
# All stage state (is-converged / is-implemented / ceiling-reached / is-blocked)
# is a PURE FUNCTION of the log + the working tree — never stored.
#
# Authority for ordering is APPEND ORDER (line position), not ts: the sole ts
# generator is whole-second, so same-second ties are real; line position is the
# total order (single-writer-per-line, append-only). See §operating invariant 12.
set -euo pipefail
[[ -n "${_EVENTS_LOADED:-}" ]] && return 0
_EVENTS_LOADED=1

_EVENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${_SIDECAR_LOADED:-}" ]] || . "$_EVENTS_DIR/sidecar.sh"

EV_CEILING_DEFAULT=100

# ── scope keys (invariant 8: layer-qualified + reserved sentinels) ──────────────
# Reserved singleton/aggregate scopes. Real unit keys must NOT match ^__[a-z]+__$.
_EV_RESERVED_RE='^__[a-z]+__$'
_EV_RESERVED_SCOPES="__brainstorm__ __cross__ __integration__ __tasks__ __legacy__"

# _ev_is_reserved SCOPE → rc0 if SCOPE is a reserved sentinel scope.
_ev_is_reserved() {
  case " $_EV_RESERVED_SCOPES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# scope UNIT → echoes the scope key for UNIT (fail-closed on sentinel collision).
# Reserved sentinels pass through; real units must be layer-qualified ({layer}-{slug})
# and must not collide with the reserved ^__[a-z]+__$ namespace.
scope() {
  local _u="$1"
  if _ev_is_reserved "$_u"; then printf '%s\n' "$_u"; return 0; fi
  if [[ "$_u" =~ $_EV_RESERVED_RE ]]; then
    echo "[events] FATAL: unit '${_u}' collides with reserved sentinel namespace ^__[a-z]+__\$" >&2
    return 2
  fi
  [[ -n "$_u" ]] || { echo "[events] FATAL: empty unit key" >&2; return 2; }
  printf '%s\n' "$_u"
}

# ev_file PLAN SCOPE → absolute path to events/{scope}.jsonl
ev_file() { sc_path "$1" "events/${2}.jsonl"; }

# ev_ensure_dir PLAN — ensure events/ subdir exists (symlink-guarded like sc_ensure_dir).
ev_ensure_dir() {
  sc_ensure_dir "$1" || return 1
  local _d; _d="$(sc_dir "$1")/events" || return 1
  if [[ -L "$_d" ]]; then
    echo "[events] FATAL: events subdir ${_d} is a symlink — refusing redirected path" >&2; return 2
  fi
  [[ -d "$_d" ]] || mkdir -p "$_d"
}

# Per-scope line threshold above which an append triggers GC. Override via env.
EV_GC_THRESHOLD="${CLAUDE_EVENTS_GC_THRESHOLD:-500}"
# Newest verdict/audit-reject records kept PER STAGE during GC. Per-stage (not per-hash) so
# input-hash wiggling cannot defeat the bound; a live streak (≥2) is always among the newest
# records because any FAIL breaks the streak H-agnostically, so older PASS beyond it are inert.
EV_GC_KEEP_N="${CLAUDE_EVENTS_GC_KEEP_N:-50}"

# ev_gc PLAN SCOPE — truncate events/{scope}.jsonl to a safe floor (invariant 1):
# keep the last N verdict/audit-reject PER STAGE AND every other record (block/human-clear/
# milestone/task) in original line order. Preserves live streaks and all unresolved blocks;
# only old verdict/audit history is dropped, even under hash-wiggling. Runs as a SEPARATE
# locked rewrite — never nested inside an append lock (no reentrant self-deadlock).
ev_gc() {
  local _plan="$1" _scope="$2" _path; _path=$(ev_file "$_plan" "$_scope") || return 1
  [[ -f "$_path" ]] || return 0
  _sc_rewrite_jsonl "$_path" \
    '[ to_entries[] | .value + {__i:.key} ] as $rows
     | ( [ $rows[] | select(.type=="verdict" or .type=="audit-reject") ]
         | group_by(.stage) | map(.[-($n):][]) ) as $kv
     | ( [ $rows[] | select((.type=="verdict" or .type=="audit-reject")|not) ] ) as $ko
     | ($kv + $ko) | sort_by(.__i) | .[] | del(.__i)' \
    "events-gc" --slurp --argjson n "$EV_GC_KEEP_N" 2>/dev/null || true
}

# ev_append PLAN SCOPE RECORD_JSON — append one fact line to events/{scope}.jsonl.
# Per-scope mkdir spin-lock (reused from sidecar); single-line atomic append, no RMW.
# After the append lock releases, GC the scope file if it crossed the size threshold (the GC
# rewrite re-acquires the same lock cleanly — sequential, never nested → no self-deadlock).
ev_append() {
  local _plan="$1" _scope="$2" _rec="$3" _path
  ev_ensure_dir "$_plan" || return 1
  _path=$(ev_file "$_plan" "$_scope") || return 1
  sc_append_jsonl "$_path" "$_rec" || return 1
  local _lines; _lines=$(wc -l < "$_path" 2>/dev/null || echo 0)
  [[ "${_lines:-0}" -gt "$EV_GC_THRESHOLD" ]] && ev_gc "$_plan" "$_scope"
  return 0
}

# ev_record_verdict PLAN UNIT STAGE INPUT_HASH VERDICT [CATEGORY] — append a verdict fact.
# input_hash is FROZEN at call time (the snapshot the critic judged) — never re-derived.
ev_record_verdict() {
  local _plan="$1" _unit="$2" _stage="$3" _H="$4" _verdict="$5" _cat="${6:-}" _scope _ts
  _scope=$(scope "$_unit") || return 2
  _ts=$(_iso_timestamp)
  ev_append "$_plan" "$_scope" "$(jq -nc \
    --arg ts "$_ts" --arg unit "$_unit" --arg stage "$_stage" --arg ih "$_H" \
    --arg v "$_verdict" --arg cat "$_cat" \
    '{ts:$ts,type:"verdict",unit:$unit,stage:$stage,input_hash:$ih,verdict:$v,category:$cat}')"
}

# _ev_block_open PLAN UNIT STAGE KIND → rc0 if an open (uncleared) block of this exact
# (unit,stage,kind) exists. Used for invariant-3 dedup before appending a block fact.
_ev_block_open() {
  local _plan="$1" _unit="$2" _stage="$3" _kind="$4" _scope _path _r
  _scope=$(scope "$_unit") || return 1
  _path=$(_ev_scope_path "$_plan" "$_scope")
  _r=$(jq -sr --arg unit "$_unit" --arg stage "$_stage" --arg kind "$_kind" '
    [ .[] | select(.unit==$unit and .stage==$stage) ] as $rows
    | ( [ range(0;($rows|length)) as $i | select($rows[$i].type=="block" and $rows[$i].kind==$kind) | $i ] | last ) as $lb
    | ( [ range(0;($rows|length)) as $i | select($rows[$i].type=="human-clear" and $rows[$i].kind==$kind) | $i ] | last ) as $lc
    | if ($lb != null) and ($lc == null or $lb > $lc) then "yes" else "no" end
  ' "$_path" 2>/dev/null || echo "no")
  [[ "$_r" == "yes" ]]
}

# ev_record_block PLAN UNIT STAGE KIND DETAIL — append a block fact, deduped (invariant 3):
# skip when an open (unit,stage,kind) block already exists. Returns 0 either way.
ev_record_block() {
  local _plan="$1" _unit="$2" _stage="$3" _kind="$4" _detail="${5:-}" _scope _ts
  [[ -n "$_unit" && -n "$_stage" && -n "$_kind" ]] || return 0
  _ev_block_open "$_plan" "$_unit" "$_stage" "$_kind" && return 0
  _scope=$(scope "$_unit") || return 2
  _ts=$(_iso_timestamp)
  ev_append "$_plan" "$_scope" "$(jq -nc \
    --arg ts "$_ts" --arg unit "$_unit" --arg stage "$_stage" --arg kind "$_kind" --arg detail "$_detail" \
    '{ts:$ts,type:"block",unit:$unit,stage:$stage,kind:$kind,detail:$detail}')"
}

# ev_record_human_clear PLAN UNIT STAGE WHAT [KIND] — append a human-clear fact.
# what=block clears a block of KIND (newest-clear-wins per kind); what=ceiling uses KIND=null.
ev_record_human_clear() {
  local _plan="$1" _unit="$2" _stage="$3" _what="$4" _kind="${5:-}" _scope _ts
  [[ -n "$_unit" && -n "$_stage" ]] || return 0
  _scope=$(scope "$_unit") || return 2
  _ts=$(_iso_timestamp)
  local _kindjson='null'; [[ -n "$_kind" ]] && _kindjson="$(jq -nc --arg k "$_kind" '$k')"
  ev_append "$_plan" "$_scope" "$(jq -nc \
    --arg ts "$_ts" --arg unit "$_unit" --arg stage "$_stage" --arg what "$_what" --argjson kind "$_kindjson" \
    '{ts:$ts,type:"human-clear",unit:$unit,stage:$stage,what:$what,kind:$kind}')"
}

# ev_record_audit_reject PLAN UNIT STAGE INPUT_HASH REASON — append an audit-reject fact.
# Carries the frozen input_hash so it filters by H in ev_streak (input-change = free reset).
# Breaks the streak at H (pass-audit overrode the 2nd PASS).
ev_record_audit_reject() {
  local _plan="$1" _unit="$2" _stage="$3" _H="$4" _reason="${5:-}" _scope _ts
  [[ -n "$_unit" && -n "$_stage" ]] || return 0
  _scope=$(scope "$_unit") || return 2
  _ts=$(_iso_timestamp)
  ev_append "$_plan" "$_scope" "$(jq -nc \
    --arg ts "$_ts" --arg unit "$_unit" --arg stage "$_stage" --arg ih "$_H" --arg reason "$_reason" \
    '{ts:$ts,type:"audit-reject",unit:$unit,stage:$stage,input_hash:$ih,reason:$reason}')"
}

# ev_list_scopes PLAN — echo every events scope name present on disk (basename minus .jsonl).
ev_list_scopes() {
  local _d; _d="$(sc_dir "$1")/events" 2>/dev/null || return 0
  [[ -d "$_d" ]] || return 0
  local _f
  for _f in "$_d"/*.jsonl; do [[ -e "$_f" ]] || continue; basename "$_f" .jsonl; done
}

# ev_unblock_scope PLAN SCOPE — operator clear: append a human-clear for every open (stage,kind)
# block and a human-clear(ceiling) for every stage with verdicts in this scope. Over-clearing is
# harmless (a human-clear newer than any block/crossing simply makes the predicate false).
ev_unblock_scope() {
  local _plan="$1" _scope="$2" _path; _path=$(ev_file "$_plan" "$_scope") || return 0
  [[ -f "$_path" ]] || return 0
  local _stage _kind
  while IFS=$'\t' read -r _stage _kind; do
    [[ -n "$_stage" ]] && ev_record_human_clear "$_plan" "$_scope" "$_stage" block "$_kind"
  done < <(jq -rs '[.[]|select(.type=="block")]|group_by([.stage,.kind])|.[]|[.[0].stage,(.[0].kind//"")]|@tsv' "$_path" 2>/dev/null || true)
  while IFS= read -r _stage; do
    [[ -n "$_stage" ]] && ev_record_human_clear "$_plan" "$_scope" "$_stage" ceiling ""
  done < <(jq -rs '[.[]|select(.type=="verdict")]|group_by(.stage)|.[]|.[0].stage' "$_path" 2>/dev/null || true)
}

# ev_unblock_all PLAN — clear all events blocks + ceilings across every scope (plan-wide unblock).
ev_unblock_all() {
  local _plan="$1" _s
  while IFS= read -r _s; do [[ -n "$_s" ]] && ev_unblock_scope "$_plan" "$_s"; done < <(ev_list_scopes "$_plan")
}

# ev_record_milestone PLAN UNIT STAGE — append a milestone fact (streak/ceiling recompute floor).
ev_record_milestone() {
  local _plan="$1" _unit="$2" _stage="$3" _scope _ts
  [[ -n "$_unit" && -n "$_stage" ]] || return 0
  _scope=$(scope "$_unit") || return 2
  _ts=$(_iso_timestamp)
  ev_append "$_plan" "$_scope" "$(jq -nc \
    --arg ts "$_ts" --arg unit "$_unit" --arg stage "$_stage" \
    '{ts:$ts,type:"milestone",unit:$unit,stage:$stage}')"
}

# ── input hashing (generalized from _spec_fingerprint) ──────────────────────────
# _ev_sha STREAM → sha256 of stdin (sha256sum/shasum); echoes empty on no tool.
_ev_sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 2>/dev/null | awk '{print $1}'
  else return 3; fi
}

# _hash_file_list — read newline-separated file paths on stdin, hash sorted
# relative paths + working-tree contents. Sentinels preserved:
#   "empty"       — no input files (fail-closed: never counts toward a streak)
#   "no-sha-tool" — SHA tool unavailable (preflight halts before this in practice)
# Paths are made relative to CLAUDE_PROJECT_DIR so the hash is location-independent.
_hash_file_list() {
  local _proj="${CLAUDE_PROJECT_DIR:-}"
  local _files _f _rel _sorted _existing=""
  _files=$(cat)
  # Keep only files that EXIST in the working tree — a non-existent (fallback) path is
  # not authored input. Path-set membership still changes the hash on add/delete; an
  # empty existing-set yields the "empty" sentinel (fail-closed, never counts to streak).
  while IFS= read -r _f; do
    [[ -n "$_f" && -f "$_f" ]] && _existing="${_existing}${_f}"$'\n'
  done < <(printf '%s\n' "$_files" | sed '/^$/d')
  _sorted=$(printf '%s' "$_existing" | sed '/^$/d' | LC_ALL=C sort -u)
  [[ -z "$_sorted" ]] && { echo "empty"; return 0; }
  local _fp _rc=0
  _fp=$( {
    while IFS= read -r _f; do
      [[ -z "$_f" ]] && continue
      _rel="$_f"; [[ -n "$_proj" ]] && _rel="${_f#"$_proj"/}"
      printf '%s\n' "$_rel"
      cat "$_f" 2>/dev/null || true
    done <<< "$_sorted"
  } | _ev_sha ) || _rc=$?
  if [[ $_rc -eq 3 || -z "$_fp" ]]; then echo "no-sha-tool"; return 0; fi
  echo "$_fp"
}

# ── resolvers (unit → spec/src/test paths) ──────────────────────────────────────
# _ev_unit_layer_slug UNIT → echoes "layer slug" or rc1 if not layer-qualified.
_ev_unit_layer_slug() {
  case "$1" in
    domain-*)         printf 'domain %s\n' "${1#domain-}" ;;
    infrastructure-*) printf 'infrastructure %s\n' "${1#infrastructure-}" ;;
    features-*)       printf 'features %s\n' "${1#features-}" ;;
    *) return 1 ;;
  esac
}

# _ev_stage_of_agent AGENT → echoes the logical stage for a critic agent.
_ev_stage_of_agent() {
  case "$1" in
    critic-feature) echo brainstorm ;;
    critic-spec)    echo spec ;;
    critic-cross)   echo cross ;;
    critic-test)    echo test ;;
    critic-code)    echo code ;;
    critic-quality) echo quality ;;
    *) echo "$1" ;;
  esac
}

# _ev_find_spec_path SLUG — self-contained spec resolver (mirrors llm-runner find_spec_path)
# so events.sh has no cross-file load-order dependency.
_ev_find_spec_path() {
  local _slug="$1" _proj="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-}}" _sp
  for _sp in "${_proj}/features/${_slug}/spec.md" "${_proj}/domain/${_slug}/spec.md" \
             "${_proj}/infrastructure/${_slug}/spec.md" "${_proj}/src/features/${_slug}/spec.md" \
             "${_proj}/src/domain/${_slug}/spec.md" "${_proj}/src/infrastructure/${_slug}/spec.md"; do
    [[ -f "$_sp" ]] && { echo "$_sp"; return; }
  done
  echo "${_proj}/features/${_slug}/spec.md"
}

# _ev_qualified_unit KEY — echoes a layer-qualified unit key. A key already starting with
# a layer prefix (domain-/infrastructure-/features-) passes through; a bare feature slug
# (e.g. add-todo) is prefixed features-. Feature slugs are {verb}-{noun}, so they never
# collide with the layer prefixes in practice (invariant 8).
_ev_qualified_unit() {
  if _ev_unit_layer_slug "$1" >/dev/null 2>&1; then printf '%s\n' "$1"; else printf 'features-%s\n' "$1"; fi
}

# _ev_unit_spec_path UNIT — echoes the unit's spec.md path (canonical, both layouts).
_ev_unit_spec_path() {
  local _ls _layer _slug
  _ls=$(_ev_unit_layer_slug "$1") || { _ev_find_spec_path "$1"; return; }
  read -r _layer _slug <<< "$_ls"
  local _proj="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-}}" _p
  for _p in "${_proj}/${_layer}/${_slug}/spec.md" "${_proj}/src/${_layer}/${_slug}/spec.md"; do
    [[ -f "$_p" ]] && { echo "$_p"; return; }
  done
  echo "${_proj}/${_layer}/${_slug}/spec.md"
}

# _ev_glob_unit_files LAYER SLUG SUBROOT — list existing src/test files for a concept,
# accepting kebab/snake + directory/single-file layouts (additive, never narrowing).
_ev_glob_unit_files() {
  local _layer="$1" _slug="$2" _root="$3"
  local _snake _kebab; _snake=$(printf '%s' "$_slug" | tr '-' '_'); _kebab=$(printf '%s' "$_slug" | tr '_' '-')
  local _proj="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-}}" _d _form
  for _form in "$_snake" "$_kebab"; do
    for _d in "${_proj}/${_root}/${_layer}/${_form}" "${_proj}/src/${_root}/${_layer}/${_form}"; do
      [[ -d "$_d" ]] && find "$_d" -type f -not -path '*/__pycache__/*' -not -name '*.pyc' 2>/dev/null
    done
    # single-file layouts
    find "${_proj}/${_root}/${_layer}" "${_proj}/src/${_layer}" -maxdepth 1 -type f \
      \( -name "${_form}.*" -o -name "test_${_form}.*" -o -name "${_form}_test.*" \) 2>/dev/null || true
  done | LC_ALL=C sort -u
}

# _ev_unit_src_files UNIT — list source files for the unit.
_ev_unit_src_files() {
  local _ls _layer _slug; _ls=$(_ev_unit_layer_slug "$1") || return 0
  read -r _layer _slug <<< "$_ls"
  _ev_glob_unit_files "$_layer" "$_slug" "src"
}

# _ev_unit_test_files UNIT — list test files for the unit (path-rule convention,
# commit-independent; distinct from _recent_test_files which uses git history).
_ev_unit_test_files() {
  local _ls _layer _slug; _ls=$(_ev_unit_layer_slug "$1") || return 0
  read -r _layer _slug <<< "$_ls"
  _ev_glob_unit_files "$_layer" "$_slug" "tests"
}

# _ev_dep_spec_paths UNIT — 1-level Depends-on closure: spec paths this unit's spec
# declares as dependencies. Declaration-based (deterministic); grep is a verification
# gate elsewhere, never a hash input.
_ev_dep_spec_paths() {
  local _spec; _spec=$(_ev_unit_spec_path "$1")
  [[ -f "$_spec" ]] || return 0
  local _deps _d
  _deps=$(grep -iE '^[[:space:]]*Depends-on:' "$_spec" 2>/dev/null \
    | sed 's/^[[:space:]]*[Dd]epends-on:[[:space:]]*//' | tr ',' ' ')
  for _d in $_deps; do
    _d=$(printf '%s' "$_d" | tr -dc 'a-z0-9-')
    [[ -z "$_d" ]] && continue
    # Resolve dep concept to a spec path across domain/infra/feature canonical layouts.
    _ev_find_spec_path "$_d"
  done
}

# _ev_docs_files — docs/*.md under the project.
_ev_docs_files() {
  local _proj="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-}}"
  [[ -d "${_proj}/docs" ]] && find "${_proj}/docs" -name '*.md' 2>/dev/null || true
}

# _ev_all_specs — every authored spec.md (matches _spec_fingerprint's scope).
_ev_all_specs() {
  local _proj="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-}}"
  [[ -n "$_proj" && -d "$_proj" ]] || return 0
  find "$_proj" -name 'spec.md' \
    -not -path '*/.git/*' -not -path '*/plans/*' \
    -not -path "${_proj}/.claude/worktrees/*" -not -path '*/node_modules/*' -not -path '*/.venv/*' \
    2>/dev/null || true
}

# _ev_all_src_test — all authored source + test files (integration/cross input).
_ev_all_src_test() {
  local _proj="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-}}"
  [[ -n "$_proj" && -d "$_proj" ]] || return 0
  local _r
  for _r in src tests; do
    [[ -d "${_proj}/${_r}" ]] && find "${_proj}/${_r}" -type f \
      -not -path '*/.git/*' -not -path '*/__pycache__/*' -not -name '*.pyc' 2>/dev/null || true
  done
}

# _ev_brainstorm_input — plan.md AUTHORED sections only (allowlist, fail-safe) + docs.
# Allowlist (not denylist): only ## Vision / ## Scenarios / ## Test Manifest are hashed;
# every other section is excluded by default so machine-mutated sections never enter the
# hash (else brainstorm self-reference deadlocks). See §단계별 입력.
_ev_brainstorm_authored() {
  local _plan_md="$1" _tmp
  _tmp=$(mktemp)
  awk '
    /^## / {
      sec=$0
      keep=(sec=="## Vision" || sec=="## Scenarios" || sec=="## Test Manifest")
      next
    }
    keep { print }
  ' "$_plan_md" > "$_tmp" 2>/dev/null || true
  echo "$_tmp"
}

# _stage_input_hash PLAN UNIT STAGE → echoes the content-addressed input hash for the
# (unit,stage) pair, computed from the WORKING TREE (HEAD-agnostic — see §working-tree).
_stage_input_hash() {
  local _plan="$1" _unit="$2" _stage="$3"
  case "$_stage" in
    brainstorm)
      local _plan_md _au _h
      _plan_md="${_plan}"
      _au=$(_ev_brainstorm_authored "$_plan_md")
      _h=$( { echo "$_au"; _ev_docs_files; } | _hash_file_list )
      rm -f "$_au"
      printf '%s\n' "$_h" ;;
    spec)
      { _ev_docs_files; _ev_unit_spec_path "$_unit"; } | _hash_file_list ;;
    cross)
      { _ev_all_specs; _ev_docs_files; } | _hash_file_list ;;
    test)
      { _ev_unit_spec_path "$_unit"; _ev_unit_test_files "$_unit"; } | _hash_file_list ;;
    code)
      { _ev_unit_spec_path "$_unit"; _ev_unit_test_files "$_unit"; _ev_unit_src_files "$_unit"; \
        _ev_dep_spec_paths "$_unit"; } | _hash_file_list ;;
    quality)
      { _ev_unit_src_files "$_unit"; _ev_unit_spec_path "$_unit"; } | _hash_file_list ;;
    integration)
      { _ev_all_src_test; _ev_all_specs; } | _hash_file_list ;;
    *) echo "empty" ;;
  esac
}

# ── pure recomputation over events/{scope}.jsonl ────────────────────────────────
# All readers take UNIT + STAGE and read ONLY scope(UNIT)'s file. Ordering authority
# is line position (jq -s preserves input order). ts is display/approximation only.

# _ev_rows PLAN SCOPE — emit the scope file path (or empty). Internal helper.
_ev_scope_path() {
  local _p; _p=$(ev_file "$1" "$2") || return 1
  [[ -f "$_p" ]] && printf '%s\n' "$_p" || printf '%s\n' "/dev/null"
}

# ev_streak PLAN UNIT STAGE INPUT_HASH → prints streak count (PASS@H run, newest-first,
# milestone-bounded). FAIL/PARSE_ERROR stop H-agnostically; audit-reject@H stops;
# audit-reject@!=H is skipped (not a stop). See §계산.
ev_streak() {
  local _plan="$1" _unit="$2" _stage="$3" _H="$4" _scope _path
  _scope=$(scope "$_unit") || return 2
  _path=$(_ev_scope_path "$_plan" "$_scope")
  jq -sr --arg unit "$_unit" --arg stage "$_stage" --arg H "$_H" '
    [ .[] | select((.unit==$unit) and (.stage==$stage)) ] as $rows
    | ( [ range(0; ($rows|length)) as $i | select($rows[$i].type=="milestone") | $i ] | last ) as $lm
    | ( if $lm == null then $rows else $rows[($lm+1):] end ) as $win
    | reduce ($win | reverse | .[]) as $r ({stop:false,count:0};
        if .stop then .
        elif ($r.type=="verdict" and $r.verdict=="PASS" and $r.input_hash==$H) then .count += 1
        elif ($r.type=="verdict" and ($r.verdict=="FAIL" or $r.verdict=="PARSE_ERROR")) then .stop=true
        elif ($r.type=="audit-reject" and $r.input_hash==$H) then .stop=true
        else . end )
    | .count
  ' "$_path" 2>/dev/null || echo 0
}

# ev_ceiling_reached PLAN UNIT STAGE → rc0 if ceiling reached (RUN→BLOCKED:ceiling), rc1 otherwise.
# count(verdict in current window) > CEILING AND no human-clear(ceiling) later than the
# crossing verdict. Input-hash-agnostic (total attempts) — the real infinite-loop backstop.
ev_ceiling_reached() {
  local _plan="$1" _unit="$2" _stage="$3" _scope _path _ceil
  _ceil=$(_ev_ceiling)
  _scope=$(scope "$_unit") || return 1
  _path=$(_ev_scope_path "$_plan" "$_scope")
  local _r
  _r=$(jq -sr --arg unit "$_unit" --arg stage "$_stage" --argjson ceil "$_ceil" '
    [ .[] | select((.unit==$unit) and (.stage==$stage)) ] as $rows
    | ( [ range(0; ($rows|length)) as $i | select($rows[$i].type=="milestone") | $i ] | last ) as $lm
    | ( if $lm == null then $rows else $rows[($lm+1):] end ) as $win
    | [ range(0; ($win|length)) as $i | select($win[$i].type=="verdict") | $i ] as $vidx
    | if ($vidx|length) <= $ceil then "no"
      else
        ($vidx[$ceil]) as $cross
        | ( [ range(0; ($win|length)) as $j
              | select($win[$j].type=="human-clear" and $win[$j].what=="ceiling" and $j > $cross) | $j ]
            | length ) as $cleared
        | if $cleared > 0 then "no" else "yes" end
      end
  ' "$_path" 2>/dev/null || echo "no")
  [[ "$_r" == "yes" ]]
}

# ev_is_blocked PLAN UNIT STAGE → rc0 if an open block exists for (unit,stage).
# Scope-wide (NOT milestone-bounded): blocks clear only via human-clear, never milestone.
# Per kind: newest-clear-wins (block kind K cleared by a later human-clear with .kind==K).
ev_is_blocked() {
  local _plan="$1" _unit="$2" _stage="$3" _scope _path
  _scope=$(scope "$_unit") || return 1
  _path=$(_ev_scope_path "$_plan" "$_scope")
  local _r
  _r=$(jq -sr --arg unit "$_unit" --arg stage "$_stage" '
    [ .[] | select((.unit==$unit) and (.stage==$stage)) ] as $rows
    | [ $rows[] | select(.type=="block") | .kind ] | unique as $kinds
    | reduce $kinds[] as $k (false;
        if . then . else
          ( [ range(0; ($rows|length)) as $i | select($rows[$i].type=="block" and $rows[$i].kind==$k) | $i ] | last ) as $lb
          | ( [ range(0; ($rows|length)) as $i | select($rows[$i].type=="human-clear" and $rows[$i].kind==$k) | $i ] | last ) as $lc
          | if ($lb != null) and ($lc == null or $lb > $lc) then true else false end
        end )
  ' "$_path" 2>/dev/null || echo "false")
  [[ "$_r" == "true" ]]
}

# ev_is_converged PLAN UNIT STAGE [FROZEN_HASH] → rc0 if converged (SKIP). empty-guard fail-closed.
# FROZEN_HASH (optional): use this pre-computed hash instead of recomputing — required by the
# pass-audit gate so the 1st/2nd PASS see the same input identity (no racy working-tree re-read).
ev_is_converged() {
  local _plan="$1" _unit="$2" _stage="$3" _frozen="${4:-}" _H _streak
  if [[ -n "$_frozen" ]]; then _H="$_frozen"; else _H=$(_stage_input_hash "$_plan" "$_unit" "$_stage"); fi
  [[ "$_H" == "empty" || "$_H" == "no-sha-tool" || -z "$_H" ]] && return 1
  ev_ceiling_reached "$_plan" "$_unit" "$_stage" && return 1
  _streak=$(ev_streak "$_plan" "$_unit" "$_stage" "$_H")
  [[ "${_streak:-0}" -ge 2 ]]
}

# ev_is_implemented PLAN UNIT → rc0 if code AND quality both converged.
ev_is_implemented() {
  ev_is_converged "$1" "$2" code && ev_is_converged "$1" "$2" quality
}

# ev_is_integration_passed PLAN → rc0 if __integration__ has a PASS verdict at the
# current H_int. Single-pass-at-hash (NOT streak); gates `transition done` only — the
# runner itself always re-runs (invariant 13).
ev_is_integration_passed() {
  local _plan="$1" _H _path
  _H=$(_stage_input_hash "$_plan" "__integration__" integration)
  [[ "$_H" == "empty" || "$_H" == "no-sha-tool" || -z "$_H" ]] && return 1
  _path=$(_ev_scope_path "$_plan" "__integration__")
  local _r
  _r=$(jq -sr --arg H "$_H" '
    [ .[] | select(.type=="verdict" and .stage=="integration" and .verdict=="PASS" and .input_hash==$H) ] | length
  ' "$_path" 2>/dev/null || echo 0)
  [[ "${_r:-0}" -ge 1 ]]
}

# stage_is_satisfied PLAN UNIT STAGE → rc0=SKIP, rc1=RUN.
# Single predicate replacing marker existence + is-converged + is-implemented.
stage_is_satisfied() {
  local _plan="$1" _unit="$2" _stage="$3"
  ev_is_blocked "$_plan" "$_unit" "$_stage" && return 1       # block branch handles [BLOCKED:*]
  ev_ceiling_reached "$_plan" "$_unit" "$_stage" && return 1  # ceiling branch handles [BLOCKED:ceiling]
  ev_is_converged "$_plan" "$_unit" "$_stage" && return 0     # SKIP
  return 1                                                    # RUN
}

# _ev_ceiling — validated ceiling from env (min 2, default 100).
_ev_ceiling() {
  local _c="${CLAUDE_CRITIC_LOOP_CEILING:-$EV_CEILING_DEFAULT}"
  case "$_c" in ''|*[!0-9]*) _c=$EV_CEILING_DEFAULT ;; esac
  [[ "$_c" -lt 2 ]] && _c=$EV_CEILING_DEFAULT
  printf '%s\n' "$_c"
}
