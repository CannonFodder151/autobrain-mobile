#!/usr/bin/env bash
#
# Self-check for scripts/check-carto-key.sh (AUT-4823) against fixture
# artifacts, reproducing the cases that matter in a release:
#
#   1. key present in the AOT snapshot          -> pass
#   2. key absent from the AOT snapshot         -> FAIL (watermapped release)
#   3. CARTO_API_KEY unset/empty                -> FAIL, before any artifact read
#   4. container with no AOT member at all      -> FAIL (guard must not pass
#      vacuously — this is the "checked 0 members" case)
#   5. mixed good/bad artifacts                 -> overall FAIL
#   6. artifact missing / not a zip             -> FAIL
#
# Run: bash scripts/check-carto-key.test.sh
# Requires: bash, python3.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/check-carto-key.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# Build a zip fixture whose lib/arm64-v8a/libapp.so contains the given payload.
make_aab() {
  python3 - "$1" "$2" <<'PY'
import sys, zipfile
out, payload = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w") as zf:
    zf.writestr("BundleConfig.pb", "\x08\x01")
    zf.writestr("base/manifest/AndroidManifest.xml", "<manifest/>")
    zf.writestr("base/classes.dex", "dex\n035\0")
    zf.writestr("lib/arm64-v8a/libapp.so", payload)
    zf.writestr("lib/armeabi-v7a/libapp.so", payload)
PY
}

# A container that is a valid zip but carries no AOT snapshot at all.
make_no_aot() {
  python3 - "$1" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as zf:
    zf.writestr("BundleConfig.pb", "\x08\x01")
    zf.writestr("base/manifest/AndroidManifest.xml", "<manifest/>")
PY
}

ok_aab="$TMP/with-key.aab"
bad_aab="$TMP/without-key.aab"
no_aot_aab="$TMP/no-aot.aab"
not_zip="$TMP/not-a-zip.aab"
make_aab "$ok_aab" 'AAB-filler cb1_TESTKEY_abc123 tileTemplate ?key='
make_aab "$bad_aab" 'AAB-filler no key here tileTemplate'
make_no_aot "$no_aot_aab"
printf 'this is definitely not a zip archive' > "$not_zip"

check() {
  local label="$1" expected="$2"; shift 2
  local out rc
  out="$("$@" 2>&1)" && rc=0 || rc=$?
  if [[ "$rc" == "$expected" ]]; then
    echo "  ok: $label (rc=$rc)"
    pass=$((pass + 1))
  else
    echo "  FAIL: $label expected rc=$expected got rc=$rc"
    echo "$out" | sed 's/^/       /'
    fail=$((fail + 1))
  fi
}

echo "AUT-4823 check-carto-key.sh self-check"

# 1. key present -> pass
check "key present in AOT snapshot -> pass" 0 \
  env CARTO_API_KEY=cb1_TESTKEY_abc123 bash "$SCRIPT" "$ok_aab"

# 2. key absent from snapshot -> fail
check "key absent from AOT snapshot -> fail" 1 \
  env CARTO_API_KEY=cb1_TESTKEY_abc123 bash "$SCRIPT" "$bad_aab"

# 3. empty secret -> fail, and it must fail before complaining about artifacts
check "empty CARTO_API_KEY -> fail" 1 \
  env CARTO_API_KEY= bash "$SCRIPT" "$ok_aab"

# 4. no AOT member -> fail (must not pass vacuously)
check "no AOT member in container -> fail" 1 \
  env CARTO_API_KEY=cb1_TESTKEY_abc123 bash "$SCRIPT" "$no_aot_aab"

# 5. mixed set: one good, one bad -> overall fail, per-artifact reporting
check "one good + one bad artifact -> fail" 1 \
  env CARTO_API_KEY=cb1_TESTKEY_abc123 bash "$SCRIPT" "$ok_aab" "$bad_aab"

# 6. missing artifact -> fail
check "missing artifact file -> fail" 1 \
  env CARTO_API_KEY=cb1_TESTKEY_abc123 bash "$SCRIPT" "$TMP/does-not-exist.aab"

# 7. not a zip at all -> fail, not a crash or a vacuous pass
check "artifact that is not a zip -> fail" 1 \
  env CARTO_API_KEY=cb1_TESTKEY_abc123 bash "$SCRIPT" "$not_zip"

# 8. a key that is a substring of nothing else, to prove the match is on the
#    full literal value and not a prefix such as "cb1_"
check "near-miss key (prefix only) -> fail" 1 \
  env CARTO_API_KEY=cb1_TESTKEY_abc123_SUFFIX bash "$SCRIPT" "$ok_aab"

echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]