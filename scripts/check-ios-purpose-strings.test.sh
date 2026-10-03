#!/usr/bin/env bash
#
# Self-check for scripts/check-ios-purpose-strings.py, the Info.plist purpose-string
# guard that release-ios.yml now runs before the signed build (AUT-5322). The
# fault App Store Connect reports — 90683 — only appears at upload time, after
# the signed archive exists, and the regression that caused it (dropping
# NSLocationAlwaysAndWhenInUseUsageDescription) leaves every local build green,
# so nothing but this guard sees it.
#
# Each case copies the real Info.plist into a throwaway tree, mutates the copy
# into one of the shapes the guard exists to catch, and asserts the exit status
# plus the message that proves the guard saw the right fault:
#
#   pass  untouched copy of the repo Info.plist
#   pass  the repo checkout itself (AC: a clean main must exit 0)
#   fail  the always/when-in-use location key deleted   -> MISSING: NSLocation...
#   fail  the camera key deleted                        -> MISSING: NSCamera...
#   fail  a purpose string blanked to ""                -> EMPTY
#   fail  a purpose string blanked to whitespace         -> EMPTY
#   fail  a purpose string typed as a boolean           -> EMPTY
#
# Run: bash scripts/check-ios-purpose-strings.test.sh
# Requires: bash, python3.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"
CHECK="$DIR/check-ios-purpose-strings.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# usage: check <expect pass|fail> <label> <expected message substring|-> <mutation>
# The mutation is python run with the throwaway tree as cwd; empty means the
# Info.plist is left exactly as the repo has it.
check() {
  local expect="$1" label="$2" want="$3" mutation="${4:-}"
  local root="$TMP/$(echo "$label" | tr -c 'a-zA-Z0-9' '_')"
  mkdir -p "$root/ios/Runner"
  cp "$REPO/ios/Runner/Info.plist" "$root/ios/Runner/Info.plist"
  if [[ -n "$mutation" ]]; then
    (cd "$root" && python3 -c "$mutation") || {
      fail=$((fail + 1)); echo "FAIL [$label]: the mutation itself failed"; return; }
  fi
  local out got
  if out="$(cd "$root" && python3 "$CHECK" 2>&1)"; then got=pass; else got=fail; fi
  if [[ "$got" != "$expect" ]]; then
    fail=$((fail + 1)); echo "FAIL [$label]: expected $expect, got $got"; echo "$out" | sed 's/^/    /'
    return
  fi
  if [[ "$want" != "-" && "$out" != *"$want"* ]]; then
    fail=$((fail + 1)); echo "FAIL [$label]: exit status right, but the report never mentioned '$want'"; echo "$out" | sed 's/^/    /'
    return
  fi
  pass=$((pass + 1))
}

# Mutate the plist in place: $1 = key to change, $2 = python literal for the
# replacement value.
mutate() {
  cat <<PY
import plistlib
p = "ios/Runner/Info.plist"
d = plistlib.load(open(p, "rb"))
$3
plistlib.dump(d, open(p, "wb"))
PY
}

check pass "untouched copy of the repo Info.plist" -

check fail "always/when-in-use location key deleted" "MISSING: NSLocationAlwaysAndWhenInUseUsageDescription" \
  "$(mutate x x 'd.pop("NSLocationAlwaysAndWhenInUseUsageDescription", None)')"

check fail "camera key deleted" "MISSING: NSCameraUsageDescription" \
  "$(mutate x x 'd.pop("NSCameraUsageDescription", None)')"

check fail "purpose string blanked to empty" "EMPTY: NSLocationWhenInUseUsageDescription" \
  "$(mutate x x 'd["NSLocationWhenInUseUsageDescription"] = ""')"

check fail "purpose string blanked to whitespace" "EMPTY" \
  "$(mutate x x 'd["NSCameraUsageDescription"] = "   "')"

check fail "purpose string typed as a boolean" "EMPTY" \
  "$(mutate x x 'd["NSPhotoLibraryUsageDescription"] = True')"

# The repo checkout itself, not a copy of it: this is the "still exits 0 on a
# clean main" guarantee the CI step relies on.
if (cd "$REPO" && python3 scripts/check-ios-purpose-strings.py >/dev/null 2>&1); then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL [repo checkout]: the guard did not pass on the tree as checked out"
fi

echo "check-ios-purpose-strings: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
