#!/bin/bash
#
# pipeline.sh — state machine for the delivery-pipeline skill.
#
# Owns the three invariants that agents forget under pressure:
#   1. gate order        — no gate is recorded before its predecessors pass
#   2. SHA staleness     — a verdict is only valid for the SHA it judged
#   3. round cap         — three failed verifications end the pipeline
#
# State: .pipeline/<change-id>/state.json
# Machine-readable output goes to stdout, messages to stderr.
#
# Usage:
#   pipeline.sh init [change-id] [base-ref]
#   pipeline.sh status | next | check | sync | stop <reason>
#   pipeline.sh gate <review|security|risk|ci|queue|rollout> <pass|fail> [artifact]
#   pipeline.sh gate risk <low|medium|high>
#   pipeline.sh human <approve|reject> [who]
#   pipeline.sh rollback-plan "<trigger>" "<command>" "<owner>"
#   pipeline.sh rollback-tested [when]
#
# Exit codes: 0 = ok, 1 = usage or invalid transition, 2 = pipeline stopped.

set -euo pipefail

CAP="${PIPELINE_MAX_ROUNDS:-3}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PIPE_DIR="${PIPELINE_DIR:-$ROOT/.pipeline}"

ORDER=(review security risk human ci queue rollout)
GATES=(review security risk ci queue rollout)   # human is decided, not passed

die()  { echo "pipeline: $*" >&2; exit 1; }
note() { echo "pipeline: $*" >&2; }
now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }

command -v jq >/dev/null 2>&1 || die "jq is required — https://jqlang.github.io/jq/"

# ─── arguments ───────────────────────────────────────────────────────────────

ID=""
argv=()
while [ $# -gt 0 ]; do
  case "$1" in
    -c|--change) [ $# -ge 2 ] || die "-c needs a change id"; ID="$2"; shift 2 ;;
    -h|--help)   sed -n '3,20p' "$0"; exit 0 ;;
    *)           argv+=("$1"); shift ;;
  esac
done
cmd="${argv[0]:-status}"
args=("${argv[@]:1}")

state_for() {
  local id="$1"
  if [ -n "$id" ]; then echo "$PIPE_DIR/$id/state.json"; return; fi
  local found
  found=$(find "$PIPE_DIR" -mindepth 2 -maxdepth 2 -name state.json 2>/dev/null || true)
  local n
  n=$(printf '%s\n' "$found" | grep -c . || true)
  case "$n" in
    0) die "no change record — run: pipeline.sh init <change-id>" ;;
    1) printf '%s\n' "$found" ;;
    *) die "several change records — pass -c <change-id>" ;;
  esac
}

# ─── state helpers ───────────────────────────────────────────────────────────

STATE=""

load() {
  STATE="$(state_for "$ID")"
  [ -f "$STATE" ] || die "no state file at $STATE"
}

write() {  # write <jq-filter> [jq-args...]
  local filter="$1"; shift
  jq "$@" "$filter" "$STATE" > "$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
}

get() { jq -r "$1" "$STATE"; }

head_sha() { git rev-parse --short=12 HEAD; }

require_clean_sha() {
  local now_sha
  now_sha="$(head_sha)"
  local rec
  rec="$(get '.head_sha')"
  if [ "$now_sha" != "$rec" ]; then
    die "HEAD is $now_sha but the record was opened at $rec — run 'pipeline.sh sync' and re-run the gates"
  fi
}

index_of() {
  local i=0 p
  for p in "${ORDER[@]}"; do
    [ "$p" = "$1" ] && { echo "$i"; return 0; }
    i=$((i + 1))
  done
  echo -1
}

human_required() { [ "$(get '.gates.human.required // false')" = "true" ]; }

require_running() {
  if [ "$(get '.phase')" = "stopped" ]; then
    die "pipeline stopped — $(get '.stop_reason // "manual stop"'); write handback.md and hand back to the author"
  fi
}

require_prereqs() {  # require_prereqs <gate>
  local g="$1" i j p v
  i="$(index_of "$g")"
  for ((j = 0; j < i; j++)); do
    p="${ORDER[$j]}"
    if [ "$p" = "human" ]; then
      human_required || continue
      [ "$(get '.gates.human.decision // ""')" = "approve" ] \
        || die "human gate has not approved — run: pipeline.sh human approve <name>"
      continue
    fi
    v="$(get ".gates.$p.verdict // \"\"")"
    [ "$v" = "pass" ] || die "gate '$p' must pass before '$g' (current: ${v:-unset})"
    [ "$(get ".gates.$p.sha // \"\"")" = "$(head_sha)" ] \
      || die "gate '$p' was judged at $(get ".gates.$p.sha // "nothing"") but HEAD is $(head_sha) — run 'pipeline.sh sync'"
  done
}

next_phase_after() {  # next_phase_after <gate>
  local g="$1" i n nx
  i="$(index_of "$g")"
  n=$((i + 1))
  nx="${ORDER[$n]:-done}"
  if [ "$nx" = "human" ] && ! human_required; then nx="ci"; fi
  echo "$nx"
}

# ─── commands ────────────────────────────────────────────────────────────────

cmd_init() {
  local id="${args[0]:-$(git rev-parse --abbrev-ref HEAD | tr '/' '-' | cut -c1-40)}"
  local base_ref="${args[1]:-}"
  STATE="$PIPE_DIR/$id/state.json"
  [ -f "$STATE" ] && die "change record already exists at $STATE"

  [ -n "$base_ref" ] || base_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
  [ -n "$base_ref" ] || { git rev-parse --verify --quiet origin/main >/dev/null && base_ref=main; }
  [ -n "${base_ref:-}" ] || { git rev-parse --verify --quiet origin/master >/dev/null && base_ref=master; }
  [ -n "${base_ref:-}" ] || base_ref="$(git rev-parse --abbrev-ref HEAD)"

  local base
  base="$(git merge-base HEAD "$base_ref" 2>/dev/null || git rev-parse HEAD)"

  mkdir -p "$PIPE_DIR/$id"
  jq -n \
    --arg id "$id" --arg base "$base" --arg head "$(head_sha)" --arg at "$(now)" \
    '{
      change_id: $id, base_sha: $base, head_sha: $head,
      phase: "review", round: 0, started: $at, updated: $at,
      rollback_plan: {trigger: null, command: null, owner: null, tested_at: null},
      gates: {
        review:   {verdict: null, sha: null, at: null, artifact: null},
        security: {verdict: null, sha: null, at: null, artifact: null},
        risk:     {verdict: null, tier: null, sha: null, rules: []},
        human:    {required: null, decision: null, who: null, at: null},
        ci:       {verdict: null, sha: null, artifact: null},
        queue:    {verdict: null, retest_base: null, merge_sha: null},
        rollout:  {verdict: null, stage: 0, artifact: null}
      }
    }' > "$STATE"

  note "opened $id at $(head_sha) (base $base)"
  jq . "$STATE"
}

cmd_status() { load; jq . "$STATE"; }

cmd_next() {
  load
  local phase
  phase="$(get '.phase')"
  case "$phase" in
    fix)     note "round $(get '.round') of $CAP — dispatch the fixer" ;;
    stopped) note "stopped — write handback.md and return to the author"; echo "stopped"; return 0 ;;
    done)    echo "done"; return 0 ;;
  esac
  echo "$phase"
}

cmd_sync() {
  load
  local old now_sha
  old="$(get '.head_sha')"
  now_sha="$(head_sha)"
  [ "$old" = "$now_sha" ] && { note "HEAD unchanged at $now_sha"; return 0; }

  write '.head_sha = $sha
         | .phase = "review"
         | .updated = $at
         | .gates.review   = {verdict: null, sha: null, at: null, artifact: null}
         | .gates.security = {verdict: null, sha: null, at: null, artifact: null}
         | .gates.risk     = {verdict: null, tier: null, sha: null, rules: []}
         | .gates.human    = {required: null, decision: null, who: null, at: null}
         | .gates.ci       = {verdict: null, sha: null, artifact: null}
         | .gates.queue    = {verdict: null, retest_base: null, merge_sha: null}
         | .gates.rollout  = {verdict: null, stage: 0, artifact: null}' \
    --arg sha "$now_sha" --arg at "$(now)"
  note "HEAD moved $old → $now_sha; every gate is stale, re-run from review (re-runs cost no round)"
  jq . "$STATE"
}

cmd_gate() {
  load
  require_running
  local g="${args[0]:-}" verdict="${args[1]:-}" artifact="${args[2]:-}"
  [ -n "$g" ] || die "gate needs a name: ${GATES[*]}"

  # risk is scored by tier, not pass/fail
  if [ "$g" = "risk" ]; then
    case "$verdict" in
      low|medium|high) ;;
      *) die "gate risk takes a tier: low | medium | high" ;;
    esac
  else
    case "$g" in
      review|security|ci|queue|rollout) ;;
      human) die "human gate is decided with: pipeline.sh human <approve|reject> [who]" ;;
      *) die "unknown gate '$g' — expected one of: ${GATES[*]}" ;;
    esac
    case "$verdict" in
      pass|fail) ;;
      *) die "gate '$g' takes pass or fail" ;;
    esac
  fi

  require_prereqs "$g"
  require_clean_sha

  if [ "$g" = "rollout" ]; then
    [ -n "$(get '.rollback_plan.command // ""')" ] \
      || die "no rollback command recorded — run: pipeline.sh rollback-plan \"<trigger>\" \"<command>\" \"<owner>\""
    [ "$(get '.rollback_plan.tested_at // ""')" != "" ] \
      || die "the rollback command was never executed — run it once where it is harmless, then: pipeline.sh rollback-tested"
  fi

  local sha at
  sha="$(head_sha)"
  at="$(now)"

  if [ "$g" = "risk" ]; then
    local required=false
    [ "$verdict" = "high" ] && required=true
    write '.gates.risk = {verdict: "pass", tier: $tier, sha: $sha,
                          rules: (if $rules == "" then [] else [$rules] end)}
           | .gates.human.required = $req
           | .phase = (if $req then "human" else "ci" end)
           | .updated = $at' \
      --arg tier "$verdict" --arg sha "$sha" --arg at "$at" \
      --argjson req "$required" --arg rules "${artifact:-}"
    note "risk tier: $verdict$([ "$required" = true ] && echo ' — human gate required')"
    jq . "$STATE"
    return 0
  fi

  if [ "$verdict" = "fail" ]; then
    local round newround
    round="$(get '.round')"
    newround=$((round + 1))
    write '.gates[$g].verdict = "fail"
           | .gates[$g].sha = $sha
           | .gates[$g].at = $at
           | .gates[$g].artifact = $art
           | .round = $r
           | .updated = $at' \
      --arg g "$g" --arg sha "$sha" --arg at "$at" --arg art "$artifact" \
      --argjson r "$([ "$newround" -gt "$CAP" ] && echo "$CAP" || echo "$newround")"

    if [ "$newround" -gt "$CAP" ]; then
      write '.phase = "stopped" | .stop_reason = "gate \($g) failed after \($cap) fix rounds"' \
        --arg g "$g" --argjson cap "$CAP"
      note "gate '$g' failed again after $CAP fix rounds — stopping"
      note "write handback.md and return the change to the author"
      jq . "$STATE"
      exit 2
    fi
    write '.phase = "fix"'
    note "gate '$g' failed — fix round $newround of $CAP, dispatch the fixer"
    jq . "$STATE"
    return 0
  fi

  # pass
  local phase
  phase="$(next_phase_after "$g")"
  write '.gates[$g].verdict = "pass"
         | .gates[$g].sha = $sha
         | .gates[$g].at = $at
         | .gates[$g].artifact = (if $art == "" then .gates[$g].artifact else $art end)
         | .phase = $p
         | .updated = $at' \
    --arg g "$g" --arg sha "$sha" --arg at "$at" --arg art "$artifact" --arg p "$phase"
  note "gate '$g' passed — next: $phase"
  jq . "$STATE"
}

cmd_human() {
  load
  require_running
  local decision="${args[0]:-}" who="${args[1]:-unknown}"
  case "$decision" in approve|reject) ;; *) die "human takes approve or reject" ;; esac
  require_prereqs human
  require_clean_sha

  if [ "$decision" = "reject" ]; then
    local round newround
    round="$(get '.round')"
    newround=$((round + 1))
    write '.gates.human.decision = "reject" | .gates.human.who = $who
           | .gates.human.at = $at | .updated = $at
           | .round = $r
           | .phase = (if $over then "stopped" else "fix" end)
           | .stop_reason = (if $over then "human rejected after \($cap) fix rounds" else null end)' \
      --arg who "$who" --arg at "$(now)" --argjson r "$([ "$newround" -gt "$CAP" ] && echo "$CAP" || echo "$newround")" \
      --argjson cap "$CAP" --argjson over "$([ "$newround" -gt "$CAP" ] && echo true || echo false)"
    if [ "$newround" -gt "$CAP" ]; then
      note "human rejected again after $CAP fix rounds — stopping"
      jq . "$STATE"
      exit 2
    fi
    note "human rejected — fix round $newround of $CAP"
    jq . "$STATE"
    return 0
  fi

  if human_required; then
    [ -n "$(get '.rollback_plan.trigger // ""')" ] && [ -n "$(get '.rollback_plan.command // ""')" ] \
      || die "a high-risk change needs a recorded rollback plan before approval — run: pipeline.sh rollback-plan \"<trigger>\" \"<command>\" \"<owner>\""
  fi

  write '.gates.human.decision = "approve" | .gates.human.who = $who
         | .gates.human.at = $at | .phase = "ci" | .updated = $at' \
    --arg who "$who" --arg at "$(now)"
  note "human approved — next: ci"
  jq . "$STATE"
}

cmd_rollback_plan() {
  load
  require_running
  local trigger="${args[0]:-}" command="${args[1]:-}" owner="${args[2]:-unknown}"
  [ -n "$trigger" ] && [ -n "$command" ] \
    || die 'usage: pipeline.sh rollback-plan "<trigger>" "<command>" "<owner>"'
  write '.rollback_plan = {trigger: $t, command: $c, owner: $o, tested_at: null}
         | .updated = $at' --arg t "$trigger" --arg c "$command" --arg o "$owner" --arg at "$(now)"
  note "rollback plan recorded — execute the command once in a harmless scope, then: pipeline.sh rollback-tested"
  jq . "$STATE"
}

cmd_rollback_tested() {
  load
  require_running
  [ -n "$(get '.rollback_plan.command // ""')" ] || die "record the plan first: pipeline.sh rollback-plan ..."
  local when="${args[0]:-$(now)}"
  write '.rollback_plan.tested_at = $at | .updated = $at' --arg at "$when"
  note "rollback command marked as executed at $when"
  jq . "$STATE"
}

cmd_check() {
  load
  local problems=() phase
  phase="$(get '.phase')"
  case "$phase" in
    stopped) problems+=("pipeline is stopped — hand back to the author") ;;
    done)    problems+=("pipeline already complete") ;;
  esac

  local g v gsha head
  head="$(head_sha)"
  for g in review security risk; do
    v="$(get ".gates.$g.verdict // \"\"")"
    [ "$v" = "pass" ] || problems+=("gate '$g' has no pass verdict")
    gsha="$(get ".gates.$g.sha // \"\"")"
    [ "$gsha" = "$head" ] || problems+=("gate '$g' judged $([ -n "$gsha" ] && echo "$gsha" || echo "nothing"), HEAD is $head")
  done
  if human_required; then
    [ "$(get '.gates.human.decision // ""')" = "approve" ] || problems+=("human approval required but missing")
  fi

  if [ ${#problems[@]} -gt 0 ]; then
    printf '%s\n' "${problems[@]}" >&2
    jq -n --argjson p "$(printf '%s\n' "${problems[@]}" | jq -R . | jq -s .)" \
      '{ready: false, blockers: $p}'
    exit 1
  fi
  jq -n --arg sha "$head" '{ready: true, sha: $sha}'
}

cmd_stop() {
  load
  local reason="${args[0]:-manual stop}"
  write '.phase = "stopped" | .stop_reason = $r | .updated = $at' \
    --arg r "$reason" --arg at "$(now)"
  note "stopped: $reason — write handback.md"
  jq . "$STATE"
  exit 2
}

case "$cmd" in
  init)    cmd_init ;;
  status)  cmd_status ;;
  next)    cmd_next ;;
  check)   cmd_check ;;
  sync)    cmd_sync ;;
  gate)    cmd_gate ;;
  human)   cmd_human ;;
  rollback-plan)   cmd_rollback_plan ;;
  rollback-tested) cmd_rollback_tested ;;
  stop)    cmd_stop ;;
  *)       die "unknown command '$cmd' — see --help" ;;
esac
