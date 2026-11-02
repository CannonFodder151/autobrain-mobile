#!/usr/bin/env bash
#
# setup-ios-signing.sh — Configure Apple iOS signing credentials for AutoBrain mobile releases.
#
# This script installs the Apple distribution certificate, provisioning profile,
# and App Store Connect API key into the GitHub Actions secrets for the
# autobrain-mobile repository. It should be run after obtaining the credentials
# from the Apple Developer portal.
#
# Prerequisites:
# - gh CLI authenticated with admin access to CannonFodder151/autobrain-mobile
# - Apple Distribution Certificate (.p12 file)
# - Provisioning Profile (.mobileprovision file, optional - can use -allowProvisioningUpdates)
# - App Store Connect API Key (.p8 file with key_id and issuer_id)
#
# Usage:
#   ./setup-ios-signing.sh <path-to-cert.p12> <cert-password> <path-to-profile.mobileprovision> <path-to-authkey.p8> <key-id> <issuer-id> <team-id>
#
# If provisioning profile is not available, pass "-" as third argument.

set -euo pipefail

REPO="CannonFodder151/autobrain-mobile"

CERT_P12="${1:?Usage: $0 <cert.p12> <cert-password> <profile.mobileprovision|-> <authkey.p8> <key-id> <issuer-id> <team-id>}"
CERT_PASSWORD="${2:?Missing cert password}"
PROVISIONING_PROFILE="${3:?Missing provisioning profile path or -}"
AUTH_KEY="${4:?Missing App Store Connect API key (.p8)}"
KEY_ID="${5:?Missing key ID}"
ISSUER_ID="${6:?Missing issuer ID}"
TEAM_ID="${7:?Missing team ID}"

if [[ ! -f "$CERT_P12" ]]; then
    echo "Error: Certificate file not found: $CERT_P12" >&2
    exit 1
fi

if [[ ! -f "$AUTH_KEY" ]]; then
    echo "Error: Auth key file not found: $AUTH_KEY" >&2
    exit 1
fi

echo "==> Encoding certificate as base64..."
CERT_P12_B64=$(base64 -w 0 "$CERT_P12")

echo "==> Setting IOS_CERT_P12_BASE64 secret..."
gh secret set IOS_CERT_P12_BASE64 --repo "$REPO" --body "$CERT_P12_B64"

echo "==> Setting IOS_CERT_PASSWORD secret..."
gh secret set IOS_CERT_PASSWORD --repo "$REPO" --body "$CERT_PASSWORD"

if [[ "$PROVISIONING_PROFILE" != "-" && -f "$PROVISIONING_PROFILE" ]]; then
    echo "==> Encoding provisioning profile as base64..."
    PROFILE_B64=$(base64 -w 0 "$PROVISIONING_PROFILE")
    echo "==> Setting IOS_PROVISIONING_PROFILE_BASE64 secret..."
    gh secret set IOS_PROVISIONING_PROFILE_BASE64 --repo "$REPO" --body "$PROFILE_B64"
else
    echo "==> No provisioning profile provided; will use xcodebuild -allowProvisioningUpdates"
    echo "==> Setting IOS_PROVISIONING_PROFILE_BASE64 to empty..."
    gh secret set IOS_PROVISIONING_PROFILE_BASE64 --repo "$REPO" --body ""
fi

echo "==> Setting IOS_TEAM_ID secret..."
gh secret set IOS_TEAM_ID --repo "$REPO" --body "$TEAM_ID"

echo "==> Preparing App Store Connect API key JSON..."
APPLE_STORE_API_KEY=$(jq -n \
    --arg key_id "$KEY_ID" \
    --arg issuer_id "$ISSUER_ID" \
    --arg private_key "$(cat "$AUTH_KEY")" \
    '{key_id: $key_id, issuer_id: $issuer_id, private_key: $private_key}')

echo "==> Setting APPLE_STORE_API_KEY secret..."
gh secret set APPLE_STORE_API_KEY --repo "$REPO" --body "$APPLE_STORE_API_KEY"

# Also set individual components for compatibility
echo "==> Setting APPLE_STORE_KEY_ID secret..."
gh secret set APPLE_STORE_KEY_ID --repo "$REPO" --body "$KEY_ID"

echo "==> Setting APPLE_STORE_ISSUER_ID secret..."
gh secret set APPLE_STORE_ISSUER_ID --repo "$REPO" --body "$ISSUER_ID"

echo ""
echo "✅ All iOS signing secrets configured for $REPO"
echo ""
echo "Next steps:"
echo "1. Verify secrets in GitHub: https://github.com/$REPO/settings/secrets/actions"
echo "2. Run the 'Diagnose iOS signing chain on macOS runner' workflow to verify the runner"
echo "3. Trigger a test release with 'Release (.ipa)' workflow (beta lane)"
