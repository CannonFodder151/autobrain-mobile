#!/usr/bin/env bash
# AUT-5149: runnable check for the "Install provisioning profile" step in
# release-ios.yml.
#
# The step used to validate the profile with `plutil -convert json`, which cannot
# represent a real CMS-signed .mobileprovision (<data> blobs, nested dicts, and
# <date> values JSON has no type for). It failed on every genuine profile:
#   <stdin>: Invalid object in plist for JSON format
#   json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)
# (run 36998058429 / job 110809215825)
#
# AUT-5113 replaced that with a `security cms -D -o` decode plus a plistlib parse
# that also rejects a profile for the wrong App ID and a development profile.
# This script extracts the step body from the workflow and *executes* it against
# a real-shaped fixture, so the check cannot pass vacuously.
#
# No framework: bash asserts only, matching scripts/macos/provision-runner.test.sh.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
WF="$ROOT/.github/workflows/release-ios.yml"
BUNDLE_ID="com.autobrain.autobrain"
fails=0
ok()   { echo "ok - $1"; }
fail() { echo "FAIL - $1" >&2; fails=$((fails+1)); }

[ -f "$WF" ] || { echo "FAIL - $WF not found" >&2; exit 1; }

# --- static: extract the step body from the workflow ------------------------
# Runs to the next step marker rather than the first unindented line, because
# the step body contains a python heredoc with blank lines.
step="$(awk '
  /^      - name: Install provisioning profile$/ { in_step = 1; next }
  in_step && /^      - / { exit }
  in_step && /^        run: \|/ { in_body = 1; next }
  in_body { sub(/^          /, ""); print }
' "$WF")"
if [ -z "$step" ]; then
  fail "could not extract the 'Install provisioning profile' step body from $WF"
  exit 1
fi

# --- static: no JSON round-trip survives (comment lines stripped, since the
#     step documents the removal of that call) -------------------------------
wf_code="$(sed 's/^[[:space:]]*#.*//' "$WF")"
if grep -q 'plutil -convert json' <<<"$wf_code"; then
  fail "release-ios.yml still validates a profile with 'plutil -convert json'"
else
  ok "release-ios.yml contains no 'plutil -convert json'"
fi

printf '%s\n' "$step" | grep -q 'security cms -D -i "\$PROFILE" -o' \
  && ok "decodes to a plist with 'security cms -D -o'" \
  || fail "step does not decode with 'security cms -D -o'"
printf '%s\n' "$step" | grep -q 'plistlib' \
  && ok "parses the decoded profile with plistlib (date-safe)" \
  || fail "step does not parse the profile with plistlib"

# --- fixtures + stub security ----------------------------------------------
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
stub="$tmp/bin"; mkdir -p "$stub" "$tmp/home"
printf 'bm90LWEtcmVhbC1jbXMtc2lnbmF0dXJl' > "$tmp/profile.b64"

cat > "$tmp/mkprofile.py" <<'PY'
import plistlib, sys, datetime
bundle, task_allow, devices, path = sys.argv[1], sys.argv[2] == "true", sys.argv[3] == "true", sys.argv[4]
# A real application-identifier entitlement is "<10-char team id>.<bundle id>".
app_id = "737ABCDEFG." + bundle
p = {
    "Name": "AutoBrain App Store",
    "TeamIdentifier": ["737ABCDEFG"],
    "AppIDName": "autobrain",
    "ExpirationDate": datetime.datetime(2027, 9, 11),
    "Entitlements": {
        "application-identifier": app_id,
        "get-task-allow": task_allow,
    },
}
if devices:
    p["ProvisionedDevices"] = ["00008030-000123456789ABCD"]
with open(path, "wb") as fh:
    plistlib.dump(p, fh)
PY

# Stub `security`: writes STUB_PROFILE to the path given after -o. STUB_FAIL=1
# simulates a payload that is not a CMS-signed profile.
cat > "$stub/security" <<'STUB'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [[ "$prev" == "-o" ]] && out="$a"; prev="$a"; done
[[ -n "$out" ]] || { echo "security: no -o output path" >&2; exit 1; }
if [[ "${STUB_FAIL:-0}" == 1 ]]; then
  echo "security: CMS decode failed" >&2
  exit 1
fi
cp "$STUB_PROFILE" "$out"
STUB
chmod +x "$stub/security"

mkfixture() { python3 "$tmp/mkprofile.py" "$1" "$2" "$3" "$tmp/profile.plist"; }

run_step() { # $1=fail? $2=task_allow $3=devices $4=b64 [$5=IOS_BUNDLE_ID to build]
  # The fixture always carries the correct App ID; only $5 overrides what the
  # run claims to build, so the mismatch case really is a mismatch.
  local fails_flag="$1" task="$2" devs="$3" b64="$4" bundle="${5:-$BUNDLE_ID}"
  mkfixture "$BUNDLE_ID" "$task" "$devs" || return 1
  env -i PATH="$stub:/usr/bin:/bin" HOME="$tmp/home" RUNNER_TEMP="$tmp" \
      STUB_PROFILE="$tmp/profile.plist" STUB_FAIL="$fails_flag" \
      PROVISIONING_PROFILE_B64="$b64" IOS_BUNDLE_ID="$bundle" \
      GITHUB_OUTPUT="$tmp/gh_output" \
      bash -euo pipefail -c "$step" 2>&1
}

# --- the fault from run 36998058429: a valid App Store profile --------------
out="$(run_step 0 false false "$(cat "$tmp/profile.b64")")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'Checks OK' <<<"$out" && grep -q "$BUNDLE_ID" <<<"$out"; then
  ok "valid App Store profile: step succeeds and prints decoded fields"
else
  fail "valid App Store profile: expected rc=0 with fields, got rc=$rc: $out"
fi
grep -q "^name=AutoBrain App Store$" "$tmp/gh_output" 2>/dev/null \
  && ok "verified profile name is handed to GITHUB_OUTPUT for the archive step" \
  || fail "step did not export the verified profile name to GITHUB_OUTPUT"

# --- empty secret keeps the AUT-4355 warn-and-defer path --------------------
out="$(run_step 0 false false "")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'is empty' <<<"$out"; then
  ok "empty secret: step warns and defers to -allowProvisioningUpdates (rc=0)"
else
  fail "empty secret: expected rc=0 with a warning, got rc=$rc: $out"
fi

# --- undecodable payload still fails closed ---------------------------------
out="$(run_step 1 false false "$(cat "$tmp/profile.b64")")"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'not a CMS-signed provisioning profile' <<<"$out"; then
  ok "undecodable profile: step fails closed (rc=$rc)"
else
  fail "undecodable profile: expected non-zero rc, got rc=$rc: $out"
fi

# --- a profile bound to another App ID is rejected up front -----------------
out="$(run_step 0 false false "$(cat "$tmp/profile.b64")" com.autobrainservice.autobrain)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'but this run builds' <<<"$out"; then
  ok "wrong App ID: step fails closed before xcodebuild (rc=$rc)"
else
  fail "wrong App ID: expected non-zero rc, got rc=$rc: $out"
fi

# --- a development profile is rejected (cannot be exported to the App Store) --
out="$(run_step 0 true false "$(cat "$tmp/profile.b64")")"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'get-task-allow' <<<"$out"; then
  ok "development profile (get-task-allow): step fails closed (rc=$rc)"
else
  fail "development profile: expected non-zero rc, got rc=$rc: $out"
fi

out="$(run_step 0 false true "$(cat "$tmp/profile.b64")")"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'ProvisionedDevices' <<<"$out"; then
  ok "ad-hoc profile (ProvisionedDevices): step fails closed (rc=$rc)"
else
  fail "ad-hoc profile: expected non-zero rc, got rc=$rc: $out"
fi

# --- runner isolation gates analyze.yml on every push -----------------------
if bash "$ROOT/scripts/check-workflow-runner-isolation.sh" >/dev/null 2>&1; then
  ok "check-workflow-runner-isolation.sh passes"
else
  fail "check-workflow-runner-isolation.sh failed"
fi

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed" >&2; exit 1; }
echo "all ios-provisioning-profile checks passed"