#!/usr/bin/env bash
#
# Fails if any workflow runs on a self-hosted runner while being triggered by
# contributor-controlled code (pull_request / pull_request_target).
#
# Why (AUT-4722): a self-hosted runner is a persistent host. A `pull_request`
# trigger executes the workflow *file from the PR head*, so a contributor can
# land arbitrary steps on the box. Any artifact that survives the job waits on
# that host until the next trusted run — e.g. release-mobile.yml, which loads
# UPLOAD_KEYSTORE_BASE64 and GOOGLE_PLAY_SERVICE_ACCOUNT_JSON.
#
# Self-hosted runners are only allowed for dispatch/push/schedule triggers.
#
# Second rule: the `release-signing` runner label carries the Play upload key,
# so exactly one workflow may claim it. A second claimant silently shares those
# secrets with whatever else that workflow runs.
#
# Third rule (AUT-4766): a workflow that reads secrets must be dispatch-only.
# This repo is private on a GitHub Free plan — branch protection and rulesets
# both 403 with "Upgrade to GitHub Pro", so nothing on the server gates who may
# push to main. A `push:` trigger on a secret-reading workflow means any push
# to main executes that secret-reading code with no review in between. Only
# `workflow_dispatch` adds a deliberate human action. Pro allows dropping this
# rule in favour of a real required-review branch rule.
#
# schedule / workflow_run / workflow_call count as auto-fire too (AUT-4882 F5).
# A nightly cron that reads APPLE_STORE_API_KEY is unattended secret access,
# which is the whole threat; `workflow_call` is a bypass because a
# dispatch-only workflow invoked by another workflow runs on the caller's ref.
#
# Fourth rule (AUT-4882 F6): a self-hosted runner whose workflow mutates the
# host may only be workflow_dispatch. This is the control dispatch-only
# host-mutating workflows actually need — rule 1 only looked at
# `pull_request`, so adding a `push:` trigger later would have passed the guard
# and put main's code on the runner every commit.
#
# Fifth rule (AUT-4864): a step that disables errexit must also set
# `continue-on-error: true`. GitHub's default shell is `bash -e {0}`, so a
# diagnostic step written as `set -uo pipefail` still runs under `-e` and aborts
# on the first probe against a path that does not exist on the host. The job
# then goes red while only reporting host state, so every triage pass re-reads
# a red X that is not the failure being chased.
#
# Run: bash scripts/check-workflow-runner-isolation.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
WF_DIR="$ROOT/.github/workflows"
failures=0
signing_claimants=()

shopt -s nullglob
for wf in "$WF_DIR"/*.yml "$WF_DIR"/*.yaml; do
  name="$(basename "$wf")"
  # `on:` block parsed crudely: untrusted if pull_request appears before the
  # first top-level non-trigger key (permissions/jobs/concurrency/env).
  # `/^on:/` rather than `/^on:[[:space:]]*$/` so the inline list form
  # (`on: [pull_request, push]`) is caught too.
  on_block="$(awk '
    /^on:/ {in_on=1; print; next}
    in_on && /^[a-zA-Z_]+:/ {in_on=0}
    in_on {print}
  ' "$wf")"

  if grep -qwE 'pull_request(_target)?' <<<"$on_block"; then
    if grep -qE 'runs-on:.*self-hosted' "$wf"; then
      echo "::error::$name runs on a self-hosted runner with a pull_request trigger" >&2
      failures=$((failures + 1))
    fi
  fi

  # Only a `runs-on:` line counts, so mentioning the label in a comment or in
  # a ponytail note does not make a workflow a claimant.
  if grep -qE '^[[:space:]]*runs-on:.*release-signing' "$wf"; then
    signing_claimants+=("$name")
  fi

# Rule 5 (AUT-4864): a step whose `run:` body turns off `errexit`
  # (`set -uo pipefail`, `set +e`, ...) is declaring itself non-fatal, but the
  # default Actions shell is `bash -e {0}` — so the `-e` the author deliberately
  # dropped is re-added by the runner and the step aborts on the first
  # unguarded command that returns non-zero. A diagnostic step therefore fails
  # while merely *reporting* host state, producing a red X that says nothing
  # about the thing being diagnosed. Require `continue-on-error: true` so the
  # intent is real and the step's exit code stops gating the job.
  #
  # Steps are split on the list-item dash at whatever indent the file uses, and
  # a line at lower indent closes the current step. Scoped per step, not per
  # file: a workflow may pair a diagnostic step with a step that legitimately
  # depends on errexit.
  # awk emits each step as ONE record, so read with -d '' — a plain `read`
  # would take only the first line of the block and lose `continue-on-error`.
  while IFS= read -r -d '' step_body; do
    # Comment lines are stripped so a `# ... set -uo pipefail ...` explanation
    # does not count as a step that disables errexit.
    step_code="$(grep -vE '^[[:space:]]*#' <<<"$step_body")"
    # Flag only a `set` line that omits `e` from its flag cluster, i.e. one
    # that leaves errexit OFF. `set -euo pipefail` keeps -e and is fine; the
    # AUT-4864 shape is a cluster like `-uo` / `-u` / `-o`, or an explicit
    # `set +e`.
    if grep -qE '(^|[[:space:]])set[[:space:]]+(\+e|(-|\+)[a-z]*)[[:space:]]*$|(^|[[:space:]])set[[:space:]]+-[a-z]*[uo][a-z]*[[:space:]]' <<<"$step_code" \
       && ! grep -qE '(^|[[:space:]])set[[:space:]]+-[a-z]*e[a-z]*[[:space:]]' <<<"$step_code"; then
      # The optional `(- ...)?` covers `continue-on-error` written as the FIRST
      # key of the list item, where the line starts with the list dash
      # (`- continue-on-error: true`). Anchoring on whitespace alone missed that
      # equally valid YAML and flagged correct workflows (AUT-4995).
      if ! grep -qE "^[[:space:]]*(-[[:space:]]+)?continue-on-error:[[:space:]]*(true|'true'|\"true\"|\\\$\{\{[^}]*\}\})[[:space:]]*$" <<<"$step_body"; then
        echo "::error::$name has a diagnostic step that disables errexit (set -uo pipefail / set +e) but no continue-on-error: true; the default 'bash -e {0}' shell re-adds -e, so the step aborts on the first non-zero probe instead of reporting it (AUT-4864)" >&2
        failures=$((failures + 1))
      fi
    fi
  done < <(awk '
    BEGIN { RS = "\n" }
    function emit() { if (buf != "") { printf "%s%c", buf, 0; buf = "" } }
    match($0, /^[ ]*-[ ]/) {
      indent = RSTART + RLENGTH - 2
      # A dash line INDENTED DEEPER than the current step is body content
      # (a list inside `run:`), not a new step. Splitting there truncated the
      # step and dropped a trailing `continue-on-error` (AUT-4876 F1).
      if (step_indent != "" && indent > step_indent) { buf = buf "\n" $0; next }
      emit()
      step_indent = indent
      buf = $0
      next
    }
    buf != "" {
      line_indent = match($0, /[^ ]/) - 1
      if (line_indent <= step_indent) { emit(); next }
      buf = buf "\n" $0
    }
    END { emit() }
  ' "$wf")

  # Rule 3: secret-reading workflow must not auto-fire on push. Comment lines
  # are stripped first so a `${{ secrets.X }}` mentioned in the header trust
  # model note does not count as a read.
  if grep -vE '^[[:space:]]*#' "$wf" | grep -qE '\$\{\{[[:space:]]*secrets\.'; then
    if grep -qwE 'push|schedule|workflow_run|workflow_call' <<<"$on_block"; then
      echo "::error::$name reads secrets AND auto-fires (push|schedule|workflow_run|workflow_call); with no branch protection (Pro required, AUT-4766) that runs secret-reading code unreviewed or unattended. Use workflow_dispatch only." >&2
      failures=$((failures + 1))
    fi
  fi

  # Rule 4: a self-hosted runner that mutates its own host (runs a script from
  # the repo, installs, or otherwise writes outside the job's checkout) may only
  # be reached by workflow_dispatch. Rule 1 covered `pull_request` only, so a
  # later `push:` trigger passed the guard while putting main's code on a
  # persistent box every commit (AUT-4882 F6).
  if grep -qE 'runs-on:.*self-hosted' "$wf"; then
    if grep -qwE 'pull_request|pull_request_target|push|schedule|workflow_run|workflow_call|repository_dispatch' <<<"$on_block"; then
      echo "::error::$name runs on a self-hosted runner and auto-fires; it installs/mutates the persistent runner host. Use workflow_dispatch only." >&2
      failures=$((failures + 1))
    fi
  fi
done

if [[ "${#signing_claimants[@]}" -eq 0 ]]; then
  echo "::error::no workflow claims the release-signing runner label; the signing secrets have no dedicated runner" >&2
  failures=$((failures + 1))
elif [[ "${#signing_claimants[@]}" -gt 1 ]]; then
  echo "::error::release-signing runner label claimed by ${#signing_claimants[@]} workflows (${signing_claimants[*]}); the Play upload key is shared with every claimant" >&2
  failures=$((failures + 1))
fi

if [[ "$failures" -gt 0 ]]; then
  echo "AUT-4722/AUT-4766/AUT-4864: $failures workflow-safety violation(s)." >&2
  exit 1
fi
echo "OK: no pull_request-triggered workflow runs on a self-hosted runner; self-hosted workflows are dispatch-only; release-signing claimed by ${signing_claimants[0]}; no secret-reading workflow auto-fires; every non-fatal diagnostic step sets continue-on-error: true."
