#!/bin/bash
# AUT-5634: alert when a GitHub Actions run fails WITHOUT EVER RUNNING.
#
# A run that GitHub refuses to dispatch reports `conclusion: failure` with zero
# executed steps and an empty `runner_name` — byte-for-byte the same shape in
# the PR checks tab as a real test failure. That ambiguity is how the Actions
# billing block sat unnoticed three times (c5653781 Aug, aa15fd92, AUT-5634).
#
# This runs on the dev box under cron, NOT as a GitHub Actions workflow,
# deliberately (AUT-5634 AC4):
#   * a scheduled GitHub-hosted job burns metered minutes, and while the
#     account is over its spending limit the monitor's own dispatch would be
#     blocked too — a watchdog that stops watching when it is needed most;
#   * the repo's own guard (scripts/check-workflow-runner-isolation.sh rule 4)
#     forbids a self-hosted runner on any auto-firing trigger.
# Adding zero workflows is what makes this fire while billing is broken.
#
# Detection is the signature from AUT-5634 AC1, unchanged:
#   conclusion == "failure" && steps.length == 0 && runner_name == ""
#
# Deterministic and offline-testable: no model, no heuristics. Predicated runs
# are reported once, then re-asserted every REALERT_HOURS while the same run
# stays blocked, so a block that persists for days keeps nagging instead of
# going silent after the first alert.
#
# Run: bash scripts/dispatch-block-monitor.sh
# Self-check: bash scripts/dispatch-block-monitor.test.sh
# Env: GITHUB_TOKEN (required), GH_REPO, N8N_WEBHOOK, STATE_FILE,
#      PAGE_SIZE, REALERT_HOURS, DRY_RUN.
set -uo pipefail

REPO="${GH_REPO:-CannonFodder151/autobrain-mobile}"
API="https://api.github.com"
N8N_WEBHOOK="${N8N_WEBHOOK:-https://n8n.nathanmartina.com/webhook/discord-report}"
DISCORD_CHANNEL="${DISCORD_CHANNEL:-ops}"
STATE_FILE="${STATE_FILE:-$HOME/.autobrain-dispatch-block-seen}"
PAGE_SIZE="${PAGE_SIZE:-50}"
REALERT_SECONDS=$(( ${REALERT_HOURS:-24} * 3600 ))

log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }

if [ -z "${GITHUB_TOKEN:-}" ]; then
  log "GITHUB_TOKEN not set; cannot query the Actions API"
  exit 1
fi

api() {
  curl -sSf --max-time 30 \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@"
}

# AUT-5634 AC1 signature. A job GitHub never dispatched has no steps and no
# runner; a job that ran and failed always has at least one step. The
# `conclusion` test alone is not enough — that is the whole bug.
BLOCKED_JOBS_JQ='.jobs[]
  | select(.conclusion == "failure")
  | select(((.steps // []) | length) == 0)
  | select((.runner_name // "") == "")
  | [.name, (.id|tostring), .check_run_url] | @tsv'

runs_json="$(api "$API/repos/$REPO/actions/runs?per_page=$PAGE_SIZE")" || {
  log "Actions runs query failed; skipping this cycle"
  exit 0
}

now="$(date +%s)"
CARRY_FILE="${STATE_FILE}.carry"
: > "$CARRY_FILE"
# Carry forward the alert timestamps of runs still inside their
# re-alert window, and report any run that is new or has aged out.
reported=0
declare -a report_rows=()

while IFS=$'\t' read -r run_id run_name head_branch html_url created_at; do
  [ -n "$run_id" ] || continue
  created_at="${created_at//:/}" # jq strptime wants +0000, the API gives +00:00
  run_epoch="$(date -u -d "${created_at}" +%s 2>/dev/null || echo "$now")"

  last=""
  if [ -f "$STATE_FILE" ]; then
    last="$(awk -v id="$run_id" '$1 == id {print $2; exit}' "$STATE_FILE")"
  fi

  if [ -n "$last" ] && [ $(( now - last )) -lt "$REALERT_SECONDS" ]; then
    echo "$run_id $last" >> "$CARRY_FILE"   # keep, not yet due again
    continue
  fi

  jobs_json="$(api "$API/repos/$REPO/actions/runs/$run_id/jobs")" || continue
  blocked="$(jq -r "$BLOCKED_JOBS_JQ" <<<"$jobs_json" 2>/dev/null)"
  [ -n "$blocked" ] || continue

  job_names="$(cut -f1 <<<"$blocked" | paste -sd, -)"
  reason="$(printf '%s\n' "$blocked" | cut -f3 | head -1 | xargs -r -I{} \
    curl -sSf --max-time 20 -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github+json" "{}/annotations" 2>/dev/null \
    | jq -r '.[] | select(.message | test("not started|payment|spending limit"; "i")) | .message' \
    | head -1)"

  log "dispatch-block: run $run_id ($run_name) jobs=$job_names"
  report_rows+=("$run_id|$run_name|$head_branch|$job_names|$html_url|$reason")
  reported=$(( reported + 1 ))
done < <(jq -r --argjson n "$PAGE_SIZE" '
  .workflow_runs
  | map(select(.conclusion == "failure"))
  | .[:$n][]
  | [.id, .name, .head_branch, .html_url, .created_at] | @tsv' <<<"$runs_json")

# Write the state file once, from the carried-forward entries plus (only if
# the alert lands) the runs just reported. Recording a run as alerted before
# the POST succeeds would silently swallow the report — precisely the "nobody
# was told" failure this monitor exists to end.
commit_state() {
  cp -f "$CARRY_FILE" "$STATE_FILE.tmp" 2>/dev/null || : > "$STATE_FILE.tmp"
  if [ "${1:-}" = "include_reported" ]; then
    for row in ${report_rows+"${report_rows[@]}"}; do
      echo "${row%%|*} $now" >> "$STATE_FILE.tmp"
    done
  fi
  mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}

if [ "$reported" -eq 0 ]; then
  commit_state
  rm -f "$CARRY_FILE"
  log "no dispatch-time blocks"
  exit 0
fi

if [ "${DRY_RUN:-0}" = "1" ]; then
  for row in "${report_rows[@]}"; do echo "DRY_RUN would alert: $row"; done
  rm -f "$CARRY_FILE"
  exit 0
fi

# Commit the state only after the alert lands. Recording first would silently
# swallow the report on a failed POST — exactly the "nobody was told" failure
# this monitor exists to end.
if python3 - "${N8N_WEBHOOK}" "$DISCORD_CHANNEL" "$REPO" "$reported" "$now" \
  "${report_rows[@]}" <<'PY'
import json, sys, urllib.request, datetime

webhook, channel, repo, reported, now, *rows = sys.argv[1:]
reported = int(reported)
runs = [r.split("|", 5) for r in rows]
reason = next((r[5] for r in runs if r[5]), "")
newest = runs[0]  # the runs API returns newest-first

# The n8n reporter's contract is <=4 inline fields (company Discord format).
# Long-running blocks produce far more runs than that, so summarise and keep
# the most recent one fully linked.
fields = [
    {"name": "Runs blocked", "value": str(reported), "inline": True},
    {"name": "Jobs", "value": ", ".join(sorted({r[3] for r in runs}))[:1024], "inline": True},
    {"name": "Newest", "value": f"<{newest[4]}|{newest[0]}> ({newest[1]}, {newest[2]})", "inline": True},
    {"name": "Detected",
     "value": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC"), "inline": True},
]
description = ("0 executed steps and no runner assigned — the job was never "
               "dispatched, so these are **not** test failures. Usually the "
               "account billing/spending limit (an org-owner action); "
               "self-hosted runners and hosted deploys are unaffected.")
if reason:
    description += f"\nGitHub says: {reason}"

payload = {
    "channel": channel,
    "title": f"{repo}: {reported} Actions run(s) failed without running",
    "description": description,
    "color": "0xED4245",
    "author": "Deployment Lead",
    "fields": fields,
}
req = urllib.request.Request(webhook, data=json.dumps(payload).encode(),
                             headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=30) as resp:
    print(f"discord {resp.status} ({channel}): {reported} dispatch block(s)")
PY
then
  commit_state include_reported
  rm -f "$CARRY_FILE"
else
  # Undelivered runs are NOT recorded, so the next cycle re-reports them.
  commit_state
  rm -f "$CARRY_FILE"
  log "ERROR: Discord report failed; runs will be re-reported next cycle"
  exit 1
fi
