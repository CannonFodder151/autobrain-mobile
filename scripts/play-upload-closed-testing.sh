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
#   PLAY_TRACK                         (optional) default "alpha" — the existing
#                                      Alpha track (has testers). A missing track
#                                      is created as CLOSED_TESTING in its own
#                                      committed edit so a fresh Play Console is not a stop.
#   PLAY_RELEASE_STATUS                (optional) "completed" (default) or "draft".
#   PLAY_ALLOW_DRAFT_FALLBACK          (optional) default true.
#   PLAY_LOG_FILE                      (optional) append a full transcript here
#                                      (used by CI to keep a debuggable log).
#   PLAY_API_BASE                      (optional) API base URL, default
#                                      https://androidpublisher.googleapis.com
#                                      (tests point this at a local mock).
#   GITHUB_OUTPUT                      (optional) when set and a tester audience
#                                      is required, appends
#                                      needs_tester_audience=true.
#
# Notes:
# - Only ONE edit is ever open at a time. Play's edits.insert silently deletes
#   the previously-open edit, so a "probe edit" flow fails the main edit's
#   bundle upload with 400 "This Edit has been deleted" (AUT-952). Track
#   existence is probed edit-free; the release goes onto the EXISTING closed
#   testing track (testing). If that probe comes back missing, the track is
#   created once as CLOSED_TESTING in its OWN committed edit before the main
#   edit opens (AUT-932), then the build is released onto it — a fresh Play
#   Console never blocks the first upload. The create edit is committed (closed)
#   before the main edit opens, so it never trips the AUT-952 failure.
# - Closed testing tracks have custom names. The default target is the
#   existing `alpha` track which already has a tester audience.
# - The `alpha` track is a rollout track. A bare "completed" (implicit 100%)
#   release is refused with 403 "You cannot rollout this release because it does
#   not allow any existing users to upgrade to the newly added APKs" unless the
#   staged rollout already covers every existing tester. Play accepts
#   status="inProgress" with userFraction=0.999 to serve the build to the full
#   tester list. Set PLAY_ROLLOUT_PERCENT=100 (default) to enable this fallback.
# - Committing the edit is what "submits for review" to Google Play.
# - Every HTTP failure prints its status code + response body to stderr and
#   fails with a ::error:: line so GitHub shows the cause directly.
# Never prints the service-account JSON or any secrets. Requires: bash, curl,
# jq, openssl (all present on ubuntu-latest GitHub runners).

set -euo pipefail

AAB="${1:?usage: play-upload-closed-testing.sh <app-release.aab> [track-id]}"
[[ -f "$AAB" ]] || { echo "::error::AAB not found: $AAB"; exit 1; }
TRACK="${2:-${PLAY_TRACK:-alpha}}"
PACKAGE="${PLAY_PACKAGE_NAME:-com.autobrainservice.app}"
NOTES="${PLAY_RELEASE_NOTES:-}"
STATUS="${PLAY_RELEASE_STATUS:-completed}"
# PLAY_ROLLOUT_PERCENT=100 (default) fallback. `alpha` is a rollout track, so a
# bare "completed" release is refused with 403 ("does not allow any existing users
# to upgrade") unless the rollout already covers every existing tester. Play accepts
# status="inProgress" with userFraction=0.999 to serve the build to the full tester
# list. Disabled only by explicitly setting PLAY_ROLLOUT_PERCENT=0.
ALLOW_FALLBACK="${PLAY_ALLOW_DRAFT_FALLBACK:-true}"
ROLLOUT_PERCENT="${PLAY_ROLLOUT_PERCENT:-100}"
[[ "$ROLLOUT_PERCENT" =~ ^[0-9]+$ && "$ROLLOUT_PERCENT" -ge 0 && "$ROLLOUT_PERCENT" -le 100 ]] || { echo "::error::PLAY_ROLLOUT_PERCENT must be 0-100"; exit 1; }
[[ "$STATUS" == "completed" || "$STATUS" == "draft" || "$STATUS" == "inProgress" ]] || { echo "::error::PLAY_RELEASE_STATUS must be completed, draft, or inProgress"; exit 1; }

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

API_BASE="${PLAY_API_BASE:-https://androidpublisher.googleapis.com}"
BASE="$API_BASE/androidpublisher/v3/applications/$PACKAGE"
UPLOAD_BASE="$API_BASE/upload/androidpublisher/v3/applications/$PACKAGE"
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

# 2. Ensure the closed testing track exists — edit-free probe (200 = exists).
#    A missing track is created once as CLOSED_TESTING in its OWN committed edit
#    (committed/closed BEFORE the main edit opens), so Play keeps a single edit
#    open and we never hit the AUT-952 "This Edit has been deleted" failure.
track_probe="$(curl -sS --connect-timeout 30 -o /dev/null -w '%{http_code}' "$BASE/tracks/$TRACK/releases" "${AUTH[@]}")"
if [[ "$track_probe" != "200" ]]; then
  echo "track '$TRACK' not found (releases probe HTTP $track_probe) — creating closed testing track"
  req -m 60 -X POST "$BASE/edits" "${AUTH[@]}" -H "Content-Type: application/json" -d '{}'
  [[ "$HTTP_CODE" == "200" ]] || die_http "edits.insert (track-create)" 200
  create_edit="$(jq -r '.id' <<<"$HTTP_BODY")"
  [[ -n "$create_edit" && "$create_edit" != "null" ]] || { echo "::error::edits.insert (track-create) returned no id"; exit 1; }
  req -m 60 -X POST "$BASE/edits/$create_edit/tracks" "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    -d "{\"track\":\"$TRACK\",\"type\":\"CLOSED_TESTING\",\"formFactor\":\"DEFAULT\"}"
  [[ "$HTTP_CODE" == "200" ]] || die_http "tracks.create ($TRACK)" 200
  req -m 120 -X POST "$BASE/edits/$create_edit:commit" "${AUTH[@]}"
  [[ "$HTTP_CODE" == "200" ]] || die_http "track-create edit commit" 200
  echo "closed testing track '$TRACK' created"
fi

# 3. Open the main edit — the ONLY edit held open by this script (see step 2)
req -m 60 -X POST "$BASE/edits" "${AUTH[@]}" -H "Content-Type: application/json" -d '{}'
[[ "$HTTP_CODE" == "200" ]] || die_http "edits.insert (main)" 200
edit_id="$(jq -r '.id' <<<"$HTTP_BODY")"
[[ -n "$edit_id" && "$edit_id" != "null" ]] || { echo "::error::edits.insert returned no id"; exit 1; }
EDIT="$BASE/edits/$edit_id"

# 4. Upload the AAB (media upload goes to the /upload/ host)
req -m 600 -X POST "$UPLOAD_BASE/edits/$edit_id/bundles?uploadType=media" "${AUTH[@]}" \
  -H "Content-Type: application/octet-stream" --data-binary "@$AAB"
[[ "$HTTP_CODE" == "200" ]] || die_http "bundle upload" 200
version_code="$(jq -r '.versionCode' <<<"$HTTP_BODY")"
[[ -n "$version_code" && "$version_code" != "null" ]] || { echo "::error::bundle upload returned no versionCode"; exit 1; }
echo "uploaded $AAB -> versionCode $version_code"

# 5. Assign it to the closed testing track. $release is already the complete
#    Track body — Track.releases is a JSON array of TrackRelease, so do not
#    wrap it again ({releases:$release} would double-nest and Play 400s).
release="{\"releases\":[{\"name\":\"$TRACK-$version_code\",\"versionCodes\":[\"$version_code\"],\"status\":\"$STATUS\""
# userFraction only applies to a staged (inProgress) rollout; completed/draft have no fraction.
if [[ "$STATUS" == "inProgress" && "$ROLLOUT_PERCENT" -ge 1 ]]; then
  # Play rejects userFraction == 1.0, so cap at 0.999 to serve every tester.
  frac=$(awk -v p="$ROLLOUT_PERCENT" 'BEGIN { if (p >= 100) p=99.9; printf "%.3f", p/100 }')
  release="$release,\"userFraction\":$frac"
fi
if [[ -n "$NOTES" ]]; then
  notes_json="$(jq -n --arg t "$NOTES" '[{"language":"en-US","text":$t}]')"
  release="$release,\"releaseNotes\":$notes_json"
fi
release="$release}]}"
track_body="$release"
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
elif [[ "$commit_code" == "403" && "$STATUS" == "completed" && "$ROLLOUT_PERCENT" -ge 1 ]] \
  && grep -q "does not allow any existing users to upgrade" <<<"$commit_body"; then
  # `alpha` is a rollout track: Play refuses a bare "completed" (100%) release
  # unless the staged rollout already reaches every existing tester. Retry as a
  # staged rollout capped at 0.999, which serves the build to the full list.
  echo "::warning::Play refused 'completed' on rollout track '$TRACK' ('does not allow any existing users to upgrade'); retrying as status=inProgress userFraction=0.999."
  frac=$(awk -v p="$ROLLOUT_PERCENT" 'BEGIN { if (p >= 100) p=99.9; printf "%.3f", p/100 }')
  release="{\"releases\":[{\"name\":\"$TRACK-$version_code\",\"versionCodes\":[\"$version_code\"],\"status\":\"inProgress\",\"userFraction\":$frac"
  if [[ -n "$NOTES" ]]; then
    release="$release,\"releaseNotes\":$notes_json"
  fi
  release="$release}]}"
  req -m 60 -X PUT "$EDIT/tracks/$TRACK" "${AUTH[@]}" \
    -H "Content-Type: application/json" -d "$release"
  [[ "$HTTP_CODE" == "200" ]] || die_http "tracks.update ($TRACK) as inProgress" 200
  commit_out="$("${CURL_NF[@]}" -m 300 -w $'\n%{http_code}' -X POST "$EDIT:commit" "${AUTH[@]}")"
  commit_code="$(tail -1 <<<"$commit_out")"
  [[ "$commit_code" == "200" ]] || { echo "::error::edit commit (inProgress fallback) failed (HTTP $commit_code): $(head -c 500 <<<"$commit_out" | tr '\n' ' ')"; exit 1; }
  STATUS="inProgress"
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
  req -m 60 -X PUT "$EDIT/tracks/$TRACK" "${AUTH[@]}" \
    -H "Content-Type: application/json" -d "$release"
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
# Drop the read-only verify edit so no open edit is ever left behind.
"${CURL_NF[@]}" -m 60 -X DELETE "$BASE/edits/$verify_edit" "${AUTH[@]}" >/dev/null 2>&1 || true
echo "closed testing ($TRACK) release OK: versionCode $version_code — status $STATUS, committed for review"
