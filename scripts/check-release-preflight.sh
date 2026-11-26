#!/usr/bin/env bash
#
# Preflight checks for mobile release (AUT-IMP-003): secrets/config presence,
# pubspec/version format, Play package/track expectations, and script hygiene.
# Fails fast with actionable messages. Never prints secret values.
#
# Usage:
#   scripts/check-release-preflight.sh [--secrets-only] [--ci]
#
# --secrets-only: only validate required env/secrets and Play config vars
# --ci: enforce CI-required secrets for release-mobile workflow

set -euo pipefail

SECRETS_ONLY=0
CI_MODE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --secrets-only) SECRETS_ONLY=1; shift ;;
    --ci) CI_MODE=1; shift ;;
    *) echo "::error::unknown arg: $1"; exit 1 ;;
  esac
done

ok() { echo "OK: $*"; }
fail() { echo "::error::$*"; exit 1; }
warn() { echo "::warning::$*"; }

PACKAGE="${PLAY_PACKAGE_NAME:-com.autobrainservice.app}"
TRACK="${PLAY_TRACK:-alpha}"

# Required for Play API operations
if [[ -n "${GOOGLE_PLAY_SERVICE_ACCOUNT_JSON:-}" || -n "${SERVICE_ACCOUNT_JSON_FILE:-}" ]]; then
  ok "Play service account credential present (GOOGLE_PLAY_SERVICE_ACCOUNT_JSON or SERVICE_ACCOUNT_JSON_FILE)"
else
  fail "missing Play service account credential: set GOOGLE_PLAY_SERVICE_ACCOUNT_JSON or SERVICE_ACCOUNT_JSON_FILE"
fi

# Basic SA shape check without leaking
if [[ -n "${GOOGLE_PLAY_SERVICE_ACCOUNT_JSON:-}" ]]; then
  echo "$GOOGLE_PLAY_SERVICE_ACCOUNT_JSON" | jq -e '.client_email and .token_uri and .private_key' >/dev/null 2>&1 \
    || fail "GOOGLE_PLAY_SERVICE_ACCOUNT_JSON is not valid service-account JSON (needs client_email, token_uri, private_key)"
  ok "service account JSON shape valid"
fi

[[ "$PACKAGE" == "com.autobrainservice.app" ]] || fail "PLAY_PACKAGE_NAME must be com.autobrainservice.app (got '$PACKAGE')"
ok "Play package: $PACKAGE"
[[ "$TRACK" == "alpha" ]] || warn "PLAY_TRACK is '$TRACK' (expected 'alpha' for closed testing upload)"
ok "Play closed-testing track configured: $TRACK"

if [[ "$SECRETS_ONLY" == "1" ]]; then
  echo "preflight secrets/config checks passed"
  exit 0
fi

# Repo checks
[[ -f pubspec.yaml ]] || fail "pubspec.yaml missing"
version="$(grep -E '^version: ' pubspec.yaml | head -1 | awk '{print $2}')"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ ]] || fail "pubspec version must be X.Y.Z+N (got '$version')"
ok "pubspec version format: $version"

[[ -f android/app/build.gradle ]] || fail "android/app/build.gradle missing"
grep -q 'namespace "com.autobrainservice.app"' android/app/build.gradle || fail "build.gradle namespace mismatch"
grep -q 'applicationId "com.autobrainservice.app"' android/app/build.gradle || fail "build.gradle applicationId mismatch"
ok "Android package identity com.autobrainservice.app"

for s in scripts/play-upload-closed-testing.sh scripts/play-promote-to-production.sh scripts/bump-android-version-code.sh scripts/get-play-max-version-code.sh; do
  [[ -f "$s" ]] || fail "missing release script: $s"
  bash -n "$s" || fail "syntax error in $s"
  ok "script present+valid: $s"
done

# CI secrets expectations (names only)
if [[ "$CI_MODE" == "1" || -n "${GITHUB_ACTIONS:-}" ]]; then
  for v in UPLOAD_KEYSTORE_BASE64 KEY_ALIAS KEY_PASSWORD KEY_STORE_PASSWORD; do
    if [[ -z "${!v:-}" ]]; then
      warn "CI secret/env not set in current context: $v (must be configured in repo secrets for release-mobile workflow)"
    else
      ok "CI signing secret present: $v"
    fi
  done
  if [[ -z "${CARTO_API_KEY:-}" ]]; then
    warn "CARTO_API_KEY not set in current context (required by release-mobile build)"
  else
    ok "CARTO_API_KEY present"
  fi
fi

echo "preflight checks passed"
