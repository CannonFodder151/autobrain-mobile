#!/usr/bin/env bash
# AUT-4840: install fastlane on a self-hosted macOS runner and prove it runs.
#
# Homebrew is preferred when present. Nathans-iMac-Pro (x86_64, macOS 12.6) has
# no Homebrew at any prefix and no passwordless sudo (runs 36820215347, 36821136891),
# so `brew install fastlane` only ever exits 127. The system Ruby in
# MacOSX13.1.sdk is not a fallback either: it has no ruby/config.h, so gems with
# a C extension (fastlane pulls `cgi`) fail to build. ruby/setup-ruby@v1 refuses
# the self-hosted macos-12-x64 label, and the ruby-builder toolcache tarball it
# downloads hardcodes absolute paths into /Users/runner/hostedtoolcache and
# /usr/local/opt/gmp (verified on run 36821266514), neither of which is writable
# here. So fall back to a prebuilt conda-forge Ruby in user space via micromamba:
# no sudo, no Homebrew, complete headers.
#
# Deliberate simplification: the Ruby prefix is pinned to $HOME/.rubies/ruby so it
# can be cached by actions/cache. If the runner user changes, bump RUBY_PREFIX.
set -euo pipefail

RUBY_VERSION="${RUBY_VERSION:-3.3}"
RUBY_PREFIX="${RUBY_PREFIX:-$HOME/.rubies/ruby}"
MICROMAMBA="${MICROMAMBA:-$HOME/.local/bin/micromamba}"
export MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-$HOME/.micromamba}"

log() { printf '>>> %s\n' "$*"; }

install_micromamba() {
  [[ -x "$MICROMAMBA" ]] && return 0
  log "fetching micromamba"
  mkdir -p "$(dirname "$MICROMAMBA")"
  local archive="$RUNNER_TEMP/micromamba-download"
  curl -fsSL --retry 3 -o "$archive" \
    https://github.com/mamba-org/micromamba-releases/releases/latest/download/micromamba-osx-64
  # Some assets are a bare binary, others a bzipped tarball containing bin/micromamba.
  if ! tar -xjf "$archive" -C "$RUNNER_TEMP" bin/micromamba 2>/dev/null; then
    mv "$archive" "$MICROMAMBA"
    chmod +x "$MICROMAMBA"
    return 0
  fi
  mv "$RUNNER_TEMP/bin/micromamba" "$MICROMAMBA"
}

provision_ruby() {
  log "provisioning Ruby ${RUBY_VERSION} into ${RUBY_PREFIX} (micromamba, user space)"
  install_micromamba
  local installed
  installed="$("$RUBY_PREFIX/bin/ruby" -e 'print RUBY_VERSION' 2>/dev/null || true)"
  if [[ "$installed" != "$RUBY_VERSION".* ]]; then
    [[ -x "$RUBY_PREFIX/bin/ruby" ]] && log "replacing Ruby ${installed} at ${RUBY_PREFIX}"
    "$MICROMAMBA" create --yes --prefix "$RUBY_PREFIX" --channel conda-forge "ruby=${RUBY_VERSION}"
  fi
  "$RUBY_PREFIX/bin/ruby" --version
  "$RUBY_PREFIX/bin/gem" --version
}

# 3.3 is the newest conda-forge Ruby for osx-64 that builds against the Apple clang
# 14 shipped with Xcode 14 (3.4 headers need the C23 stdckdint.h). The Ruby is
# configured with a triplet-prefixed compiler
# (x86_64-apple-darwin13.4.0-clang) that only exists when the conda clang package
# is installed, so gem native extensions fail with
# `make: x86_64-apple-darwin13.4.0-clang: No such file or directory` (run
# 36822553933). The box has Xcode's clang, so shim whatever CC/CXX/LD name this
# Ruby was configured with onto it.
ensure_compiler() {
  local var name
  for var in CC CXX LD; do
    name="$("$RUBY_PREFIX/bin/ruby" -rrbconfig -e "print RbConfig::CONFIG['$var'].to_s.split(/\s+/).first")"
    [[ -z "$name" || "$name" == */* ]] && continue
    command -v "$name" >/dev/null 2>&1 && continue
    log "shimming missing compiler ${name} -> clang"
    printf '#!/bin/sh\nexec clang "$@"\n' > "$RUBY_PREFIX/bin/$name"
    chmod +x "$RUBY_PREFIX/bin/$name"
  done
  clang --version | head -1
}

for prefix in /usr/local/bin /opt/homebrew/bin; do
  [[ -x "$prefix/brew" ]] && export PATH="$prefix:$PATH"
done

if command -v brew >/dev/null 2>&1; then
  log "using Homebrew at $(command -v brew)"
  brew install fastlane
else
  log "no Homebrew on this runner; using a user-space Ruby instead"
  provision_ruby
  export PATH="$RUBY_PREFIX/bin:$PATH"
  ensure_compiler
  "$RUBY_PREFIX/bin/gem" install fastlane --no-document
  # conda-forge's RubyGems puts binaries in its own bindir, not $RUBY_PREFIX/bin.
  BINDIR="$("$RUBY_PREFIX/bin/ruby" -e 'print Gem.bindir')"
  log "fastlane bindir: ${BINDIR}"
  export PATH="$BINDIR:$RUBY_PREFIX/bin:$PATH"
  echo "$BINDIR" >> "${GITHUB_PATH:-/dev/null}"
fi

export PATH="$RUBY_PREFIX/bin:$PATH"
command -v fastlane
# No `|| true`: the point of this script is to prove the runner can install and
# run fastlane, so a failed install must keep failing the job.
fastlane --version