#!/usr/bin/env bash
#
# Self-check for scripts/check-workflow-runner-isolation.sh. Builds throwaway
# workflow dirs in a temp tree and asserts the guard passes on the shapes we
# want and fails on each shape we are guarding against:
#
#   rule 1  pull_request trigger on a self-hosted runner        -> fail
#   rule 2  a second `release-signing` runs-on claimant         -> fail
#   rule 3  secret-reading workflow that auto-fires             -> fail
#            (push / schedule / workflow_run / workflow_call)
#   rule 4  self-hosted runner with any non-dispatch trigger    -> fail
#   rule 5  diagnostic step with `set -uo pipefail` and no
#           `continue-on-error: true`                           -> fail
#   ok      secret-reading workflow, workflow_dispatch only     -> pass
#   ok      `${{ secrets.X }}` mentioned in a comment only      -> pass
#   ok      scheduled workflow that reads no secrets, no runner -> pass
#   ok      `set -euo pipefail` step (errexit stays ON)         -> pass
#   ok      `set -uo pipefail` + `continue-on-error: true`      -> pass
#   ok      `set -uo pipefail` mentioned only in a comment      -> pass
#
# Run: bash scripts/check-workflow-runner-isolation.test.sh
# Requires: bash.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$DIR/check-workflow-runner-isolation.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# usage: check <expect pass|fail> <label> <workflow body...>
check() {
  local expect="$1" label="$2"; shift 2
  local root="$TMP/$(echo "$label" | tr -c 'a-zA-Z0-9' '_')"
  rm -rf "$root"
  mkdir -p "$root/.github/workflows" "$root/scripts"
  cp "$GUARD" "$root/scripts/"
  local wf
  for wf in "$@"; do
    printf '%s\n' "$wf" > "$root/.github/workflows/wf-$RANDOM.yml"
  done
  if (cd "$root" && bash scripts/check-workflow-runner-isolation.sh >/dev/null 2>&1); then
    got=pass
  else
    got=fail
  fi
  if [[ "$got" == "$expect" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL [$label]: expected $expect, got $got"
  fi
}

SIGNING_JOB='jobs:
  release:
    runs-on: [self-hosted, linux, x64, release-signing]
    steps:
      - run: echo hi'

check pass "dispatch-only secret workflow" \
"on:
  workflow_dispatch:
permissions:
  contents: write
$SIGNING_JOB
    steps:
      - env:
          K: \${{ secrets.UPLOAD_KEYSTORE_BASE64 }}
        run: echo \"\$K\""

check fail "push-triggered secret workflow" \
"on:
  push:
    branches: [main]
  workflow_dispatch:
permissions:
  contents: write
$SIGNING_JOB
    steps:
      - env:
          K: \${{ secrets.UPLOAD_KEYSTORE_BASE64 }}
        run: echo \"\$K\""

check fail "inline-list push + secrets" \
"on: [push]
permissions:
  contents: write
jobs:
  r:
    runs-on: ubuntu-latest
    steps:
      - env:
          K: \${{ secrets.APPLE_STORE_API_KEY }}
        run: echo \"\$K\""

check pass "secrets mentioned only in comments" \
"on:
  workflow_dispatch:
$SIGNING_JOB
    steps:
      - run: echo hi" \
"on:
  push:
    branches: [main]
# this workflow reads UPLOAD_KEYSTORE_BASE64 but does not actually read it
permissions:
  contents: write
jobs:
  r:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi"

check fail "PR trigger on self-hosted" \
"on:
  pull_request:
jobs:
  r:
    runs-on: [self-hosted, linux, x64]
    steps:
      - run: echo hi"

check fail "two release-signing claimants" \
"on:
  workflow_dispatch:
$SIGNING_JOB
    steps:
      - run: echo hi" \
"on:
  workflow_dispatch:
jobs:
  other:
    runs-on: [self-hosted, linux, x64, release-signing]
    steps:
      - run: echo hi"

check fail "scheduled secret workflow" \
"on:
  schedule:
    - cron: '0 3 * * *'
  workflow_dispatch:
permissions:
  contents: write
$SIGNING_JOB
    steps:
      - env:
          K: \${{ secrets.APPLE_STORE_API_KEY }}
        run: echo \"\$K\""

check fail "workflow_run secret workflow" \
"on:
  workflow_run:
    workflows: [Build]
    types: [completed]
permissions:
  contents: write
$SIGNING_JOB
    steps:
      - env:
          K: \${{ secrets.UPLOAD_KEYSTORE_BASE64 }}
        run: echo \"\$K\""

check fail "workflow_call secret workflow" \
"on:
  workflow_call:
permissions:
  contents: write
$SIGNING_JOB
    steps:
      - env:
          K: \${{ secrets.UPLOAD_KEYSTORE_BASE64 }}
        run: echo \"\$K\""

# rule 2 needs exactly one release-signing claimant in every fixture tree, so
# each pass case carries a dispatch-only signing workflow alongside the case
# under test.
SIGNING_ONLY="on:
  workflow_dispatch:
permissions:
  contents: write
$SIGNING_JOB
    steps:
      - run: echo hi"

check pass "scheduled workflow reading no secrets, no self-hosted runner" \
"on:
  schedule:
    - cron: '0 3 * * *'
permissions:
  contents: read
jobs:
  r:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi" \
"$SIGNING_ONLY"

check fail "push-triggered self-hosted provisioning workflow" \
"on:
  push:
    branches: [main]
  workflow_dispatch:
permissions:
  contents: read
jobs:
  provision:
    runs-on: [self-hosted, macOS, X64]
    steps:
      - run: bash scripts/macos/provision-runner.sh"

check pass "dispatch-only self-hosted provisioning workflow" \
"on:
  workflow_dispatch:
permissions:
  contents: read
concurrency:
  group: macos-provision
  cancel-in-progress: false
jobs:
  provision:
    runs-on: [self-hosted, macOS, X64]
    steps:
      - run: bash scripts/macos/provision-runner.sh" \
"$SIGNING_ONLY"

# Rule 5 (AUT-4864). The AUT-4864 shape is a step that writes `set -uo pipefail`
# — dropping the `-e` it never actually had, because the Actions default shell
# is `bash -e {0}`. Without `continue-on-error: true` the step still gates the
# job on its exit code and aborts on the first probe of an absent path.
check fail "diagnostic step disables errexit, no continue-on-error" \
"on:
  workflow_dispatch:
$SIGNING_JOB
    steps:
      - name: Probe host
        run: |
          set -uo pipefail
          ls -1 ~/Library/LaunchAgents/ 2>&1 | head -20"

check pass "diagnostic step disables errexit but sets continue-on-error" \
"on:
  workflow_dispatch:
$SIGNING_JOB
    steps:
      - name: Probe host
        continue-on-error: true
        run: |
          set -uo pipefail
          ls -1 ~/Library/LaunchAgents/ 2>&1 | head -20"

check pass "set -euo pipefail keeps errexit on" \
"on:
  workflow_dispatch:
$SIGNING_JOB
    steps:
      - name: Build
        run: |
          set -euo pipefail
          flutter build apk"

check pass "set -uo pipefail mentioned only in a comment" \
"on:
  workflow_dispatch:
$SIGNING_JOB
    steps:
      - name: Build
        # historical note: this used to say set -uo pipefail here
        run: |
          set -euo pipefail
          flutter build apk"

check fail "set +e also needs continue-on-error" \
"on:
  workflow_dispatch:
$SIGNING_JOB
    steps:
      - name: Probe host
        run: |
          set +e
          whoami"

# A diagnostic step next to a step that legitimately depends on errexit must
# not drag the real step into the rule — the check is scoped per step.
check fail "diagnostic step unguarded beside a strict build step" \
"on:
  workflow_dispatch:
$SIGNING_JOB
    steps:
      - name: Probe host
        run: |
          set -uo pipefail
          xcodebuild -version
      - name: Build
        run: |
          set -euo pipefail
          flutter build apk"

echo "passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]]
# AUT-4876 F1: a nested list inside `run:` used to split the step and drop the
# trailing continue-on-error, flagging a correct workflow.
check pass "continue-on-error survives a nested list in run:" \
"on:
  workflow_dispatch:
$SIGNING_JOB
    steps:
      - name: Probe host
        run: |
          set -uo pipefail
          for p in - a - b; do
            ls -1 \"\$p\"
          done
        continue-on-error: true"

# AUT-4876 F2: quoted and expression-valued continue-on-error are the same intent.
check pass "quoted continue-on-error: 'true' counts" \
"on:
  workflow_dispatch:
$SIGNING_JOB
    steps:
      - name: Probe host
        run: |
          set -uo pipefail
          whoami
        continue-on-error: 'true'"

check pass "continue-on-error: \${{ ... }} counts" \
"on:
  workflow_dispatch:
$SIGNING_JOB
    steps:
      - name: Probe host
        run: |
          set -uo pipefail
          whoami
        continue-on-error: \${{ true }}"

# Guard against over-widening: 'true-ish' is not a true value.
check fail "continue-on-error: true-ish is not honoured" \
"on:
  workflow_dispatch:
$SIGNING_JOB
    steps:
      - name: Probe host
        run: |
          set -uo pipefail
          whoami
        continue-on-error: true-ish"
