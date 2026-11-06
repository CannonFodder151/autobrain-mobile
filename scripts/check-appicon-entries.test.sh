#!/usr/bin/env bash
#
# Self-check for scripts/check-appicon-entries.py, the AppIcon manifest guard
# that release-ios.yml now runs before the signed build (AUT-5283). The guard
# only ever ran by hand, so nothing stopped the required-entry set from losing
# the 1024x1024 ios-marketing icon: deleting that entry *and* its PNG still
# exited 0, which is the 90023 class that cost AUT-2638 three upload attempts.
#
# Each case copies the real AppIcon.appiconset into a throwaway tree, mutates
# the copy into one of the shapes the guard exists to catch, and asserts the
# exit status plus the message that proves the guard saw the right fault:
#
#   pass  untouched copy of the repo iconset
#   pass  the repo checkout itself (AC: a clean main must exit 0)
#   fail  ios-marketing entry and its PNG deleted  -> 1024x1024
#   fail  iPad 167x167 entry and its PNG deleted   -> 167x167
#   fail  one entry's filename key dropped         -> NO FILENAME
#   fail  a stray PNG no entry names               -> UNASSIGNED
#   fail  filename names a file that is not there  -> MISSING FILE
#   fail  filename names a PNG of the wrong pixels -> SIZE MISMATCH
#
# Run: bash scripts/check-appicon-entries.test.sh
# Requires: bash, python3.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"
CHECK="$DIR/check-appicon-entries.py"
ICONSET="ios/Runner/Assets.xcassets/AppIcon.appiconset"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# usage: check <expect pass|fail> <label> <expected message substring|-> <mutation>
# The mutation is python run with the throwaway tree as cwd; empty means the
# iconset is left exactly as the repo has it.
check() {
  local expect="$1" label="$2" want="$3" mutation="${4:-}"
  local root="$TMP/$(echo "$label" | tr -c 'a-zA-Z0-9' '_')"
  mkdir -p "$root/ios/Runner/Assets.xcassets"
  cp -r "$REPO/$ICONSET" "$root/$ICONSET"
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

check pass "untouched copy of the repo iconset" -

check fail "ios-marketing entry and PNG deleted" "1024x1024" '
import json, os
p = "ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json"
d = json.load(open(p))
d["images"] = [e for e in d["images"] if e["idiom"] != "ios-marketing"]
json.dump(d, open(p, "w"), indent=2)
os.remove("ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png")
'

check fail "iPad 167x167 entry and PNG deleted" "167x167" '
import json, os
p = "ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json"
d = json.load(open(p))
d["images"] = [e for e in d["images"]
               if not (e["idiom"] == "ipad" and e["size"] == "167x167")]
json.dump(d, open(p, "w"), indent=2)
os.remove("ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-167x167@2x.png")
'

check fail "entry with no filename key" "NO FILENAME" '
import json
p = "ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json"
d = json.load(open(p))
d["images"][0].pop("filename")
json.dump(d, open(p, "w"), indent=2)
'

check fail "stray unassigned PNG" "UNASSIGNED" '
open("ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-512x512@1x.png", "wb").write(
    b"\x89PNG\r\n\x1a\n" + b"\x00" * 16)
'

check fail "filename names a missing file" "MISSING FILE" '
import json
p = "ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json"
d = json.load(open(p))
for e in d["images"]:
    if e["size"] == "20x20" and e["scale"] == "2x":
        e["filename"] = "Icon-App-20x20@2x-removed.png"
json.dump(d, open(p, "w"), indent=2)
'

check fail "filename names a wrong-size PNG" "SIZE MISMATCH" '
import struct
# Only the IHDR width/height are read, so a header with the wrong pixels is
# enough to be a pixel-dimension mismatch for the 20x20@2x entry (expects 40).
open("ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@2x.png", "wb").write(
    b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", 8, 8))
'

# The repo checkout itself, not a copy of it: this is the "still exits 0 on a
# clean main" guarantee the CI step relies on.
if (cd "$REPO" && python3 scripts/check-appicon-entries.py >/dev/null 2>&1); then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL [repo checkout]: the guard did not pass on the tree as checked out"
fi

echo "check-appicon-entries: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
