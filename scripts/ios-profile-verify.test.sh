#!/usr/bin/env bash
#
# Self-check for the "Install provisioning profile" step in
# .github/workflows/release-ios.yml (AUT-5164).
#
# The step body is extracted straight out of the workflow with yaml.safe_load
# and run under `bash` with `set -euo pipefail`, so the assertions cover the
# shell and the embedded python heredoc as they actually execute on the runner
# rather than a copy that can drift. `security cms -D` — the one macOS-only
# command — is shimmed with `openssl cms`, which reads the same CMS SignedData.
#
# Fixtures are real CMS-signed .mobileprovision payloads, so the shim is fed the
# same bytes Apple's own tooling produces.
#
# Run: bash scripts/ios-profile-verify.test.sh
# Requires: bash, python3, pyyaml, openssl.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"
WORKFLOW="$REPO/.github/workflows/release-ios.yml"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BUNDLE="com.autobrain.autobrain"
TEAM="ABCDE12345"

fail() { echo "FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------- step body --
# Extract the step's `run:` block verbatim and hand it to a file we can exec.
python3 - "$WORKFLOW" "$WORK/step.sh" <<'PY'
import sys, yaml

workflow, out = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(workflow))
for job in doc["jobs"].values():
    for step in job.get("steps", []):
        if step.get("name") == "Install provisioning profile":
            body = step["run"]
            # The Actions expression is only evaluated on a real runner; the
            # secret it reads is what the harness supplies directly.
            body = body.replace("${{ secrets.IOS_PROVISIONING_PROFILE_BASE64 }}", "")
            body = body.replace("${{ secrets.IOS_TEAM_ID }}", "")
            open(out, "w").write(body)
            break
    else:
        continue
    break
else:
    sys.exit(f"no 'Install provisioning profile' step in {workflow}")
PY
grep -q "PROVISIONING_PROFILE_B64" "$WORK/step.sh" || fail "extracted step body is not the profile installer"
chmod +x "$WORK/step.sh"

# ----------------------------------------------------------------- the shim --
# `security cms -D -i IN -o OUT` -> openssl, DER in and out.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/security" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "cms" ]] || { echo "unsupported security subcommand" >&2; exit 64; }
shift
in="" out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -D) shift ;;
    -i) in="$2"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
exec openssl cms -verify -purpose any -noverify -inform DER -in "$in" -out "$out"
SHIM
chmod +x "$WORK/bin/security"
export PATH="$WORK/bin:$PATH"

# --------------------------------------------------------------- fixtures ----
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 3650 -nodes -subj "/CN=autobrain-profile-test" >/dev/null 2>&1 \
  || fail "could not generate a throwaway signing cert"

# Wrap each payload in a real CMS SignedData, DER encoded like Apple's.
sign() { # sign <plist-source> <out.mobileprovision>
  openssl cms -sign -signer "$WORK/cert.pem" -inkey "$WORK/key.pem" \
    -in "$1" -outform DER -nodetach -out "$2" >/dev/null 2>&1
}

FUTURE="2030-01-01 00:00:00"
PAST="2025-01-01 00:00:00"
base_profile() { # base_profile <out.plist> [get-task-allow] [expiry-override]
  python3 - "$1" "${2-}" "${3-}" <<'PY'
import datetime, plistlib, sys
out, gta, expiry = sys.argv[1], sys.argv[2], sys.argv[3]
p = {
    "Name": "AutoBrain Distribution",
    "AppIDName": "AutoBrain",
    "TeamIdentifier": ["ABCDE12345"],
    "ExpirationDate": datetime.datetime(2030, 1, 1),
    "Entitlements": {
        "application-identifier": "ABCDE12345.com.autobrain.autobrain",
        "get-task-allow": False,
    },
    "ProvisionsAllDevices": False,
}
if gta == "true":
    p["Entitlements"]["get-task-allow"] = True
elif gta == "absent":
    del p["Entitlements"]["get-task-allow"]
if expiry:
    date_part = expiry.split()[0]
    y, m, d = (int(x) for x in date_part.split("-"))
    p["ExpirationDate"] = datetime.datetime(y, m, d)
open(out, "wb").write(plistlib.dumps(p))
PY
}

pass=0 fail_count=0
# run_case <name> <expected-exit> <profile-base64|@empty|@malformed|@noncms|@nonplist>
run_case() {
  local name="$1" want="$2" b64="$3"
  local home gha runner out_file rc
  home="$(mktemp -d "$WORK/home.XXXXXX")"
  runner="$(mktemp -d "$WORK/runner.XXXXXX")"
  gha="$(mktemp -d "$WORK/gha.XXXXXX")"
  out_file="$gha/env"

  local body
  if [[ "$b64" == "@empty" ]]; then
    body=""
  elif [[ "$b64" == "@malformed" ]]; then
    body="bm90LWEtcHJvZmlsZQ=="   # "not-a-profile", not base64 of a CMS blob
  elif [[ "$b64" == "@noncms" ]]; then
    body="$(printf 'this is not a CMS blob at all\n' | base64 -w0)"
  elif [[ "$b64" == "@nonplist" ]]; then
    body="$(base64 -w0 < "$WORK/nonplist.mobileprovision")"
  else
    body="$b64"
  fi

  set +e
  HOME="$home" RUNNER_TEMP="$runner" GITHUB_ENV="$out_file" GITHUB_OUTPUT="$gha/out" \
    GITHUB_PATH="$gha/path" IOS_BUNDLE_ID="$BUNDLE" TEAM_ID="${TEST_TEAM_ID-$TEAM}" \
    PROVISIONING_PROFILE_B64="$body" \
    bash "$WORK/step.sh" >"$WORK/stdout" 2>"$WORK/stderr"
  rc=$?
  set -e

  LAST_STDOUT="$(cat "$WORK/stdout")"
  LAST_STDERR="$(cat "$WORK/stderr")"
  LAST_GITHUB_ENV="$(cat "$out_file" 2>/dev/null || true)"

  if [[ "$rc" != "$want" ]]; then
    echo "FAIL: $name — expected exit $want, got $rc" >&2
    echo "  stdout: $(head -c 400 "$WORK/stdout")" >&2
    echo "  stderr: $(head -c 400 "$WORK/stderr")" >&2
    fail_count=$((fail_count + 1))
  else
    echo "ok: $name (exit $rc)"
    pass=$((pass + 1))
  fi

  # F6: the expanded plist must not survive the step, but the installed
  # .mobileprovision must (codesign resolves the pinned specifier against it).
  local decoded="$runner/autobrain_distribution.plist"
  if [[ -e "$decoded" ]]; then
    echo "FAIL: $name — the expanded profile plist was left behind at $decoded" >&2
    fail_count=$((fail_count + 1))
  else
    echo "ok: $name — expanded plist removed (F6)"
    pass=$((pass + 1))
  fi
  [[ -n "$want" && "$want" != "0" ]] && rm -rf "$home" "$runner" "$gha"
  LAST_HOME="$home"
}

# Build every fixture up front so a bad one fails loudly, not as a false pass.
base_profile "$WORK/valid.plist"
sign "$WORK/valid.plist" "$WORK/valid.mobileprovision"

base_profile "$WORK/expired.plist" "" "$PAST"
sign "$WORK/expired.plist" "$WORK/expired.mobileprovision"

base_profile "$WORK/enterprise.plist"
python3 - "$WORK/enterprise.plist" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
p["ProvisionsAllDevices"] = True
open(sys.argv[1], "wb").write(plistlib.dumps(p))
PY
sign "$WORK/enterprise.plist" "$WORK/enterprise.mobileprovision"

base_profile "$WORK/wrongappid.plist"
python3 - "$WORK/wrongappid.plist" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
p["Entitlements"]["application-identifier"] = "ABCDE12345.com.example.other"
open(sys.argv[1], "wb").write(plistlib.dumps(p))
PY
sign "$WORK/wrongappid.plist" "$WORK/wrongappid.mobileprovision"

base_profile "$WORK/development.plist" true
python3 - "$WORK/development.plist" <<'PY'
import datetime, plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
p["ProvisionedDevices"] = ["00008030-000000000000001E"]
open(sys.argv[1], "wb").write(plistlib.dumps(p))
PY
sign "$WORK/development.plist" "$WORK/development.mobileprovision"

# get-task-allow absent: an absent key defaults to True, so it must be fatal.
base_profile "$WORK/gta_absent.plist" absent
sign "$WORK/gta_absent.plist" "$WORK/gta_absent.mobileprovision"

printf 'not a property list\n' > "$WORK/nonplist.bin"
sign "$WORK/nonplist.bin" "$WORK/nonplist.mobileprovision"

VALID_B64="$(base64 -w0 < "$WORK/valid.mobileprovision")"
EXPIRED_B64="$(base64 -w0 < "$WORK/expired.mobileprovision")"
ENTERPRISE_B64="$(base64 -w0 < "$WORK/enterprise.mobileprovision")"
WRONGAPPID_B64="$(base64 -w0 < "$WORK/wrongappid.mobileprovision")"
DEVELOPMENT_B64="$(base64 -w0 < "$WORK/development.mobileprovision")"
GTA_ABSENT_B64="$(base64 -w0 < "$WORK/gta_absent.mobileprovision")"

echo
echo "--- exit codes ---"
run_case "valid App Store profile"        0 "$VALID_B64"
# F3 sanity: plistlib hands back a *naive* datetime for <date>. If the verifier
# compared it to an aware now() without normalising, every genuine profile would
# die on TypeError — so an unexpired one must parse and print cleanly.
if grep -q 'Expires: 2030-01-01' "$WORK/stdout"; then
  echo "ok: F3 — an unexpired <date> is compared without TypeError"
  pass=$((pass + 1))
else
  echo "FAIL: F3 — valid profile did not report its expiry:" >&2
  head -c 400 "$WORK/stdout" >&2
  fail_count=$((fail_count + 1))
fi
run_case "expired profile"                1 "$EXPIRED_B64"
run_case "ProvisionsAllDevices (enterprise)" 1 "$ENTERPRISE_B64"
run_case "wrong App ID"                   1 "$WRONGAPPID_B64"
run_case "development profile"            1 "$DEVELOPMENT_B64"
run_case "get-task-allow absent"          1 "$GTA_ABSENT_B64"
run_case "malformed base64"               1 "@malformed"
run_case "non-CMS payload"                1 "@noncms"
run_case "CMS-wrapped non-plist"          1 "@nonplist"

echo
echo "--- F2: CWE-93 log/annotation/GITHUB_ENV injection ---"
# A profile Name carrying a newline must not emit a standalone `::` line, and
# must not inject a second GITHUB_ENV variable.
python3 - "$WORK/valid.plist" "$WORK/inject.plist" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
p["Name"] = "Injected\n::set-output name=pwn::1\nsecond"
open(sys.argv[2], "wb").write(plistlib.dumps(p))
PY
sign "$WORK/inject.plist" "$WORK/inject.mobileprovision"
run_case "Name injects a workflow command" 0 "$(base64 -w0 < "$WORK/inject.mobileprovision")"

if grep -qE '^::' "$WORK/stdout"; then
  echo "FAIL: F2 — a raw '::' command line reached the step output:" >&2
  grep -nE '^::' "$WORK/stdout" >&2
  fail_count=$((fail_count + 1))
else
  echo "ok: F2 — no standalone '::' line in step output"
  pass=$((pass + 1))
fi

env_lines="$(printf '%s\n' "$LAST_GITHUB_ENV" | grep -c . || true)"
if [[ "$env_lines" == "2" ]] \
  && printf '%s\n' "$LAST_GITHUB_ENV" | grep -qx 'IOS_PROFILE_NAME=Injected ::set-output name=pwn::1 second' \
  && printf '%s\n' "$LAST_GITHUB_ENV" | grep -qx 'IOS_PROFILE_BUNDLE_ID=com.autobrain.autobrain'; then
  echo "ok: F2 — GITHUB_ENV holds exactly the two expected vars, sanitised"
  pass=$((pass + 1))
else
  echo "FAIL: F2 — GITHUB_ENV was not sanitised as expected:" >&2
  printf '%s\n' "$LAST_GITHUB_ENV" | cat -A >&2
  fail_count=$((fail_count + 1))
fi

echo
echo "--- F5: team pin ---"
# A profile whose application-identifier belongs to another team must be
# rejected when TEAM_ID is set, and must still pass when it is not.
python3 - "$WORK/valid.plist" "$WORK/otherteam.plist" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
p["Entitlements"]["application-identifier"] = "ZZZZZ99999.com.autobrain.autobrain"
open(sys.argv[2], "wb").write(plistlib.dumps(p))
PY
sign "$WORK/otherteam.plist" "$WORK/otherteam.mobileprovision"
run_case "other team's profile, TEAM_ID set" 1 "$(base64 -w0 < "$WORK/otherteam.mobileprovision")"

TEST_TEAM_ID="" run_case "other team's profile, TEAM_ID unset" 0 "$(base64 -w0 < "$WORK/otherteam.mobileprovision")"
unset TEST_TEAM_ID

echo
echo "--- empty secret stays non-fatal (AUT-4355) ---"
run_case "empty profile secret" 0 "@empty"

echo
echo "passed: $pass, failed: $fail_count"
[[ "$fail_count" == "0" ]] || exit 1
echo "ALL OK"