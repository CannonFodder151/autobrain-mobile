#!/usr/bin/env bash
#
# Upload an Android App Bundle (.aab) to the Google Play **closed testing**
# track and submit it (commit) so the fresh build is served to testers.
#
# Usage:
#   scripts/play-upload-closed-testing.sh <app-release.aab> [track-id]
#
# Env:
#   GOOGLE_PLAY_SERVICE_ACCOUNT_JSON   (required) service-account JSON string.
#   SERVICE_ACCOUNT_JSON_FILE          (alt) path to that JSON file.
#   PLAY_PACKAGE_NAME                  (optional) default com.autobrainservice.app
#   PLAY_RELEASE_NOTES                 (optional) plain-text "what's new".
#   PLAY_TRACK                         (optional) default "testing".
#   PLAY_RELEASE_STATUS                (optional) "completed" (default) or "draft".
#   PLAY_ALLOW_DRAFT_FALLBACK          (optional) default true.
#   PLAY_LOG_FILE                      (optional) append a full transcript here
#                                      (used by CI to keep a debuggable log).
#   GITHUB_OUTPUT                      (optional) when set and a tester audience
#                                      is required, appends
#                                      needs_tester_audience=true.
#
# Notes:
# - Closed testing tracks have custom names (no fixed API default). If the
#   configured track does not exist it is created once as CLOSED_TESTING in
#   its own committed edit, then the build is released onto it.
# - Play rejects a "completed" release on a closed testing track when the track
#   has no tester audience ("Release in track targeting no countries"). With
#   PLAY_ALLOW_DRAFT_FALLBACK=true the script then commits the release as a
#   draft (still versionCode-visible on the track, ready to roll out from the
#   Play Console once testers are configured).
# - Committing the edit is what "submits for review" to Google Play.
# - Every HTTP failure prints its status code + response body to stderr and
#   fails with a ::error:: line so GitHub shows the cause directly.
# Never prints the service-account JSON or any secrets. Requires: bash, curl,
# jq, openssl (all present on ubuntu-latest GitHub runners).

set -euo pipefail

AAB="${1:?usage: play-upload-closed-testing.sh <app-release.aab> [track-id]}"
[[ -f "$AAB" ]] || { echo "::error::AAB not found: $AAB"; exit 1; }
TRACK="${2:-${PLAY_TRACK:-testing}}"
PACKAGE="${PLAY_PACKAGE_NAME:-com.autobrainservice.app}"
NOTES="${PLAY_RELEASE_NOTES:-}"
STATUS="${PLAY_RELEASE_STATUS:-completed}"
ALLOW_FALLBACK="${PLAY_ALLOW_DRAFT_FALLBACK:-true}"
[[ "$STATUS" == "completed" || "$STATUS" == "draft" ]] || { echo "::error::PLAY_RELEASE_STATUS must be completed or draft"; exit 1; }

# Every step is mirrored to PLAY_LOG_FILE (CI keeps the runner-local log so a
# collapse-free copy of this transcript survives on disk for debugging).
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

BASE="https://androidpublisher.googleapis.com/androidpublisher/v3/applications/$PACKAGE"
UPLOAD_BASE="https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/$PACKAGE"
# --retry-all-errors requires curl >= 7.71 (missing on older self-hosted runners);
# plain --retry already covers transient HTTP 5xx/429 and network hiccups.
CURL=(curl -sS --retry 3 --retry-delay 2 --connect-timeout 30)
CURL_NF=(curl -sS --connect-timeout 30)

# req runs curl, prints the HTTP status + body, and returns the body on stdout.
# Global HTTP_CODE holds the status; global HTTP_BODY holds the response body.
HTTP_CODE="000"
HTTP_BODY=""
req() {
  local -a args=("$@")
  local out code
  out="$("${CURL[@]}" -w $'\n%{http_code}' "${args[@]}" 2>&1)"
  HTTP_CODE="$(tail -n1 <<<"$out")"
  HTTP_BODY="$(sed '$d' <<<"$out")"
  printf '   HTTP %s: %s\n' "$HTTP_CODE" "$(head -c 300 <<<"$HTTP_BODY" | tr '\n' ' ')" >&2
}

# die_http fails the step loudly when a call returned an unexpected status.
die_http() {
  local label="$1" expected="$2"
  echo "::error::$label: expected HTTP $expected, got $HTTP_CODE" >&2
  echo "::error::$label response: $(head -c 500 <<<"$HTTP_BODY" | tr '\n' ' ')" >&2
  exit 1
}

# 1. OAuth2 access token via RS256 JWT (scope: androidpublisher)
now="$(date +%s)"
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
header="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
claims="$(printf '{"iss":"%s","scope":"https://www.googleapis.com/auth/androidpublisher","aud":"%s","iat":%s,"exp":%s}' "$EMAIL" "$TOKEN_URI" "$now" "$((now + 3600))" | b64url)"
sig="$(printf '%s.%s' "$header" "$claims" | openssl dgst -sha256 -sign <(printf '%s\n' "$PRIVKEY") -binary | b64url)"
echo "== Play upload: $PACKAGE -> track $TRACK (aab $(du -h "$AAB" | cut -f1)) =="
req -m 60 -X POST "$TOKEN_URI" \
  --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
  --data-urlencode "assertion=$header.$claims.$sig"
[[ "$HTTP_CODE" == "200" ]] || die_http "OAuth token exchange" 200
token="$(jq -r '.access_token' <<<"$HTTP_BODY")"
[[ -n "$token" && "$token" != "null" ]] || { echo "::error::OAuth token exchange returned no access_token"; exit 1; }
AUTH=(-H "Authorization: Bearer $token")

# 2. Open the main edit
req -m 60 -X POST "$BASE/edits" "${AUTH[@]}" -H "Content-Type: application/json" -d '{}'
[[ "$HTTP_CODE" == "200" ]] || die_http "edits.insert (main)" 200
edit_id="$(jq -r '.id' <<<"$HTTP_BODY")"
[[ -n "$edit_id" && "$edit_id" != "null" ]] || { echo "::error::edits.insert returned no id"; exit 1; }
EDIT="$BASE/edits/$edit_id"

# 3. Ensure the closed testing track exists — create it in its own committed
#    edit if missing (creating + releasing in a single edit made commit 500).
req -m 60 -X POST "$BASE/edits" "${AUTH[@]}" -H "Content-Type: application/json" -d '{}'
[[ "$HTTP_CODE" == "200" ]] || die_http "edits.insert (probe)" 200
probe_edit="$(jq -r '.id' <<<"$HTTP_BODY")"
req -m 60 "$BASE/edits/$probe_edit/tracks" "${AUTH[@]}"
[[ "$HTTP_CODE" == "200" ]] || die_http "tracks.list (probe)" 200
track_ids="$(jq -r '[.tracks[]?.track] | join(",")' <<<"$HTTP_BODY")"
if [[ ",$track_ids," != *",$TRACK,"* ]]; then
  echo "track '$TRACK' not found — creating closed testing track"
  req -m 60 -X POST "$BASE/edits/$probe_edit/tracks" "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    -d "{\"track\":\"$TRACK\",\"type\":\"CLOSED_TESTING\",\"formFactor\":\"DEFAULT\"}"
  [[ "$HTTP_CODE" == "200" ]] || die_http "tracks.create ($TRACK)" 200
  req -m 120 -X POST "$BASE/edits/$probe_edit:commit" "${AUTH[@]}"
  [[ "$HTTP_CODE" == "200" ]] || die_http "track-create edit commit" 200
  echo "closed testing track '$TRACK' created"
else
  "${CURL[@]}" -m 60 -X DELETE "$BASE/edits/$probe_edit" "${AUTH[@]}" >/dev/null 2>&1 || true
fi

# 4. Upload the AAB (media upload goes to the /upload/ host)
req -m 600 -X POST "$UPLOAD_BASE/edits/$edit_id/bundles?uploadType=media" "${AUTH[@]}" \
  -H "Content-Type: application/octet-stream" --data-binary "@$AAB"
[[ "$HTTP_CODE" == "200" ]] || die_http "bundle upload" 200
version_code="$(jq -r '.versionCode' <<<"$HTTP_BODY")"
[[ -n "$version_code" && "$version_code" != "null" ]] || { echo "::error::bundle upload returned no versionCode"; exit 1; }
echo "uploaded $AAB -> versionCode $version_code"

# 5. Assign it to the closed testing track
release="{\"releases\":[{\"name\":\"$TRACK-$version_code\",\"versionCodes\":[\"$version_code\"],\"status\":\"$STATUS\""
if [[ -n "$NOTES" ]]; then
  notes_json="$(jq -n --arg t "$NOTES" '[{"language":"en-US","text":$t}]')"
  release="$release,\"releaseNotes\":$notes_json"
fi
release="$release}]}"
track_body="$(jq -n --argjson r "$release" '{releases:$r}')"
req -m 60 -X PUT "$EDIT/tracks/$TRACK" "${AUTH[@]}" \
  -H "Content-Type: application/json" -d "$track_body"
[[ "$HTTP_CODE" == "200" ]] || die_http "tracks.update ($TRACK)" 200

# 6. Commit the edit — this is "submitting the changes for review" to Google.
#    The commit call intentionally has no --retry/-f so its 403/400 bodies can
#    be inspected before deciding on the draft fallback.
commit_success=false
commit_out="$("${CURL_NF[@]}" -m 300 -w $'\n%{http_code}' -X POST "$EDIT:commit" "${AUTH[@]}")"
commit_code="$(tail -1 <<<"$commit_out")"
commit_body="$(sed '$d' <<<"$commit_out")"
echo "   commit HTTP: $commit_code" >&2
if [[ "$commit_code" == "200" ]]; then
  commit_success=true
elif [[ "$commit_code" == "403" && "$STATUS" == "completed" && "$ALLOW_FALLBACK" == "true" ]] \
  && grep -q "targeting no countries" <<<"$commit_body"; then
  echo "::warning::Play refuses 'completed' (submit-for-review) on closed testing track '$TRACK' without a tester audience ('targeting no countries'); committing as draft. Once a tester group + country availability are configured on the track in Play Console, the same pipeline auto-submits for review with no code change."
  echo "::warning::ASK-NATHAN: Play Console -> Testing -> Closed testing -> $TRACK -> add testers (emails or a Google Group) and set country availability (restOfWorld on). One-time setup; after that every release lands as 'completed' (submitted for review)."
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "needs_tester_audience=true" >> "$GITHUB_OUTPUT"
  fi
  STATUS="draft"
  release="${release/\"completed\"/\"draft\"}"
  track_body="$(jq -n --argjson r "$release" '{releases:$r}')"
  req -m 60 -X PUT "$EDIT/tracks/$TRACK" "${AUTH[@]}" \
    -H "Content-Type: application/json" -d "$track_body"
  [[ "$HTTP_CODE" == "200" ]] || die_http "tracks.update ($TRACK) as draft" 200
  "${CURL_NF[@]}" -m 300 -X POST "$EDIT:commit" "${AUTH[@]}" >/dev/null
  commit_success=true
else
  echo "::error::edit commit failed (HTTP $commit_code): $(head -c 500 <<<"$commit_body" | tr '\n' ' ')"
  exit 1
fi

# 7. Verify the release landed on the track (fresh edit, read POST-commit state)
req -m 60 -X POST "$BASE/edits" "${AUTH[@]}" -H "Content-Type: application/json" -d '{}'
[[ "$HTTP_CODE" == "200" ]] || die_http "edits.insert (verify)" 200
verify_edit="$(jq -r '.id' <<<"$HTTP_BODY")"
req -m 60 "$BASE/edits/$verify_edit/tracks/$TRACK" "${AUTH[@]}"
[[ "$HTTP_CODE" == "200" ]] || die_http "tracks.get verify ($TRACK)" 200
vc_on_track="$(jq -r --arg vc "$version_code" '[.releases[].versionCodes[]?] | index($vc) != null' <<<"$HTTP_BODY")"
[[ "$vc_on_track" == "true" ]] || { echo "::error::versionCode $version_code not visible on track '$TRACK' after commit"; exit 1; }
echo "closed testing ($TRACK) release OK: versionCode $version_code — status $STATUS, committed for review"
