#!/usr/bin/env bash
#
# Promote an existing closed-testing release to Google Play **production**.
#
# Usage:
#   scripts/play-promote-to-production.sh [versionCode] [source-track]
#
# If versionCode is omitted, the latest versionCode on source-track (default
# "alpha") is promoted. The .aab must already be uploaded (via the closed-
# testing upload script) and visible on source-track.
#
# Env:
#   GOOGLE_PLAY_SERVICE_ACCOUNT_JSON   (required) service-account JSON string.
#   SERVICE_ACCOUNT_JSON_FILE          (alt) path to that JSON file.
#   PLAY_PACKAGE_NAME                  (optional) default com.autobrainservice.app
#   PLAY_TRACK                         (optional) override target track (default production).
#   PLAY_FROM_TRACK                    (optional) source track for versionCode (default alpha).
#   PLAY_RELEASE_NOTES                 (optional) plain-text "what's new".
#   PLAY_ROLLOUT_FRACTION              (optional) 0<frac<=1. Default 0.1 (10%).
#                                      Uses status=inProgress with userFraction.
#                                      Set to 1 for immediate full rollout (completed).
#   PLAY_API_BASE                      (optional) API base URL.
#   PLAY_LOG_FILE                      (optional) append transcript.
#
# Staged rollout (AUT-322): default 10% (inProgress). To advance, re-run with
# PLAY_ROLLOUT_FRACTION=0.5 then 1.0 (or manage in Play Console). There is NO
# draft fallback here: if Play rejects, the script fails so the cause surfaces.

set -euo pipefail

TARGET_TRACK="${PLAY_TRACK:-production}"
SOURCE_TRACK="${PLAY_FROM_TRACK:-alpha}"
PACKAGE="${PLAY_PACKAGE_NAME:-com.autobrainservice.app}"
NOTES="${PLAY_RELEASE_NOTES:-}"
ROLLOUT_FRACTION="${PLAY_ROLLOUT_FRACTION:-0.1}"
VERSION_CODE_ARG="${1:-}"
SOURCE_TRACK_ARG="${2:-$SOURCE_TRACK}"

# Allow source track override via second positional
if [[ -n "${2:-}" ]]; then SOURCE_TRACK="${2}"; fi
SOURCE_TRACK="${SOURCE_TRACK:-$SOURCE_TRACK_ARG}"

if [[ -n "${PLAY_LOG_FILE:-}" ]]; then
  exec > >(tee -a "$PLAY_LOG_FILE") 2>&1
fi

if [[ -n "${GOOGLE_PLAY_SERVICE_ACCOUNT_JSON:-}" ]]; then
  SA="${GOOGLE_PLAY_SERVICE_ACCOUNT_JSON}"
elif [[ -n "${SERVICE_ACCOUNT_JSON_FILE:-}" ]]; then
  SA="$(cat "$SERVICE_ACCOUNT_JSON_FILE")"
else
  echo "::error::GOOGLE_PLAY_SERVICE_ACCOUNT_JSON (or SERVICE_ACCOUNT_JSON_FILE) must be set"
  exit 1
fi

EMAIL="$(jq -r '.client_email' <<<"$SA")"
TOKEN_URI="$(jq -r '.token_uri' <<<"$SA")"
PRIVKEY="$(jq -r '.private_key' <<<"$SA")"
[[ "$EMAIL" == "null" || "$TOKEN_URI" == "null" || "$PRIVKEY" == "null" ]] && { echo "::error::invalid service account JSON"; exit 1; }

API_BASE="${PLAY_API_BASE:-https://androidpublisher.googleapis.com}"
BASE="$API_BASE/androidpublisher/v3/applications/$PACKAGE"
CURL=(curl -sS --retry 3 --retry-delay 2 --connect-timeout 30)
CURL_NF=(curl -sS --connect-timeout 30)

HTTP_CODE="000"; HTTP_BODY=""
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
[[ -n "$token" && "$token" != "null" ]] || { echo "::error::no access_token"; exit 1; }
AUTH=(-H "Authorization: Bearer $token")

# 2. Resolve versionCode
if [[ -z "$VERSION_CODE_ARG" ]]; then
  echo "== resolving latest versionCode on source track '$SOURCE_TRACK' =="
  req -m 60 "$BASE/tracks/$SOURCE_TRACK/releases" "${AUTH[@]}"
  [[ "$HTTP_CODE" == "200" ]] || die_http "tracks.get ($SOURCE_TRACK)" 200
  VERSION_CODE_ARG="$(jq -r '.releases | map(.versionCodes[]?) | last // empty' <<<"$HTTP_BODY")"
  [[ -n "$VERSION_CODE_ARG" ]] || { echo "::error::no releases found on source track '$SOURCE_TRACK'"; exit 1; }
  echo "resolved versionCode $VERSION_CODE_ARG from '$SOURCE_TRACK'"
fi
VERSION_CODE="$VERSION_CODE_ARG"

# 3. Pre-flight: source track must contain it
req -m 60 "$BASE/tracks/$SOURCE_TRACK/releases" "${AUTH[@]}"
[[ "$HTTP_CODE" == "200" ]] || die_http "tracks.get ($SOURCE_TRACK)" 200
src_has="$(jq -r --arg vc "$VERSION_CODE" '[.releases[].versionCodes[]?] | index($vc) != null' <<<"$HTTP_BODY")"
[[ "$src_has" == "true" ]] || { echo "::error::versionCode $VERSION_CODE not found on source track '$SOURCE_TRACK'"; exit 1; }
echo "pre-flight OK: versionCode $VERSION_CODE present on '$SOURCE_TRACK'"

# 4. Pre-flight: production track state
prod_probe="$(curl -sS --connect-timeout 30 -o /dev/null -w '%{http_code}' "$BASE/tracks/$TARGET_TRACK/releases" "${AUTH[@]}")"
if [[ "$prod_probe" != "200" ]]; then
  echo "target track '$TARGET_TRACK' missing — creating as PRODUCTION"
  req -m 60 -X POST "$BASE/edits" "${AUTH[@]}" -H "Content-Type: application/json" -d '{}'
  [[ "$HTTP_CODE" == "200" ]] || die_http "edits.insert (track-create)" 200
  ce="$(jq -r '.id' <<<"$HTTP_BODY")"
  req -m 60 -X POST "$BASE/edits/$ce/tracks" "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    -d "{\"track\":\"$TARGET_TRACK\",\"type\":\"PRODUCTION\"}"
  [[ "$HTTP_CODE" == "200" ]] || die_http "tracks.create ($TARGET_TRACK)" 200
  req -m 120 -X POST "$BASE/edits/$ce:commit" "${AUTH[@]}"
  [[ "$HTTP_CODE" == "200" ]] || die_http "track-create commit" 200
  echo "production track created"
fi

req -m 60 "$BASE/tracks/$TARGET_TRACK/releases" "${AUTH[@]}"
[[ "$HTTP_CODE" == "200" ]] || die_http "tracks.get ($TARGET_TRACK)" 200
live_vc="$(jq -r '[.releases[]? | select(.status=="completed" or .status=="inProgress") | .versionCodes[]?] | last // empty' <<<"$HTTP_BODY")"
if [[ -n "$live_vc" && "$live_vc" != "$VERSION_CODE" ]]; then
  echo "::warning::production currently has versionCode $live_vc live; promoting $VERSION_CODE will replace it"
fi
already="$(jq -r --arg vc "$VERSION_CODE" '[.releases[].versionCodes[]?] | index($vc) != null' <<<"$HTTP_BODY")"
echo "production already contains $VERSION_CODE: $already"

# 5. Open main edit
req -m 60 -X POST "$BASE/edits" "${AUTH[@]}" -H "Content-Type: application/json" -d '{}'
[[ "$HTTP_CODE" == "200" ]] || die_http "edits.insert (main)" 200
edit_id="$(jq -r '.id' <<<"$HTTP_BODY")"
EDIT="$BASE/edits/$edit_id"

# 6. Promote to production (staged rollout by default, AUT-322)
STATUS="inProgress"
UF=""
if python3 - "$ROLLOUT_FRACTION" <<'PY'
import sys
try: f=float(sys.argv[1])
except: sys.exit(1)
sys.exit(0 if f >= 1.0 else 1)
PY
then
  STATUS="completed"
else
  UF="$ROLLOUT_FRACTION"
fi

release="{\"releases\":[{\"name\":\"production-$VERSION_CODE\",\"versionCodes\":[\"$VERSION_CODE\"],\"status\":\"$STATUS\""
if [[ -n "$UF" ]]; then
  release="$release,\"userFraction\":$UF"
fi
if [[ -n "$NOTES" ]]; then
  notes_json="$(jq -n --arg t "$NOTES" '[{"language":"en-US","text":$t}]')"
  release="$release,\"releaseNotes\":$notes_json"
fi
release="$release}]}"
req -m 60 -X PUT "$EDIT/tracks/$TARGET_TRACK" "${AUTH[@]}" \
  -H "Content-Type: application/json" -d "$release"
[[ "$HTTP_CODE" == "200" ]] || die_http "tracks.update ($TARGET_TRACK)" 200

# 7. Commit — NO draft fallback
commit_out="$("${CURL_NF[@]}" -m 300 -w $'\n%{http_code}' -X POST "$EDIT:commit" "${AUTH[@]}")"
commit_code="$(tail -1 <<<"$commit_out")"
commit_body="$(sed '$d' <<<"$commit_out")"
echo "   commit HTTP: $commit_code" >&2
if [[ "$commit_code" != "200" ]]; then
  echo "::error::production commit failed (HTTP $commit_code): $(head -c 500 <<<"$commit_body" | tr '\n' ' ')"
  exit 1
fi
echo "production release committed"

# 8. Verify
req -m 60 -X POST "$BASE/edits" "${AUTH[@]}" -H "Content-Type: application/json" -d '{}'
[[ "$HTTP_CODE" == "200" ]] || die_http "edits.insert (verify)" 200
verify_edit="$(jq -r '.id' <<<"$HTTP_BODY")"
req -m 60 "$BASE/edits/$verify_edit/tracks/$TARGET_TRACK" "${AUTH[@]}"
[[ "$HTTP_CODE" == "200" ]] || die_http "tracks.get verify" 200
vc_on_track="$(jq -r --arg vc "$VERSION_CODE" '[.releases[].versionCodes[]?] | index($vc) != null' <<<"$HTTP_BODY")"
[[ "$vc_on_track" == "true" ]] || { echo "::error::versionCode $VERSION_CODE not visible on production after commit"; exit 1; }
"${CURL_NF[@]}" -m 60 -X DELETE "$BASE/edits/$verify_edit" "${AUTH[@]}" >/dev/null 2>&1 || true
if [[ "$STATUS" == "completed" ]]; then
  echo "production release OK: versionCode $VERSION_CODE fully rolled out (100%)"
else
  echo "production release OK: versionCode $VERSION_CODE staged rollout userFraction=$UF (advance via PLAY_ROLLOUT_FRACTION 0.5/1.0)"
fi
