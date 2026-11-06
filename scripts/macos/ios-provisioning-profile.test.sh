#!/usr/bin/env bash
# AUT-5149: runnable check for the "Install provisioning profile" step in
# release-ios.yml.
#
# That step used to validate the profile with `plutil -convert json`, which cannot
# represent a real CMS-signed .mobileprovision: the payload carries <data> blobs
# and nested dicts plutil will not flatten, and ExpirationDate is a <date> that
# JSON has no type for. So it failed on *every* genuine profile:
#   <stdin>: Invalid object in plist for JSON format
#   json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)
# (run 36998058429 / job 110809215825)
#
# PR #113 replaced that with a `security cms -D -o` decode asserted on exit
# status. Nothing in CI would catch a regression that puts the JSON round-trip
# back, so this script extracts the step body from the workflow and *executes*
# it, which also means the check cannot pass vacuously.
#
# No framework: bash asserts only, matching scripts/macos/provision-runner.test.sh.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
WF="$ROOT/.github/workflows/release-ios.yml"
fails=0
ok()   { echo "ok - $1"; }
fail() { echo "FAIL - $1" >&2; fails=$((fails+1)); }

[ -f "$WF" ] || { echo "FAIL - $WF not found" >&2; exit 1; }

# --- static: extract the step body from the workflow ------------------------
# Runs to the next step marker rather than stopping at the first unindented
# line, so a heredoc or blank line inside the body cannot truncate it.
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

# --- static: no JSON round-trip survives ------------------------------------
# Comment lines are stripped, since the step documents the removal of that call.
wf_code="$(sed 's/^[[:space:]]*#.*//' "$WF")"
if grep -q 'plutil -convert json' <<<"$wf_code"; then
  fail "release-ios.yml still validates a profile with 'plutil -convert json'"
else
  ok "release-ios.yml contains no 'plutil -convert json'"
fi

printf '%s\n' "$step" | grep -q 'security cms -D -i "\$PROFILE" -o' \
  && ok "decodes to a plist with 'security cms -D -o'" \
  || fail "step does not decode with 'security cms -D -o'"
printf '%s\n' "$step" | grep -q 'if ! security cms -D' \
  && ok "decode assertion is on 'security cms -D' exit status" \
  || fail "step does not assert on 'security cms -D' exit status"

# --- fixture + stub binaries ------------------------------------------------
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
stub="$tmp/bin"; mkdir -p "$stub" "$tmp/home"
printf 'bm90LWEtcmVhbC1jbXMtc2lnbmF0dXJl' > "$tmp/profile.b64"

# A real App Store profile: <data> blobs, a <date>, and an entitlements dict.
python3 - "$tmp/profile.plist" <<'PY'
import plistlib, sys, datetime
p = {
    "Name": "AutoBrain App Store",
    "TeamIdentifier": ["737ABCDEFG"],
    "AppIDName": "autobrain",
    "ExpirationDate": datetime.datetime(2027, 9, 11),
    "Entitlements": {"application-identifier": "737ABCDEFG.com.autobrain.autobrain"},
    "DER-Encoded-Profile": b"\x30\x82\x0a\xfb\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x07\x02",
}
with open(sys.argv[1], "wb") as fh:
    plistlib.dump(p, fh)
PY

# Stub `security`: copies the fixture to the path given after -o. STUB_FAIL=1
# simulates a payload that is not a CMS-signed profile.
cat > "$stub/security" <<'STUB'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [[ "$prev" == "-o" ]] && out="$a"; prev="$a"; done
[[ -n "$out" ]] || { echo "security: no -o output path" >&2; exit 1; }
[[ "${STUB_FAIL:-0}" == 1 ]] && { echo "security: CMS decode failed" >&2; exit 1; }
cp "$STUB_PROFILE" "$out"
STUB
chmod +x "$stub/security"

# Stub `plutil`: only the `-extract <path> raw -o -` form the step uses.
cat > "$stub/plutil" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "-extract" ]] || { echo "<plist/>"; exit 0; }
case "$2" in
  Name)             echo "AutoBrain App Store" ;;
  TeamIdentifier.0) echo "737ABCDEFG" ;;
  AppIDName)        echo "autobrain" ;;
  *)                echo "2027-09-11 00:00:00" ;;
esac
STUB
chmod +x "$stub/plutil"

run_step() { # $1=stub_fail? $2=profile_b64
  env -i PATH="$stub:/usr/bin:/bin" HOME="$tmp/home" RUNNER_TEMP="$tmp" \
      STUB_PROFILE="$tmp/profile.plist" STUB_FAIL="$1" \
      PROVISIONING_PROFILE_B64="$2" \
      bash -euo pipefail -c "$step" 2>&1
}

# --- the fault from run 36998058429: a valid profile must now pass ----------
out="$(run_step 0 "$(cat "$tmp/profile.b64")")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'AutoBrain App Store' <<<"$out" \
   && grep -q '737ABCDEFG' <<<"$out" && ! grep -q 'Invalid object in plist' <<<"$out"; then
  ok "valid profile: step succeeds and prints decoded fields (no JSON round-trip)"
else
  fail "valid profile: expected rc=0 with fields, got rc=$rc: $out"
fi

# --- empty secret keeps the AUT-4355 warn-and-defer path --------------------
out="$(run_step 0 "")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'is empty' <<<"$out"; then
  ok "empty secret: step warns and defers to -allowProvisioningUpdates (rc=0)"
else
  fail "empty secret: expected rc=0 with a warning, got rc=$rc: $out"
fi

# --- an undecodable payload is still a real signing fault and fails closed ---
out="$(run_step 1 "$(cat "$tmp/profile.b64")")"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'not a decodable CMS-signed' <<<"$out"; then
  ok "undecodable profile: step fails closed (rc=$rc)"
else
  fail "undecodable profile: expected non-zero rc, got rc=$rc: $out"
fi

# --- runner isolation gates analyze.yml on every push -----------------------
if bash "$ROOT/scripts/check-workflow-runner-isolation.sh" >/dev/null 2>&1; then
  ok "check-workflow-runner-isolation.sh passes"
else
  fail "check-workflow-runner-isolation.sh failed"
fi

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed" >&2; exit 1; }
echo "all ios-provisioning-profile checks passed"