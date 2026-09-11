#!/usr/bin/env bash
# setup-ios-signing.sh — Encode and upload Apple code-signing secrets to GitHub.
#
# Prerequisites:
#   1. Apple Developer Portal: create + download distribution certificate (.cer → .p12)
#   2. Apple Developer Portal: create + download provisioning profile (.mobileprovision)
#   3. App Store Connect → Users and Access → Keys: create API key, download .p8
#   4. `gh` CLI authenticated with repo push access
#
# Usage:
#   ./scripts/setup-ios-signing.sh \
#     --p12 /path/to/dist.p12 \
#     --p12-password "my-password" \
#     --profile /path/to/profile.mobileprovision \
#     --team-id XXXXXXXXXX \
#     --api-key /path/to/AuthKey_XXX.p8.json \
#     [--repo CannonFodder151/autobrain-mobile] \
#     [--export-method app-store]
#
# The API key JSON should contain: {"key_id":"...","issuer_id":"...","private_key":"...","username":"..."}

set -euo pipefail

REPO="${REPO:-CannonFodder151/autobrain-mobile}"
EXPORT_METHOD="app-store"
P12=""
P12_PASSWORD=""
PROFILE=""
TEAM_ID=""
API_KEY=""
PROVISIONING_PROFILE_SPECIFIER=""

usage() {
  sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# //'
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --p12) P12="$2"; shift 2 ;;
    --p12-password) P12_PASSWORD="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --team-id) TEAM_ID="$2"; shift 2 ;;
    --api-key) API_KEY="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --export-method) EXPORT_METHOD="$2"; shift 2 ;;
    --profile-specifier) PROVISIONING_PROFILE_SPECIFIER="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

missing=()
[[ -z "$P12" ]] && missing+=("--p12")
[[ -z "$P12_PASSWORD" ]] && missing+=("--p12-password")
[[ -z "$PROFILE" ]] && missing+=("--profile")
[[ -z "$TEAM_ID" ]] && missing+=("--team-id")
[[ -z "$API_KEY" ]] && missing+=("--api-key")
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Missing required arguments: ${missing[*]}"
  usage
fi

[[ -f "$P12" ]] || { echo "::error::P12 file not found: $P12"; exit 1; }
[[ -f "$PROFILE" ]] || { echo "::error::Provisioning profile not found: $PROFILE"; exit 1; }
[[ -f "$API_KEY" ]] || { echo "::error::API key JSON not found: $API_KEY"; exit 1; }

# Auto-detect profile specifier from the provisioning profile if not provided
if [[ -z "$PROVISIONING_PROFILE_SPECIFIER" ]]; then
  PROVISIONING_PROFILE_SPECIFIER=$(security cms -D -i "$PROFILE" 2>/dev/null \
    | plutil -convert json - -o - 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('Name',''))" 2>/dev/null || true)
  if [[ -z "$PROVISIONING_PROFILE_SPECIFIER" ]]; then
    echo "::warning::Could not auto-detect profile name. Set --profile-specifier manually."
    PROVISIONING_PROFILE_SPECIFIER="autobrain_distribution"
  fi
  echo "Detected provisioning profile specifier: $PROVISIONING_PROFILE_SPECIFIER"
fi

echo "Setting GitHub Actions secrets on $REPO ..."
echo "  Team ID:              $TEAM_ID"
echo "  Export method:        $EXPORT_METHOD"
echo "  Profile specifier:    $PROVISIONING_PROFILE_SPECIFIER"

# Base64 encode and upload
P12_B64=$(base64 < "$P12" | tr -d '\n')
PROFILE_B64=$(base64 < "$PROFILE" | tr -d '\n')

gh secret set IOS_CERT_P12_BASE64       --body "$P12_B64"             --repo "$REPO"
gh secret set IOS_CERT_PASSWORD          --body "$P12_PASSWORD"        --repo "$REPO"
gh secret set IOS_PROVISIONING_PROFILE_BASE64 --body "$PROFILE_B64"   --repo "$REPO"
gh secret set IOS_TEAM_ID                --body "$TEAM_ID"             --repo "$REPO"
gh secret set IOS_EXPORT_METHOD          --body "$EXPORT_METHOD"       --repo "$REPO"
gh secret set IOS_PROVISIONING_PROFILE_SPECIFIER --body "$PROVISIONING_PROFILE_SPECIFIER" --repo "$REPO"
gh secret set APPLE_STORE_API_KEY        --body "$(cat "$API_KEY")"    --repo "$REPO"

echo ""
echo "All 7 iOS signing secrets configured on $REPO."
echo "Next: trigger release-ios.yml workflow_dispatch to build + upload to TestFlight."
