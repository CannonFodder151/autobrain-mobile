#!/usr/bin/env bash
# Self-check the CARTO_API_KEY plumbing in .github/workflows/release-ios.yml (AUT-5084).
#
# The bug this guards is invisible to a green build: `flutter build ios
# --dart-define=...` does not reach the shipped .ipa, because the
# `xcodebuild archive` step re-runs the Dart compile through the Xcode Flutter
# build phase, which reads the DART_DEFINES build setting instead. So the only
# thing that proves the fix is asserting on the step bodies themselves.
#
# Extracts each step out of the workflow yaml with `python3` + `yaml.safe_load`,
# executes it under bash `set -euo pipefail`, and stubs the macOS-only binaries
# (xcodebuild, unzip) so the archive and .ipa-verification steps run on Linux.
#
# Requires: bash, python3, pyyaml.
set -euo pipefail

python3 -c 'import yaml' 2>/dev/null \
  || { echo "FAIL: needs python3 with PyYAML (analyze.yml installs it with the toolchain)" >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"
WORKFLOW="$REPO/.github/workflows/release-ios.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

KEY="pk.eyJ1IjoiYXV0b2JyYWluLWNhcnRvLWRlbW8ifQ=="
GUARD="Require CARTO_API_KEY and encode DART_DEFINES (AUT-5084)"
ARCHIVE="Archive + export .ipa (Xcode, universal device+sim build)"
VERIFY="Verify .ipa produced"

pass=0
fail_count=0
ok()   { echo "ok: $*"; pass=$((pass + 1)); }
fail() { echo "FAIL: $*" >&2; fail_count=$((fail_count + 1)); }

# Pull one step's `run:` body out of the workflow. The `${{ secrets.X }}`
# expressions are only evaluated on a real runner; the harness supplies the
# values directly instead.
extract_step() { # extract_step <step-name> <out.sh>
  python3 - "$WORKFLOW" "$1" "$2" <<'PY'
import sys, yaml

workflow, name, out = sys.argv[1], sys.argv[2], sys.argv[3]
doc = yaml.safe_load(open(workflow))
for job in doc["jobs"].values():
    for step in job.get("steps", []):
        if step.get("name") == name:
            body = step["run"]
            body = body.replace("${{ secrets.CARTO_API_KEY }}", "")
            open(out, "w").write(body)
            sys.exit(0)
sys.exit(f"no step named {name!r} in {workflow}")
PY
  chmod +x "$2"
}

extract_step "$GUARD"   "$WORK/guard.sh"
extract_step "$ARCHIVE" "$WORK/archive.sh"
extract_step "$VERIFY"  "$WORK/verify.sh"

grep -q "CARTO_API_KEY" "$WORK/guard.sh" \
  || fail "extracted guard body does not read CARTO_API_KEY"

# ------------------------------------------------------------------- stubs ----
mkdir -p "$WORK/bin"
# xcodebuild records argv so the test can assert the DART_DEFINES build setting
# actually reaches the archive invocation.
cat > "$WORK/bin/xcodebuild" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$WORK/xcodebuild.argv"
exit 0
SHIM
chmod +x "$WORK/bin/xcodebuild"
# unzip -q -o IN -d OUT — the same extraction the runner performs, so
# `grep -r -a` walks a decompressed payload rather than a compressed one.
cat > "$WORK/bin/unzip" <<SHIM
#!/usr/bin/env bash
set -euo pipefail
dest="" src=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -d) dest="\$2"; shift 2 ;;
    -q|-o) shift ;;
    -*) shift ;;
    *) src="\$1"; shift ;;
  esac
done
python3 - "\$src" "\$dest" <<'PY'
import os, sys, zipfile

src, dest = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as z:
    for info in z.infolist():
        if info.is_dir():
            continue
        out = os.path.join(dest, info.filename)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with z.open(info) as fh, open(out, "wb") as ofh:
            ofh.write(fh.read())
PY
SHIM
chmod +x "$WORK/bin/unzip"
export PATH="$WORK/bin:$PATH"

run_guard() { # run_guard <key> <gha-env-file> -> echoes exit code, sets LAST_ENV
  set +e
  LAST_ENV="$WORK/gha.env"
  : > "$LAST_ENV"
  CARTO_API_KEY="$1" GITHUB_ENV="$LAST_ENV" bash "$WORK/guard.sh" \
    >"$WORK/guard.out" 2>"$WORK/guard.err"
  local rc=$?
  set -e
  return "$rc"
}

# ------------------------------------------------------------ 1. the guard ----
echo
echo "--- guard: fail closed on an unset secret ---"
if run_guard ""; then
  fail "empty CARTO_API_KEY was accepted; the release would ship a watermarked map"
else
  ok "empty CARTO_API_KEY exits non-zero (fail closed)"
fi

echo
echo "--- guard: encodes the full define set into DART_DEFINES ---"
if run_guard "$KEY"; then
  ok "CARTO_API_KEY present: guard exits 0"
else
  fail "guard rejected a valid CARTO_API_KEY:"; head -c 400 "$WORK/guard.err" >&2
fi

ENCODED="$(sed -n 's/^DART_DEFINES=//p' "$LAST_ENV" | head -1)"
[[ -n "$ENCODED" ]] || fail "guard wrote no DART_DEFINES to \$GITHUB_ENV"

DECODED="$(printf '%s' "$ENCODED" | python3 -c '
import base64, sys
for part in sys.stdin.read().strip().split(","):
    print(base64.b64decode(part).decode())
')"
for want in \
  "API_BASE_URL=https://hosted.autobrainservice.app/api/v1" \
  "WS_BASE_URL=wss://hosted.autobrainservice.app/ws" \
  "MOBILE_STORE_BUILD=true" \
  "CARTO_API_KEY=$KEY" ; do
  if grep -qxF "$want" <<<"$DECODED"; then
    ok "DART_DEFINES carries ${want%%=*}"
  else
    fail "DART_DEFINES is missing ${want%%=*}"
  fi
done

# --------------------------------------------- 2. the archive build setting ----
echo
echo "--- archive: DART_DEFINES reaches xcodebuild, not --dart-define ---"
: > "$WORK/xcodebuild.argv"
run_archive() { # run_archive <dart-defines> -> exit code
  local job
  job="$(mktemp -d)"
  mkdir -p "$job/ios"
  : > "$job/ios/ExportOptions.plist"
  printf 'version: 0.3.0+1\n' > "$job/pubspec.yaml"
  : > "$WORK/xcodebuild.argv"
  set +e
  ( cd "$job" && \
    KEY_ID=ABC123 ISSUER_ID=DEADBEEF AUTH_KEY_PATH=/dev/null \
    IOS_PROFILE_NAME="AutoBrain Distribution" DART_DEFINES="$1" \
    bash "$WORK/archive.sh" ) >"$WORK/archive.out" 2>"$WORK/archive.err"
  local rc=$?
  set -e
  rm -rf "$job"
  return "$rc"
}

if ! run_archive "$ENCODED"; then
  fail "archive step failed with a populated DART_DEFINES:"; head -c 600 "$WORK/archive.err" >&2
else
  ok "archive step exits 0"
fi

if grep -qxF "DART_DEFINES=$ENCODED" "$WORK/xcodebuild.argv"; then
  ok "xcodebuild archive invocation carries the DART_DEFINES build setting"
else
  fail "DART_DEFINES did not reach xcodebuild — the fix regressed to the silent no-op:" \
    head -c 600 "$WORK/xcodebuild.argv" >&2
fi
if grep -qxF archive "$WORK/xcodebuild.argv"; then
  ok "the archive action is still passed"
else
  fail "the archive action is missing from the xcodebuild invocation"
fi

echo
echo "--- archive: refuses to compile with an empty DART_DEFINES ---"
if run_archive ""; then
  fail "archive ran with DART_DEFINES unset; it would ship a key-less binary"
else
  ok "empty DART_DEFINES exits non-zero (fail closed)"
fi

# ------------------------------------------- 3. the exported .ipa payload ----
# Build a real zip laid out like an .ipa, so `unzip` and `grep -r -a` see the
# same thing the runner would. python3 zipfile rather than the zip(1) CLI: this
# test already needs python3 to read the workflow yaml, and `zip` is not
# installed everywhere this runs.
make_ipa() { # make_ipa <out.ipa> <with-key:true|false> <with-host:true|false>
  python3 - "$1" "$2" "$3" "$KEY" <<'PY'
import sys, zipfile

out, with_key, with_host, key = sys.argv[1:5]
payload = b"fake mach-o header\x00\x00"
if with_host == "true":
    payload += b"https://hosted.autobrainservice.app/api/v1"
if with_key == "true":
    payload += ("CARTO_API_KEY=" + key).encode()
payload += b"\x00trailing"
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("Payload/Runner.app/Frameworks/App.framework/App", payload)
PY
}

run_verify() { # run_verify <with-key> <with-host> [key] -> exit code
  local job key host rc
  # `${3-$KEY}` (no colon) so an explicitly empty third argument is
  # honoured — that case is what the vacuous-pass check below feeds.
  key="${3-$KEY}"
  job="$(mktemp -d)"
  mkdir -p "$job/build/ios/ipa" "$job/runner-temp"
  make_ipa "$job/build/ios/ipa/Runner.ipa" "$1" "$2"
  set +e
  ( cd "$job" && CARTO_API_KEY="$key" RUNNER_TEMP="$job/runner-temp" \
      bash "$WORK/verify.sh" ) >"$WORK/verify.out" 2>"$WORK/verify.err"
  rc=$?
  set -e
  rm -rf "$job"
  return "$rc"
}

echo
echo "--- .ipa verification: presence of the key is asserted ---"
if run_verify true true; then
  ok "a payload carrying CARTO_API_KEY passes"
else
  fail "verification rejected a payload that has the key:"; head -c 400 "$WORK/verify.err" >&2
fi

if run_verify false true; then
  fail "verification accepted a payload WITHOUT CARTO_API_KEY — the bug this issue fixes"
else
  ok "a payload missing CARTO_API_KEY exits non-zero"
fi

echo
echo "--- .ipa verification: guards the other defines too ---"
if run_verify true false; then
  fail "verification accepted a payload with no API_BASE_URL host — DART_DEFINES replaced the whole define set"
else
  ok "a payload missing the API/WS host exits non-zero"
fi

echo
echo "--- .ipa verification: an unset key cannot pass vacuously ---"
# `grep -F -q -- ""` matches every file, so a payload built without the key
# would sail through a missing guard. Assert the step refuses an empty needle.
if run_verify true true ""; then
  fail "verification passed with an empty CARTO_API_KEY — the key assertion is vacuous"
else
  ok "an empty CARTO_API_KEY exits non-zero"
fi

# The key is a secret-shaped value; a log line carrying it would put it in the
# job log. Assert the step never echoes it.
echo
echo "--- the key is never printed ---"
run_verify true true >/dev/null
if grep -qF "$KEY" "$WORK/verify.out" "$WORK/verify.err"; then
  fail "the verification step logged CARTO_API_KEY"
else
  ok "the verification step does not log CARTO_API_KEY"
fi
run_guard "$KEY" >/dev/null
if grep -qF "$KEY" "$WORK/guard.out" "$WORK/guard.err"; then
  fail "the guard step logged CARTO_API_KEY"
else
  ok "the guard step does not log CARTO_API_KEY"
fi

echo
echo "passed: $pass, failed: $fail_count"
[[ "$fail_count" == "0" ]] || exit 1
echo "ALL OK"