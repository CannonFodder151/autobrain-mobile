#!/usr/bin/env bash
#
# Guards the ios/ ignore boundary (AUT-4801).
#
# Why: PR #84 (AUT-4790) removed the blanket `/ios/Flutter/` rule from the root
# .gitignore so Debug.xcconfig / Release.xcconfig / AppFrameworkInfo.plist stay
# tracked. The sensitive generated artifacts (Generated.xcconfig, ephemeral/,
# flutter_export_environment.sh, App.framework, flutter_assets/) are still
# covered by ios/.gitignore, but a few Flutter-generated ones were only hidden
# by that blanket rule and are now committable:
#
#   - *.framework.dSYM/ carries DWARF with absolute build-machine paths and
#     full symbol/type tables (information disclosure + repo bloat).
#   - *.dill is compiled Dart kernel, i.e. reviewable source-equivalent.
#
# This asserts both directions: those artifacts stay ignored, and the three
# static files the blanket rule used to hide stay tracked.
#
# Run: bash scripts/check-ios-gitignore.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
cd "$ROOT"
failures=0

must_be_ignored=(
  ios/Flutter/app.dill
  ios/Flutter/flutter_build.d
  ios/Flutter/NativeAssets/native_assets.yaml
  ios/Flutter/App.framework.dSYM/Info.plist
  ios/Flutter/Flutter.framework.dSYM/Info.plist
  ios/Flutter/GeneratedPluginRegistrant.h
  ios/Flutter/GeneratedPluginRegistrant.m
)

for path in "${must_be_ignored[@]}"; do
  if ! rule="$(git check-ignore -v -- "$path")"; then
    echo "::error::$path is committable; add an ios/.gitignore rule" >&2
    failures=$((failures + 1))
  elif [[ "$rule" != *"ios/.gitignore"* ]]; then
    echo "::error::$path is ignored by '$rule', not by an explicit ios/.gitignore rule" >&2
    failures=$((failures + 1))
  fi
done

# Debug.xcconfig / Release.xcconfig carry the Generated.xcconfig include and
# must stay tracked, otherwise the Xcode project has no Flutter build settings.
must_be_tracked=(
  ios/Flutter/AppFrameworkInfo.plist
  ios/Flutter/Debug.xcconfig
  ios/Flutter/Release.xcconfig
)

for path in "${must_be_tracked[@]}"; do
  if ! git ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
    echo "::error::$path is no longer tracked (AUT-4790 regression)" >&2
    failures=$((failures + 1))
  fi
done

extra="$(git ls-files -- ios/Flutter | grep -vxF -f <(printf '%s\n' "${must_be_tracked[@]}") || true)"
if [[ -n "$extra" ]]; then
  echo "::error::unexpected file(s) tracked under ios/Flutter: $extra" >&2
  failures=$((failures + 1))
fi

if [[ "$failures" -gt 0 ]]; then
  echo "AUT-4801: $failures ios/ ignore-boundary violation(s)." >&2
  exit 1
fi
echo "OK: ${#must_be_ignored[@]} Flutter artifacts ignored via ios/.gitignore; ${#must_be_tracked[@]} static ios/Flutter files tracked."