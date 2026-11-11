#!/usr/bin/env bash
#
# Auto-increment Android versionCode if the requested build number is <= the
# highest versionCode already known to Google Play. Prevents Play's
# "Version code N has already been used" conflict (AUT-255 / AUT-393) and
# avoids manual bump churn.
#
# Usage:
#   scripts/bump-android-version-code.sh [--apply] [--package-name NAME]
#
# Without --apply: prints the proposed versionCode and exits 0 (dry run).
# With --apply: rewrites pubspec.yaml to the bumped version and prints the
#   new RELEASE_VERSION and version_code on stdout (parseable).
#
# Env:
#   GOOGLE_PLAY_SERVICE_ACCOUNT_JSON (or SERVICE_ACCOUNT_JSON_FILE) required
#   PLAY_API_BASE (optional, for tests)
#
# Output (always):
#   RELEASE_VERSION=vX.Y.Z+N
#   version_code=N
#   semver=X.Y.Z
#   bumped=true|false

set -euo pipefail

APPLY=0
PACKAGE="${PLAY_PACKAGE_NAME:-com.autobrainservice.app}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --package-name) PACKAGE="$2"; shift 2 ;;
    *) echo "::error::unknown arg: $1"; exit 1 ;;
  esac
done

for cmd in curl jq openssl sed grep awk; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "::error::required command not found: $cmd" >&2; exit 1; }
done

PUBSPEC="pubspec.yaml"
[[ -f "$PUBSPEC" ]] || { echo "::error::$PUBSPEC not found; run from repo root" >&2; exit 1; }

current_version="$(grep -E '^version: ' "$PUBSPEC" | head -1 | awk '{print $2}')"
[[ -n "$current_version" ]] || { echo "::error::could not read version from $PUBSPEC" >&2; exit 1; }
current_semver="${current_version%%+*}"
current_build="${current_version##*+}"
[[ "$current_build" =~ ^[0-9]+$ ]] || current_build=0
current_vc="$current_build"

play_max="$(bash "$(dirname "$0")/get-play-max-version-code.sh" "$PACKAGE")"
[[ "$play_max" =~ ^[0-9]+$ ]] || play_max=0

bumped=false
new_vc="$current_vc"
if [[ "$current_vc" -le "$play_max" ]]; then
  new_vc=$((play_max + 1))
  bumped=true
fi

new_version="${current_semver}+${new_vc}"
new_tag="v${new_version}"

if [[ "$APPLY" == "1" && "$bumped" == "true" ]]; then
  sed -i -E "s/^version: .*/version: ${new_version}/" "$PUBSPEC"
  echo "==> pubspec.yaml version bumped: ${current_version} -> ${new_version}"
fi

echo "RELEASE_VERSION=${new_tag}"
echo "version_code=${new_vc}"
echo "semver=${current_semver}"
echo "bumped=${bumped}"
