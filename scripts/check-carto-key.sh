#!/usr/bin/env bash
#
# Fails when CARTO_API_KEY is empty or missing from a compiled release artifact.
#
# Why (AUT-4823, mirrors the web guard from AUT-4690 / PR #822): the Servo Spy
# basemap key is injected at build time via `--dart-define=CARTO_API_KEY=...`.
# An unset/expired secret makes the build still SUCCEED, `cartoKeyParam('')`
# returns '', and the app ships the "API key required" watermapped public CARTO
# tile. Detection was a human QA curl weeks later (AUT-4533, AUT-4649).
#
# Two checks, both fatal:
#   1. CARTO_API_KEY is non-empty  -> fail fast, names the secret.
#   2. the key value is present in the compiled AOT snapshot -> catches a build
#      that dropped the --dart-define, or a string the app never reads.
#
# Usage:
#   CARTO_API_KEY=cb1_... bash scripts/check-carto-key.sh <artifact> [more...]
#
# A release artifact is a zip container; the AOT snapshot is:
#   Android .aab / .apk -> lib/<abi>/libapp.so
#   iOS .ipa            -> Payload/*.app/Frameworks/App.framework/App
# The script finds those members itself, so any container shape works.
#
# Uses python3 (present on every GH runner, ubuntu and macos alike) rather than
# unzip/zip, so it runs identically in CI and in a bare local checkout.
set -euo pipefail

key="${CARTO_API_KEY:-}"
if [[ -z "$key" ]]; then
  echo "::error::CARTO_API_KEY is empty. The GitHub Actions secret CARTO_API_KEY is unset or expired; refusing to release a key-less CARTO basemap (watermapped Servo Spy map)." >&2
  exit 1
fi

if [[ $# -eq 0 ]]; then
  echo "usage: CARTO_API_KEY=... bash $0 <artifact> [artifact...]" >&2
  exit 2
fi

failures=0
checked=0

for artifact in "$@"; do
  if [[ ! -f "$artifact" ]]; then
    echo "::error::artifact not found: $artifact" >&2
    failures=$((failures + 1))
    continue
  fi

  # Reports one line per AOT member examined:
  #   HIT  <member>   key found
  #   MISS <member>   key absent
  #   NONE <path>     container holds no AOT snapshot at all
  #   ERR  <path>     container unreadable
  report="$(
    CARTO_KEY="$key" python3 - "$artifact" <<'PY'
import os, re, sys, zipfile

AOT = re.compile(r"(libapp\.so$|Frameworks/App\.framework/App$|\.dill$)")

try:
    zf = zipfile.ZipFile(sys.argv[1])
except Exception as exc:  # not a zip, corrupt, truncated
    print("ERR  %s (%s)" % (sys.argv[1], exc))
    raise SystemExit(0)

needle = os.environ["CARTO_KEY"].encode()
members = [n for n in zf.namelist() if AOT.search(n)]
if not members:
    print("NONE %s" % sys.argv[1])
for name in members:
    try:
        hit = needle in zf.read(name)
    except Exception as exc:
        print("ERR  %s (%s)" % (name, exc))
        continue
    print("%s %s" % ("HIT " if hit else "MISS", name))
PY
  )" || true

  if [[ -z "$report" ]]; then
    echo "::error::could not inspect $artifact (is it a zip container?)" >&2
    failures=$((failures + 1))
    continue
  fi

  artifact_checked=0
  artifact_found=false
  while IFS= read -r line; do
    case "$line" in
      HIT\ *)
        artifact_checked=$((artifact_checked + 1))
        artifact_found=true
        echo "  ok: CARTO_API_KEY present in $artifact:${line#HIT }"
        ;;
      MISS\ *)
        artifact_checked=$((artifact_checked + 1))
        echo "  miss: CARTO_API_KEY absent from ${line#MISS } in $artifact"
        ;;
      NONE\ *)
        echo "::error::$artifact contains no AOT snapshot (expected libapp.so / App.framework/App / *.dill)" >&2
        failures=$((failures + 1))
        ;;
      ERR\ * )
        echo "::error::could not read ${line#ERR  } while inspecting $artifact" >&2
        failures=$((failures + 1))
        ;;
    esac
  done <<<"$report"

  checked=$((checked + artifact_checked))
  if [[ "$artifact_found" == "false" ]]; then
    echo "::error::CARTO_API_KEY value NOT found in the compiled AOT snapshot of $artifact. The build succeeded but the Servo Spy basemap will be watermapped. Check that the build step passes --dart-define=CARTO_API_KEY=." >&2
    failures=$((failures + 1))
  fi
done

if [[ "$checked" -eq 0 && "$failures" -eq 0 ]]; then
  echo "::error::no AOT member was checked; the guard did not actually verify anything" >&2
  exit 1
fi

if [[ "$failures" -gt 0 ]]; then
  echo "AUT-4823: $failures artifact(s) failed the CARTO_API_KEY guard." >&2
  exit 1
fi
echo "OK: CARTO_API_KEY present in $checked compiled artifact member(s)."
