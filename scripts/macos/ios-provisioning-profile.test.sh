#!/usr/bin/env bash
# AUT-5149: the "Install provisioning profile" step in release-ios.yml used to
# validate the profile with `plutil -convert json`, which cannot represent a real
# CMS-signed .mobileprovision (<data> blobs + nested dicts). It failed on every
# genuine profile, so the step had to become a `security cms -D` exit-status
# assertion. Static assertions plus an execution of the real step body against
# stub `security`/`plutil` binaries.
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

# --- static: extract the step body ------------------------------------------
step="$(awk '
  /^      - name: Install provisioning profile$/ { in_step = 1; next }
  in_step && /^      - / { exit }
  in_step && /^        run: \|/ { in_body = 1; next }
  in_body && /^          / { sub(/^          /, ""); print; next }
  in_body && !/^          / { exit }
' "$WF")"
[ -n "$step" ] || { fail "could not extract 'Install provisioning profile' step body"; exit 1; }

# --- static: no JSON conversion anywhere in the workflow --------------------
# (comment lines are stripped: the step documents the removal of that call)
wf_code="$(sed 's/^[[:space:]]*#.*//' "$WF")"
if grep -q 'plutil -convert json' <<<"$wf_code"; then
  fail "release-ios.yml still validates a profile with 'plutil -convert json'"
else
  ok "release-ios.yml contains no 'plutil -convert json'"
fi

# --- static: decode assertion is on security cms exit status ---------------
printf '%s\n' "$step" | grep -q 'security cms -D -i "\$PROFILE" -o "\$DECODED"' \
  && ok "decodes with 'security cms -D -o' to a plist" \
  || fail "step does not decode with 'security cms -D -o'"
printf '%s\n' "$step" | grep -q 'if ! security cms -D' \
  && ok "decode assertion is on 'security cms -D' exit status" \
  || fail "step does not assert on 'security cms -D' exit status"

# --- functional: run the extracted body against stub security/plutil -------
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
stub="$tmp/bin"; mkdir -p "$stub" "$tmp/home"
cat > "$stub/security" <<'STUB'
#!/usr/bin/env bash
# Stub: decodes to the path given after -o, succeeds only when STUB_PROFILE_DECODES=1.
out=""; prev=""
for a in "$@"; do [[ "$prev" == "-o" ]] && out="$a"; prev="$a"; done
if [[ "${STUB_PROFILE_DECODES:-0}" != 1 ]]; then
  echo "security: CMS decode failed" >&2
  exit 1
fi
[[ -n "$out" ]] || { echo "security: no -o output path" >&2; exit 1; }
echo "<plist/>" > "$out"
STUB
cat > "$stub/plutil" <<'STUB'
#!/usr/bin/env bash
# Stub plutil -extract <path> raw -o - <plist>
[[ "$1" == "-extract" ]] || { echo "<plist/>"; exit 0; }
case "$2" in
  Name)          echo "autobrain distribution" ;;
  TeamIdentifier.0) echo "737ABCDEFG" ;;
  AppIDName)     echo "autobrain" ;;
  *)             echo "2030-01-01" ;;
esac
STUB
chmod +x "$stub/security" "$stub/plutil"
printf 'not-a-real-cms-blob' | base64 --decode > "$tmp/profile.b64" 2>/dev/null
# base64 of a decodable-but-fake payload; the stub decides validity
printf 'ZmFrZS1wcm92aXNpb25pbmctcGF5bG9hZA==' > "$tmp/profile.b64"

run_step() {
  env -i PATH="$stub:/usr/bin:/bin" HOME="$tmp/home" \
      RUNNER_TEMP="$tmp" \
      STUB_PROFILE_DECODES="$1" STUB_OUT="$tmp/decoded.plist" \
      PROVISIONING_PROFILE_B64="$(cat "$tmp/profile.b64")" \
      bash -euo pipefail -c "$step" 2>&1
}

out="$(run_step 1)"; rc=$?
if [[ $rc -eq 0 && "$out" == *"autobrain distribution"* && "$out" == *"737ABCDEFG"* ]]; then
  ok "valid profile: step succeeds and prints decoded fields"
else
  fail "valid profile: expected rc=0 with fields, got rc=$rc: $out"
fi

out="$(run_step 0)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"not a decodable CMS-signed"* ]]; then
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
