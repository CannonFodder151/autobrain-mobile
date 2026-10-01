#!/usr/bin/env bash
#
# Self-check for the ios/.gitignore coverage of Flutter build artifacts.
#
# The root .gitignore stopped blanket-ignoring /ios/Flutter/ so that
# Flutter/Debug.xcconfig, Flutter/Release.xcconfig and
# Flutter/AppFrameworkInfo.plist stay tracked (AUT-4356 / AUT-4790, PR #84).
# That removal exposed generated artifacts which only the blanket rule used to
# hide, so ios/.gitignore has to cover them explicitly (AUT-4801).
#
# Asserts, against this checkout:
#   every generated path is ignored by an explicit ios/.gitignore rule
#   the three static xcconfig/plist files stay tracked and are NOT ignored
#   the sensitive generated files stay ignored
#
# Run: bash scripts/check-ios-flutter-ignore.test.sh
# Requires: bash + git.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
cd "$ROOT" || exit 1

fails=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

git check-ignore -q .gitignore 2>/dev/null && fail "not a git checkout" && exit 1

# Generated artifacts that must stay untracked. Each must resolve to a rule in
# ios/.gitignore specifically — a rule in the root .gitignore is what we are
# guarding against regressing into.
generated=(
  "ios/Flutter/app.dill"
  "ios/Flutter/flutter_build.d"
  "ios/Flutter/NativeAssets/"
  "ios/Flutter/App.framework.dSYM/"
  "ios/Flutter/Flutter.framework.dSYM/"
  "ios/Flutter/GeneratedPluginRegistrant.h"
  "ios/Flutter/GeneratedPluginRegistrant.m"
  # Sensitive generated files, to catch a rule being widened away.
  "ios/Flutter/Generated.xcconfig"
  "ios/Flutter/ephemeral/"
  "ios/Flutter/flutter_export_environment.sh"
  "ios/Flutter/App.framework"
  "ios/Flutter/Flutter.framework"
  "ios/Flutter/flutter_assets/"
)

for p in "${generated[@]}"; do
  rule="$(git check-ignore -v -- "$p" 2>/dev/null)"
  if [[ -z "$rule" ]]; then
    fail "$p is not ignored (would be committable)"
  elif [[ "$rule" != ios/.gitignore:* ]]; then
    fail "$p is ignored by ${rule%%$'\t'*} — want an explicit ios/.gitignore rule"
  else
    ok "$p ignored by ${rule%%$'\t'*}"
  fi
done

# The static files Runner.xcodeproj references as base configs/resources. If a
# rule ever hides one of these the CI checkout cannot build ("Unable to open
# base configuration reference file").
static=(
  "ios/Flutter/Debug.xcconfig"
  "ios/Flutter/Release.xcconfig"
  "ios/Flutter/AppFrameworkInfo.plist"
)

for p in "${static[@]}"; do
  git ls-files --error-unmatch -- "$p" >/dev/null 2>&1 \
    && ok "$p is tracked" \
    || fail "$p is not tracked — the ios/Flutter/ blanket rule came back"

  git check-ignore -q -- "$p" 2>/dev/null \
    && fail "$p is ignored — the ios/Flutter/ blanket rule came back" \
    || ok "$p is not ignored"
done

# Exactly the three static files, nothing else, may be tracked under ios/Flutter.
extra="$(git ls-files ios/Flutter | grep -vxF -f <(printf '%s\n' "${static[@]}") || true)"
if [[ -n "$extra" ]]; then
  fail "unexpected tracked files under ios/Flutter:"
  printf '       %s\n' $extra >&2
else
  ok "ios/Flutter tracks exactly the 3 static files"
fi

[[ $fails -eq 0 ]] || { echo "$fails assertion(s) failed" >&2; exit 1; }
echo "ALL ASSERTIONS PASSED"
