#!/usr/bin/env bash
# Self-check the CARTO_API_KEY plumbing in .github/workflows/release-mobile.yml (AUT-5556).
#
# The bug this guards is invisible to a green build: `flutter build appbundle
# --dart-define=CARTO_API_KEY=...` exits 0 whether or not the define reached
# the Dart compile. AUT-4691 added a fail-closed guard, but a non-empty secret
# only proves the secret exists — not that it is in the artifact. The Servo Spy
# map still falls back to a key-less (watermarked) CARTO tile.
#
# Android mirror of the .ipa check added in AUT-5084: extract the built
# artifact's payload and grep for the key itself. Extracts each step out of the
# workflow yaml with `python3` + `yaml.safe_load`, executes it under bash
# `set -euo pipefail`, and stubs `flutter` so the build steps run on Linux
# without a Flutter SDK.
#
# Requires: bash, python3, pyyaml.
set -euo pipefail

python3 -c 'import yaml' 2>/dev/null \
  || { echo "FAIL: needs python3 with PyYAML (analyze.yml installs it with the toolchain)" >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"
WORKFLOW="$REPO/.github/workflows/release-mobile.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

KEY="pk.eyJ1IjoiYXV0b2JyYWluLWNhcnRvLWRlbW8ifQ=="
HOST="hosted.autobrainservice.app"
GUARD="Verify CARTO_API_KEY secret is present (AUT-4691)"
BUILD_AAB="Build release appbundle"
BUILD_APK="Build release APK (same signingConfig, for apksigner scheme check)"
VERIFY_AAB="Verify CARTO_API_KEY is compiled into the .aab (AUT-5556)"
VERIFY_APK="Verify CARTO_API_KEY is compiled into the .apk (AUT-5556)"

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

extract_step "$GUARD"      "$WORK/guard.sh"
extract_step "$BUILD_AAB"  "$WORK/build-aab.sh"
extract_step "$BUILD_APK"  "$WORK/build-apk.sh"
extract_step "$VERIFY_AAB" "$WORK/verify-aab.sh"
extract_step "$VERIFY_APK" "$WORK/verify-apk.sh"

grep -q "CARTO_API_KEY" "$WORK/guard.sh" \
  || fail "extracted guard body does not read CARTO_API_KEY"

# ------------------------------------------------------------------- stubs ----
mkdir -p "$WORK/bin"
# flutter records argv so the test can assert the --dart-define carrying the
# key actually reaches the build invocation.
cat > "$WORK/bin/flutter" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$WORK/flutter.argv"
exit 0
SHIM
chmod +x "$WORK/bin/flutter"
export PATH="$WORK/bin:$PATH"

run_guard() { # run_guard <key> -> exit code
  set +e
  CARTO_API_KEY="$1" bash "$WORK/guard.sh" \
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
echo "--- guard: accepts a populated secret ---"
if run_guard "$KEY"; then
  ok "CARTO_API_KEY present: guard exits 0"
else
  fail "guard rejected a valid CARTO_API_KEY:"; head -c 400 "$WORK/guard.err" >&2
fi

# -------------------------------------------- 2. the build invocation ----
# AUT-4691's guard proves the secret exists. These assertions prove it is
# handed to the Dart compile; the verify steps below prove it landed.
echo
echo "--- build: the dart-define reaches the appbundle invocation ---"
run_build() { # run_build <step.sh> -> exit code
  : > "$WORK/flutter.argv"
  set +e
  ( cd "$WORK" && CARTO_API_KEY="$KEY" bash "$1" ) \
    >"$WORK/build.out" 2>"$WORK/build.err"
  local rc=$?
  set -e
  return "$rc"
}

if ! run_build "$WORK/build-aab.sh"; then
  fail "appbundle build step failed:"; head -c 600 "$WORK/build.err" >&2
else
  ok "appbundle build step exits 0"
fi
if grep -qxF -- "--dart-define=CARTO_API_KEY=$KEY" "$WORK/flutter.argv"; then
  ok "flutter build appbundle carries --dart-define=CARTO_API_KEY"
else
  head -c 600 "$WORK/flutter.argv" >&2
  fail "--dart-define=CARTO_API_KEY did not reach the appbundle build invocation"
fi
if grep -qxF appbundle "$WORK/flutter.argv"; then
  ok "the appbundle action is still passed"
else
  fail "the appbundle action is missing from the build invocation"
fi

echo
echo "--- build: the dart-define reaches the APK invocation ---"
if ! run_build "$WORK/build-apk.sh"; then
  fail "APK build step failed:"; head -c 600 "$WORK/build.err" >&2
else
  ok "APK build step exits 0"
fi
if grep -qxF -- "--dart-define=CARTO_API_KEY=$KEY" "$WORK/flutter.argv"; then
  ok "flutter build apk carries --dart-define=CARTO_API_KEY"
else
  head -c 600 "$WORK/flutter.argv" >&2
  fail "--dart-define=CARTO_API_KEY did not reach the APK build invocation"
fi
if grep -qxF apk "$WORK/flutter.argv"; then
  ok "the apk action is still passed"
else
  fail "the apk action is missing from the build invocation"
fi

# ------------------------------------------------- 3. the built artifacts ----
# Build real zips laid out like a Flutter release .aab / .apk, so
# `grep -r -a` walks an extracted payload rather than a compressed one. The key
# value is written ONLY into the AOT snapshot (base/lib/<abi>/libapp.so), which
# is where Dart puts a --dart-define — so a pass also proves the check reaches
# the snapshot rather than some other entry.
#
# The literal string "CARTO_API_KEY=" is always present, because Dart embeds
# the argument name of String.fromEnvironment regardless of whether the define
# was supplied. That is what makes the negative cases meaningful: a check that
# grepped the *name* instead of the *value* would pass vacuously.
#
# python3 zipfile rather than the zip(1) CLI: this test already needs python3 to
# read the workflow yaml, and `zip` is not installed everywhere this runs.
make_aab() { # make_aab <out.aab> <with-key:true|false> <with-host:true|false>
  python3 - "$1" "$2" "$3" "$KEY" <<'PY'
import sys, zipfile

out, with_key, with_host, key = sys.argv[1:5]
payload = b"\x7fELF\x02\x01\x01 fake arm64 libapp.so\x00\x00"
payload += b"String.fromEnvironment: CARTO_API_KEY="
if with_host == "true":
    payload += b"https://hosted.autobrainservice.app/api/v1"
if with_key == "true":
    payload += key.encode()
payload += b"\x00trailing"
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("BundleConfig.pb", b"\x0a\x05com.autobrainservice.app")
    z.writestr("base/manifest/AndroidManifest.xml", b"<manifest package='com.autobrainservice.app'/>")
    z.writestr("base/dex/classes.dex", b"dex\n035\x00fake dex without any defines")
    z.writestr("base/lib/arm64-v8a/libapp.so", payload)
    z.writestr("base/assets/flutter_assets/AssetManifest.json", b"[]")
PY
}

make_apk() { # make_apk <out.apk> <with-key:true|false>
  python3 - "$1" "$2" "$KEY" <<'PY'
import sys, zipfile

out, with_key, key = sys.argv[1:4]
payload = b"\x7fELF\x02\x01\x01 fake arm64 libapp.so\x00\x00"
payload += b"String.fromEnvironment: CARTO_API_KEY="
if with_key == "true":
    payload += key.encode()
payload += b"\x00trailing"
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("AndroidManifest.xml", b"<manifest package='com.autobrainservice.app'/>")
    z.writestr("classes.dex", b"dex\n035\x00fake dex without any defines")
    z.writestr("lib/arm64-v8a/libapp.so", payload)
    z.writestr("assets/flutter_assets/AssetManifest.json", b"[]")
PY
}

run_verify() { # run_verify <aab|apk> <with-key> <with-host> [key] -> exit code
  local kind="$1" key job rc
  # `${4-$KEY}` (no colon) so an explicitly empty fourth argument is
  # honoured — that case is what the vacuous-pass check below feeds.
  key="${4-$KEY}"
  job="$(mktemp -d)"
  mkdir -p "$job/runner-temp"
  if [[ "$kind" == aab ]]; then
    mkdir -p "$job/build/app/outputs/bundle/release"
    make_aab "$job/build/app/outputs/bundle/release/app-release.aab" "$2" "$3"
  else
    mkdir -p "$job/build/app/outputs/flutter-apk"
    make_apk "$job/build/app/outputs/flutter-apk/app-release.apk" "$2"
  fi
  set +e
  ( cd "$job" && CARTO_API_KEY="$key" RUNNER_TEMP="$job/runner-temp" \
      bash "$WORK/verify-$kind.sh" ) \
    >"$WORK/verify-$kind.out" 2>"$WORK/verify-$kind.err"
  rc=$?
  set -e
  rm -rf "$job"
  return "$rc"
}

echo
echo "--- .aab verification: presence of the key is asserted ---"
if run_verify aab true true; then
  ok "a payload carrying CARTO_API_KEY passes"
else
  fail "verification rejected a payload that has the key:"; head -c 400 "$WORK/verify-aab.err" >&2
fi

if run_verify aab false true; then
  fail "verification accepted a payload WITHOUT CARTO_API_KEY — the bug this issue fixes"
else
  ok "a payload missing CARTO_API_KEY exits non-zero"
fi

echo
echo "--- .aab verification: guards the other defines too ---"
if run_verify aab true false; then
  fail "verification accepted a payload with no API_BASE_URL host — the dart-define set lost its endpoints"
else
  ok "a payload missing the API/WS host exits non-zero"
fi

echo
echo "--- .aab verification: an unset key cannot pass vacuously ---"
# `grep -F -q -- ""` matches every file, so a payload built without the key
# would sail through a missing guard. Assert the step refuses an empty needle.
if run_verify aab true true ""; then
  fail "verification passed with an empty CARTO_API_KEY — the key assertion is vacuous"
else
  ok "an empty CARTO_API_KEY exits non-zero"
fi

echo
echo "--- .apk verification: presence of the key is asserted ---"
if run_verify apk true; then
  ok "an APK payload carrying CARTO_API_KEY passes"
else
  fail "APK verification rejected a payload that has the key:"; head -c 400 "$WORK/verify-apk.err" >&2
fi

if run_verify apk false; then
  fail "APK verification accepted a payload WITHOUT CARTO_API_KEY — the bug this issue fixes"
else
  ok "an APK payload missing CARTO_API_KEY exits non-zero"
fi

echo
echo "--- .apk verification: an unset key cannot pass vacuously ---"
if run_verify apk true true ""; then
  fail "APK verification passed with an empty CARTO_API_KEY — the key assertion is vacuous"
else
  ok "an empty CARTO_API_KEY exits non-zero on the APK check"
fi

# A missing artifact must fail closed too, not skip: `[[ -f ]]` guards the
# release against a silently unbuilt bundle.
echo
echo "--- verification: a missing artifact fails closed ---"
for kind in aab apk; do
  job="$(mktemp -d)"
  mkdir -p "$job/runner-temp"
  set +e
  ( cd "$job" && CARTO_API_KEY="$KEY" RUNNER_TEMP="$job/runner-temp" \
      bash "$WORK/verify-$kind.sh" ) >"$WORK/missing-$kind.out" 2>&1
  rc=$?
  set -e
  rm -rf "$job"
  if [[ "$rc" == 0 ]]; then
    fail "$kind verification passed with no artifact built"
  else
    ok "$kind verification exits non-zero when the artifact is missing"
  fi
done

# The key is a secret-shaped value; a log line carrying it would put it in the
# job log. Assert the steps never echo it.
echo
echo "--- the key is never printed ---"
for probe in "guard:$WORK/guard.sh" "aab:$WORK/verify-aab.sh" "apk:$WORK/verify-apk.sh"; do
  label="${probe%%:*}"; script="${probe#*:}"
  set +e
  CARTO_API_KEY="$KEY" bash "$script" >"$WORK/leak.out" 2>"$WORK/leak.err"
  set -e
  if grep -qF "$KEY" "$WORK/leak.out" "$WORK/leak.err"; then
    fail "the $label step logged CARTO_API_KEY"
  else
    ok "the $label step does not log CARTO_API_KEY"
  fi
done

echo
echo "passed: $pass, failed: $fail_count"
[[ "$fail_count" == "0" ]] || exit 1
echo "ALL OK"