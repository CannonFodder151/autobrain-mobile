#!/usr/bin/env bash
#
# Auto-increment versionCode if it conflicts with Play Console.
# Queries the Play API for the latest versionCode on the closed-testing track
# and returns the next available versionCode (max(local, remote) + 1).
#
# Usage:
#   scripts/bump-versioncode-if-conflict.sh <current-version-code> [track]
#
# Env:
#   GOOGLE_PLAY_SERVICE_ACCOUNT_JSON   (required) service-account JSON string.
#   SERVICE_ACCOUNT_JSON_FILE          (alt) path to that JSON file.
#   PLAY_PACKAGE_NAME                  (optional) default com.autobrainservice.app
#   PLAY_TRACK                         (optional) default "alpha" (closed testing)
#   PLAY_API_BASE                      (optional) API base URL.
#   GITHUB_OUTPUT                      (optional) if set, writes version_code=<next>
#
# Outputs (stdout): the next available versionCode (integer)
# Exits: 0 on success, non-zero on error

set -euo pipefail

CURRENT_VERSION_CODE="${1:?usage: bump-versioncode-if-conflict.sh <current-version-code> [track]}"
SOURCE_TRACK="${2:-${PLAY_TRACK:-alpha}}"

if [[ -n "${GOOGLE_PLAY_SERVICE_ACCOUNT_JSON:-}" ]]; then
  SA="${GOOGLE_PLAY_SERVICE_ACCOUNT_JSON}"
elif [[ -n "${SERVICE_ACCOUNT_JSON_FILE:-}" ]]; then
  SA="$(cat "$SERVICE_ACCOUNT_JSON_FILE")"
else
  echo "::error::GOOGLE_PLAY_SERVICE_ACCOUNT_JSON (or SERVICE_ACCOUNT_JSON_FILE) must be set" >&2
  exit 1
fi

EMAIL="$(jq -r '.client_email' <<<"$SA")"
TOKEN_URI="$(jq -r '.token_uri' <<<"$SA")"
PRIVKEY="$(jq -r '.private_key' <<<"$SA")"
[[ "$EMAIL" == "null" || "$TOKEN_URI" == "null" || "$PRIVKEY" == "null" ]] && { echo "::error::invalid service account JSON" >&2; exit 1; }

PACKAGE="${PLAY_PACKAGE_NAME:-com.autobrainservice.app}"
API_BASE="${PLAY_API_BASE:-https://androidpublisher.googleapis.com}"
BASE="$API_BASE/androidpublisher/v3/applications/$PACKAGE"
CURL=(curl -sS --retry 3 --retry-delay 2 --connect-timeout 30)

HTTP_CODE="000"
HTTP_BODY=""
req() {
  local out
  out="$("${CURL[@]}" -w $'\n%{http_code}' "$@" 2>&1)"
  HTTP_CODE="$(tail -n1 <<<"$out")"
  HTTP_BODY="$(sed '$d' <<<"$out")"
  printf '   HTTP %s: %s\n' "$HTTP_CODE" "$(head -c 300 <<<"$HTTP_BODY" | tr '\n' ' ')" >&2
}
die_http() {
  echo "::error::$1: expected HTTP $2, got $HTTP_CODE" >&2
  echo "::error::$1 response: $(head -c 500 <<<"$HTTP_BODY" | tr '\n' ' ')" >&2
  exit 1
}

# 1. OAuth token
now="$(date +%s)"
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
header="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
claims="$(printf '{"iss":"%s","scope":"https://www.googleapis.com/auth/androidpublisher","aud":"%s","iat":%s,"exp":%s}' "$EMAIL" "$TOKEN_URI" "$now" "$((now + 3600))" | b64url)"
sig="$(printf '%s.%s' "$header" "$claims" | openssl dgst -sha256 -sign <(printf '%s\n' "$PRIVKEY") -binary | b64url)"
req -m 60 -X POST "$TOKEN_URI" \
  --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
  --data-urlencode "assertion=$header.$claims.$sig"
[[ "$HTTP_CODE" == "200" ]] || die_http "OAuth token exchange" 200
token="$(jq -r '.access_token' <<<"$HTTP_BODY")"
[[ -n "$token" && "$token" != "null" ]] || { echo "::error::no access_token" >&2; exit 1; }
AUTH=(-H "Authorization: Bearer $token")

# 2. Get latest versionCode from source track
echo "== Checking latest versionCode on '$SOURCE_TRACK' track ==" >&2
req -m 60 "$BASE/tracks/$SOURCE_TRACK/releases" "${AUTH[@]}"
[[ "$HTTP_CODE" == "200" ]] || die_http "tracks.get ($SOURCE_TRACK)" 200

# Extract all versionCodes from all releases on the track
REMOTE_VERSION_CODE="$(jq -r '.releases // [] | map(.versionCodes[]? | tonumber) | max // 0' <<<"$HTTP_BODY")"
echo "latest versionCode on '$SOURCE_TRACK': $REMOTE_VERSION_CODE" >&2

# 3. Compute next versionCode
NEXT_VERSION_CODE=$(( CURRENT_VERSION_CODE > REMOTE_VERSION_CODE ? CURRENT_VERSION_CODE : REMOTE_VERSION_CODE ))
NEXT_VERSION_CODE=$(( NEXT_VERSION_CODE + 1 ))
echo "next available versionCode: $NEXT_VERSION_CODE" >&2

# 4. Output for CI
echo "$NEXT_VERSION_CODE"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "version_code=$NEXT_VERSION_CODE" >> "$GITHUB_OUTPUT"
fi