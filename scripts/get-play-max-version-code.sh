#!/usr/bin/env bash
#
# Query Google Play AndroidPublisher API for the highest versionCode currently
# known across all tracks for the app. Used to auto-increment versionCode in CI
# and avoid 255/conflict rejections.
#
# Usage:
#   scripts/get-play-max-version-code.sh [package-name]
#
# Env:
#   GOOGLE_PLAY_SERVICE_ACCOUNT_JSON (or SERVICE_ACCOUNT_JSON_FILE) required
#   PLAY_API_BASE (optional, for tests) default https://androidpublisher.googleapis.com
#
# Output: prints max versionCode (integer) to stdout. Exits non-zero on error.

set -euo pipefail

PACKAGE="${1:-${PLAY_PACKAGE_NAME:-com.autobrainservice.app}}"

if [[ -n "${GOOGLE_PLAY_SERVICE_ACCOUNT_JSON:-}" ]]; then
  SA="${GOOGLE_PLAY_SERVICE_ACCOUNT_JSON}"
elif [[ -n "${SERVICE_ACCOUNT_JSON_FILE:-}" ]]; then
  SA="$(cat "$SERVICE_ACCOUNT_JSON_FILE")"
else
  echo "::error::GOOGLE_PLAY_SERVICE_ACCOUNT_JSON (or SERVICE_ACCOUNT_JSON_FILE) must be set" >&2
  exit 1
fi

for cmd in curl jq openssl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "::error::required command not found: $cmd" >&2; exit 1; }
done

EMAIL="$(jq -r '.client_email' <<<"$SA")"
TOKEN_URI="$(jq -r '.token_uri' <<<"$SA")"
PRIVKEY="$(jq -r '.private_key' <<<"$SA")"
[[ "$EMAIL" == "null" || "$TOKEN_URI" == "null" || "$PRIVKEY" == "null" ]] && { echo "::error::invalid service account JSON" >&2; exit 1; }

API_BASE="${PLAY_API_BASE:-https://androidpublisher.googleapis.com}"
BASE="$API_BASE/androidpublisher/v3/applications/$PACKAGE"
CURL=(curl -sS --retry 3 --retry-delay 2 --connect-timeout 30)

now="$(date +%s)"
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
header="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
claims="$(printf '{"iss":"%s","scope":"https://www.googleapis.com/auth/androidpublisher","aud":"%s","iat":%s,"exp":%s}' "$EMAIL" "$TOKEN_URI" "$now" "$((now + 3600))" | b64url)"
sig="$(printf '%s.%s' "$header" "$claims" | openssl dgst -sha256 -sign <(printf '%s\n' "$PRIVKEY") -binary | b64url)"

out="$("${CURL[@]}" -m 60 -w $'\n%{http_code}' -X POST "$TOKEN_URI" \
  --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
  --data-urlencode "assertion=$header.$claims.$sig")"
code="$(tail -n1 <<<"$out")"
body="$(sed '$d' <<<"$out")"
[[ "$code" == "200" ]] || { echo "::error::OAuth token exchange failed (HTTP $code): $(head -c 300 <<<"$body" | tr '\n' ' ')" >&2; exit 1; }
token="$(jq -r '.access_token' <<<"$body")"
[[ -n "$token" && "$token" != "null" ]] || { echo "::error::no access_token in OAuth response" >&2; exit 1; }
AUTH=(-H "Authorization: Bearer $token")

# Insert an edit, read all tracks, delete edit. Play requires an edit context
# for tracks.list in some client flows; this is safe/read-only.
out="$("${CURL[@]}" -m 60 -w $'\n%{http_code}' -X POST "$BASE/edits" "${AUTH[@]}" -H "Content-Type: application/json" -d '{}')"
code="$(tail -n1 <<<"$out")"
body="$(sed '$d' <<<"$out")"
[[ "$code" == "200" ]] || { echo "::error::edits.insert failed (HTTP $code): $(head -c 300 <<<"$body" | tr '\n' ' ')" >&2; exit 1; }
edit_id="$(jq -r '.id' <<<"$body")"
[[ -n "$edit_id" && "$edit_id" != "null" ]] || { echo "::error::edits.insert returned no id" >&2; exit 1; }

cleanup() { "${CURL[@]}" -m 30 -X DELETE "$BASE/edits/$edit_id" "${AUTH[@]}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

out="$("${CURL[@]}" -m 60 -w $'\n%{http_code}' "$BASE/edits/$edit_id/tracks" "${AUTH[@]}")"
code="$(tail -n1 <<<"$out")"
body="$(sed '$d' <<<"$out")"
[[ "$code" == "200" ]] || { echo "::error::tracks.list failed (HTTP $code): $(head -c 300 <<<"$body" | tr '\n' ' ')" >&2; exit 1; }

max_vc="$(jq -r '
  [ .tracks[]?.releases[]? |
    (
      [ .versionCodes[]? ]
      + [ .activeArtifacts[]?.versionCode ]
      + [ .releaseCodes[]? ]
    )[] | tonumber
  ] | if length == 0 then 0 else max end
' <<<"$body" 2>/dev/null || echo 0)"

[[ "$max_vc" =~ ^[0-9]+$ ]] || max_vc=0
echo "$max_vc"
