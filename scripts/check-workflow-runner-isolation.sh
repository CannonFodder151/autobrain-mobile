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

  # Rule 3: secret-reading workflow must not auto-fire on push. Comment lines
  # are stripped first so a `${{ secrets.X }}` mentioned in the header trust
  # model note does not count as a read.
  if grep -vE '^[[:space:]]*#' "$wf" | grep -qE '\$\{\{[[:space:]]*secrets\.'; then
    if grep -qwE 'push' <<<"$on_block"; then
      echo "::error::$name reads secrets AND triggers on push; with no branch protection (Pro required, AUT-4766) any push to main runs it unreviewed. Use workflow_dispatch only." >&2
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
  echo "AUT-4722/AUT-4766: $failures runner-isolation violation(s)." >&2
  exit 1
fi
echo "OK: no pull_request-triggered workflow runs on a self-hosted runner; release-signing claimed by ${signing_claimants[0]}; no secret-reading workflow triggers on push."