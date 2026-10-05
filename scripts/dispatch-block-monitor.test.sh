#!/usr/bin/env bash
#
# Self-check for scripts/dispatch-block-monitor.sh. Exercises the
# AUT-5634 detection predicate offline against fixed JSON so the
# signature (conclusion == failure && steps.length == 0 &&
# runner_name == "") is proven, not assumed — including the traps
# that make it easy to get wrong.
#
# Run: bash scripts/dispatch-block-monitor.test.sh
# Requires: bash, jq. No network, no token, no GitHub.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/dispatch-block-monitor.sh"

# Same predicate the monitor applies to /actions/runs/{id}/jobs.
BLOCKED_JOBS_JQ='.jobs[]
  | select(.conclusion == "failure")
  | select(((.steps // []) | length) == 0)
  | select((.runner_name // "") == "")
  | [.name, (.id|tostring), .check_run_url] | @tsv'

# The four shapes the PR checks tab actually shows.
FIXED='{
  "jobs": [
    {"name": "never-dispatched", "id": 1, "conclusion": "failure",
     "steps": [], "runner_name": "", "check_run_url": "http://x/1"},
    {"name": "real-test-failure", "id": 2, "conclusion": "failure",
     "steps": [{"name": "checkout"}, {"name": "build"}], "runner_name": "github-actions",
     "check_run_url": "http://x/2"},
    {"name": "queued-not-failed", "id": 3, "conclusion": null,
     "steps": [], "runner_name": "", "check_run_url": "http://x/3"},
    {"name": "cancelled", "id": 4, "conclusion": "cancelled",
     "steps": [], "runner_name": "", "check_run_url": "http://x/4"},
    {"name": "runner-null", "id": 5, "conclusion": "failure",
     "steps": [], "runner_name": null, "check_run_url": "http://x/5"},
    {"name": "steps-null", "id": 6, "conclusion": "failure",
     "steps": null, "runner_name": "", "check_run_url": "http://x/6"}
  ]
}'

fail() { echo "::error::$*" >&2; exit 1; }

# Fail closed: a missing monitor must fail this self-check, not
# pass it (every guard below would trivially succeed without it).
[ -f "$SCRIPT" ] || fail "monitor script missing: $SCRIPT"

got="$(jq -r "$BLOCKED_JOBS_JQ" <<<"$FIXED" | cut -f1 | paste -sd, -)"
[ "$got" = "never-dispatched,runner-null,steps-null" ] \
  || fail "predicate matched [$got]; want never-dispatched,runner-null,steps-null
- a job that ran and failed must NOT match (real-test-failure has steps)
- a not-yet-run/cancelled job must NOT match (conclusion != failure)"

# Guard rails: the monitor must stay out of GitHub Actions entirely.
grep -qE '^(on:|name:)' "$SCRIPT" \
  && fail "monitor looks like a workflow file" || true
! grep -q 'runs-on' "$SCRIPT" \
  || fail "monitor must not declare a GitHub runner (AC4: metered minutes)"

# The monitor must fail closed when it cannot authenticate rather than
# silently reporting "all clear".
if env -u GITHUB_TOKEN bash "$SCRIPT" >/dev/null 2>&1; then
  fail "monitor exited 0 without GITHUB_TOKEN; must exit 1"
fi

echo "OK: dispatch-block predicate matches only never-dispatched failures; monitor runs off Actions (AC4) and fails closed without a token."
