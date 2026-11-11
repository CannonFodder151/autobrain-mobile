#!/usr/bin/env bash
#
# Pre-flight checks before triggering a mobile release (Android AAB build + Play upload/promote).
# Run locally or in CI to verify secrets, service-account permissions, track config, and
# versionCode availability before a release run.
#
# Usage:
#   scripts/check-release-preflight.sh [--check-version-code <vc>] [--source-track <track>] [--promote]
#
# Env:
#   GOOGLE_PLAY_SERVICE_ACCOUNT_JSON   (required) service-account JSON string.
#   SERVICE_ACCOUNT_JSON_FILE          (alt) path to that JSON file.
#   PLAY_PACKAGE_NAME                  (optional) default com.autobrainservice.app
#   PLAY_TRACK                         (optional) default "alpha" (closed testing source)
#   PLAY_FROM_TRACK                    (optional) source track for promote (default alpha)
#   PLAY_API_BASE                      (optional) API base URL.
#
# Exits 0 if all checks pass; non-zero with ::error:: output on failure.

set -euo pipefail

CHECK_VERSION_CODE=""
SOURCE_TRACK="${PLAY_FROM_TRACK:-${PLAY_TRACK:-alpha}}"
CHECK_PROMOTE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-version-code) CHECK_VERSION_CODE="${2:-}"; shift 2 ;;
    --source-track) SOURCE_TRACK="${2:-$SOURCE_TRACK}"; shift 2 ;;
    --promote) CHECK_PROMOTE="true"; shift ;;
    *) echo "::error::unknown arg: $1"; exit 1 ;;
  esac
done

TARGET_TRACK="production"

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
echo "== Pre-flight: $PACKAGE (service account: $EMAIL) =="
req -m 60 -X POST "$TOKEN_URI" \
  --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
  --data-urlencode "assertion=$header.$claims.$sig"
[[ "$HTTP_CODE" == "200" ]] || die_http "OAuth token exchange" 200
token="$(jq -r '.access_token' <<<"$HTTP_BODY")"
[[ -n "$token" && "$token" != "null" ]] || { echo "::error::no access_token"; exit 1; }
AUTH=(-H "Authorization: Bearer $token")

# 2. Check source track (alpha) exists and has releases
echo "== Checking source track '$SOURCE_TRACK' =="
req -m 60 "$BASE/tracks/$SOURCE_TRACK/releases" "${AUTH[@]}"
[[ "$HTTP_CODE" == "200" ]] || die_http "tracks.get ($SOURCE_TRACK)" 200
release_count="$(jq -r '.releases // [] | length' <<<"$HTTP_BODY")"
echo "source track '$SOURCE_TRACK' has $release_count release(s)"
if [[ -n "$CHECK_VERSION_CODE" ]]; then
  has="$(jq -r --arg vc "$CHECK_VERSION_CODE" '[.releases[].versionCodes[]?] | index($vc) != null' <<<"$HTTP_BODY")"
  if [[ "$has" == "true" ]]; then
    echo "versionCode $CHECK_VERSION_CODE present on '$SOURCE_TRACK'"
  else
    echo "::warning::versionCode $CHECK_VERSION_CODE NOT on '$SOURCE_TRACK' (will need upload first)"
  fi
fi

# 3. If promote check: verify production track exists or can be created
if [[ "$CHECK_PROMOTE" == "true" ]]; then
  echo "== Checking production track '$TARGET_TRACK' =="
  prod_probe="$(curl -sS --connect-timeout 30 -o /dev/null -w '%{http_code}' "$BASE/tracks/$TARGET_TRACK/releases" "${AUTH[@]}")"
  if [[ "$prod_probe" == "200" ]]; then
    echo "production track '$TARGET_TRACK' exists"
    req -m 60 "$BASE/tracks/$TARGET_TRACK/releases" "${AUTH[@]}"
    [[ "$HTTP_CODE" == "200" ]] || die_http "tracks.get ($TARGET_TRACK)" 200
    live_vc="$(jq -r '[.releases[]? | select(.status=="completed" or .status=="inProgress") | .versionCodes[]?] | last // empty' <<<"$HTTP_BODY")"
    if [[ -n "$live_vc" ]]; then
      echo "currently live on production: versionCode $live_vc"
    fi
  else
    echo "production track '$TARGET_TRACK' does not exist (will be created on promote) - HTTP $prod_probe"
    # Test edit create/commit flow for track creation
    req -m 60 -X POST "$BASE/edits" "${AUTH[@]}" -H "Content-Type: application/json" -d '{}'
    [[ "$HTTP_CODE" == "200" ]] || die_http "edits.insert (track-create test)" 200
    ce="$(jq -r '.id' <<<"$HTTP_BODY")"
    req -m 60 -X POST "$BASE/edits/$ce/tracks" "${AUTH[@]}" \
      -H "Content-Type: application/json" \
      -d "{\"track\":\"$TARGET_TRACK\",\"type\":\"PRODUCTION\"}"
    if [[ "$HTTP_CODE" == "200" ]]; then
      echo "track creation would succeed (test edit committed)"
      req -m 120 -X POST "$BASE/edits/$ce:commit" "${AUTH[@]}"
      [[ "$HTTP_CODE" == "200" ]] || die_http "track-create commit test" 200
    elif [[ "$HTTP_CODE" == "409" ]]; then
      echo "track already exists (race) - OK"
    else
      die_http "tracks.create ($TARGET_TRACK) test" 200
    fi
  fi
fi

# 4. Check app details (package name, bundle config)
echo "== Verifying app details =="
req -m 60 "$BASE" "${AUTH[@]}"
[[ "$HTTP_CODE" == "200" ]] || die_http "application.get" 200
app_name="$(jq -r '.name // empty' <<<"$HTTP_BODY")"
echo "app name: ${app_name:-<unknown>}"

echo "== All pre-flight checks passed =="