#!/usr/bin/env bash
#
# Self-check for scripts/check-workflow-runner-isolation.sh. Builds throwaway
# workflow dirs in a temp tree and asserts the guard passes on the shapes we
# want and fails on each shape we are guarding against:
#
#   rule 1  pull_request trigger on a self-hosted runner        -> fail
#   rule 2  a second `release-signing` runs-on claimant         -> fail
#   rule 3  secret-reading workflow with a push trigger         -> fail
#   ok      secret-reading workflow, workflow_dispatch only     -> pass
#   ok      `${{ secrets.X }}` mentioned in a comment only      -> pass
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

echo "passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]]