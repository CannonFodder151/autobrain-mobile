#!/usr/bin/env bash
#
# Provision the AutoBrain toolchain (Ruby + fastlane) on the self-hosted macOS
# runner Nathans-iMac-Pro (runner service user `nathan`).
#
# Why this exists (AUT-4845)
#   The host has no Homebrew and only the CommandLineTools Ruby 2.6.10. That
#   SDK is missing its own ruby/config.h, so `gem install fastlane` dies while
#   building native extensions (run 36825183321). install-fastlane.yml has
#   failed 5/5 times for that reason.
#
# Why not Homebrew
#   Homebrew's installer needs root to create /usr/local, and this script has no
#   root path at all (AUT-4882): piping an unpinned network response into a root
#   shell from a moving ref is root on the signing host if upstream is ever
#   compromised. /usr/local/bin is prepended to PATH instead when brew already
#   exists; installing brew is a deliberate one-off by a human, not something a
#   workflow does on a runner.
#
# What it does instead — no sudo, no system paths, no root
#   1. builds a self-contained Ruby 3.x under $HOME/.rbenv via ruby-build
#      (ruby-build compiles its own OpenSSL/libyaml when the system copies are
#      too old, so `gem install` can still reach rubygems.org over HTTPS)
#   2. installs a pinned fastlane into a private GEM_HOME ($HOME/.gem)
#   3. writes $HOME/.autobrain-toolchain.env, which every workflow sources via
#      scripts/macos/toolchain-env.sh (Actions steps never read ~/.zshrc)
#
# Idempotent: re-running is cheap and safe. Exits 0 once `fastlane --version`
# works, so it is safe to call from a provisioning workflow and from a
# re-provisioning step after a runner reimage.
#
# Trust model (AUT-4882): every downloaded artefact is pinned to an immutable
# ref or checksum before it runs. rbenv/ruby-build are pinned to commit SHAs,
# the libyaml tarball to a SHA-256, and fastlane to an exact version. Nothing
# here resolves a moving branch or a `HEAD` URL.
#   Residual: pinning removes upstream *drift* risk, not upstream *compromise*
#   risk. The real reduction is not rebuilding a 20-minute source toolchain on
#   the signing host on every reimage — bake a runner image with the toolchain
#   instead.
#
# Env knobs:
#   AUTOBRAIN_RUBY_VERSION   Ruby to build (default 3.3.6)
#   AUTOBRAIN_FASTLANE_VERSION  fastlane to install (default 2.225.1)
set -euo pipefail

RUBY_VERSION="${AUTOBRAIN_RUBY_VERSION:-3.3.6}"
FASTLANE_VERSION="${AUTOBRAIN_FASTLANE_VERSION:-2.240.1}"
RBENV_DIR="$HOME/.rbenv"
GEM_HOME_DIR="$HOME/.gem"
ENV_FILE="$HOME/.autobrain-toolchain.env"
RBENV_REPO="https://github.com/rbenv/rbenv.git"
RBENV_SHA="07e9b1e297a5977298c6aadc9971ae0e9eb7f0dc"
RUBY_BUILD_REPO="https://github.com/rbenv/ruby-build.git"
RUBY_BUILD_SHA="db86e6ddd6d3b1d8715d005b65fab0c3f2804fdd"

say()  { echo "==> $*"; }
warn() { echo "::warning::$*" >&2; }
die()  { echo "::error::$*" >&2; exit 1; }

# ---------------------------------------------------------------- fastlane gate
installed_fastlane() {
  [ -x "$GEM_HOME_DIR/bin/fastlane" ] \
    && "$GEM_HOME_DIR/bin/fastlane" --version 2>/dev/null | head -1
}
# Only an exact-version match short-circuits: a drift-tolerant gate would leave
# an unpinned fastlane in place forever.
if have="$(installed_fastlane)"; then
  if [ "$have" = "fastlane $FASTLANE_VERSION" ]; then
    say "fastlane already installed: $have"
    say "toolchain env: $ENV_FILE"
    exit 0
  fi
  say "fastlane $have != pinned $FASTLANE_VERSION; reinstalling"
fi

# ----------------------------------------------------------------- 1. rbenv
# `--depth 1` + `checkout <sha>` pins to an immutable commit: a compromised
# default branch cannot change what this script builds. ruby-build compiles a
# Ruby and its own OpenSSL from source and the result is `source`d by every
# later job through $HOME/.rbenv, so drift here is a persistent foothold
# (AUT-4882 F3).
clone_pinned() {
  local repo="$1" sha="$2" dir="$3"
  rm -rf "$dir"
  git clone --depth 1 "$repo" "$dir"
  git -C "$dir" fetch --depth 1 origin "$sha"
  git -C "$dir" checkout --detach "$sha"
  git -C "$dir" rev-parse HEAD | grep -qx "$sha" \
    || die "$repo is not at pinned $sha"
}

if [ ! -x "$RBENV_DIR/bin/rbenv" ]; then
  say "installing rbenv $RBENV_SHA -> $RBENV_DIR"
  clone_pinned "$RBENV_REPO" "$RBENV_SHA" "$RBENV_DIR"
  clone_pinned "$RUBY_BUILD_REPO" "$RUBY_BUILD_SHA" "$RBENV_DIR/plugins/ruby-build"
else
  say "rbenv present"
fi

export RBENV_ROOT="$RBENV_DIR"
PATH="$RBENV_DIR/bin:$PATH"
export PATH

# -- libyaml -----------------------------------------------------------
# ruby-build vendors OpenSSL but not libyaml, and its ruby definitions force
# `--with-ext=openssl,psych,+`, so a host without `brew --prefix libyaml` fails
# the build on psych. macOS 12's CommandLineTools ship no libyaml headers, so
# build it into a private prefix and point ruby's configure at it.
LIBYAML_VERSION=0.2.5
LIBYAML_SHA256=c642ae9b75fee120b2d96c712538bd2cf283228d2337df2cf2988e3c02678ef4
VENDOR_DIR="$RBENV_DIR/vendor"
LIBYAML_DIR="$VENDOR_DIR/yaml-$LIBYAML_VERSION"
LIBYAML_TARBALL="$VENDOR_DIR/yaml-$LIBYAML_VERSION.tar.gz"

if [ ! -f "$LIBYAML_DIR/include/yaml.h" ]; then
  mkdir -p "$VENDOR_DIR"
  if [ ! -f "$LIBYAML_TARBALL" ]; then
    say "downloading libyaml $LIBYAML_VERSION"
    curl -fsSL -o "$LIBYAML_TARBALL.part" \
      "https://github.com/yaml/libyaml/releases/download/$LIBYAML_VERSION/yaml-$LIBYAML_VERSION.tar.gz"
    mv "$LIBYAML_TARBALL.part" "$LIBYAML_TARBALL"
  fi
  echo "$LIBYAML_SHA256  $LIBYAML_TARBALL" | shasum -a 256 -c - >/dev/null \
    || die "libyaml $LIBYAML_VERSION checksum mismatch — refusing to build it"
  say "building libyaml $LIBYAML_VERSION -> $LIBYAML_DIR"
  rm -rf "$LIBYAML_DIR"
  tar -xzf "$LIBYAML_TARBALL" -C "$VENDOR_DIR"
  # shellcheck disable=SC2086
  ( cd "$LIBYAML_DIR" && ./configure --prefix="$LIBYAML_DIR" >/dev/null \
      && make -j"$(sysctl -n hw.ncpu)" >/dev/null && make install >/dev/null ) \
    || die "libyaml build failed"
else
  say "libyaml already built at $LIBYAML_DIR"
fi

# -- Ruby --------------------------------------------------------------
# Keep the failed build tree so a failure is inspectable on the host instead
# of only in a job log.
export RUBY_BUILD_BUILD_PATH="$RBENV_DIR/build/ruby-$RUBY_VERSION"

if [ ! -x "$RBENV_DIR/versions/$RUBY_VERSION/bin/ruby" ]; then
  say "building Ruby $RUBY_VERSION (no-doc, ~10-25 min on this host)"
  # --disable-install-doc keeps the build to minutes, not tens of minutes.
  RUBY_CONFIGURE_OPTS="--disable-install-doc --with-libyaml-dir=$LIBYAML_DIR" \
    "$RBENV_DIR/bin/rbenv" install "$RUBY_VERSION" \
    || die "ruby-build failed for $RUBY_VERSION; build tree left at $RUBY_BUILD_BUILD_PATH"
else
  say "Ruby $RUBY_VERSION already built"
fi

RUBY_BIN="$RBENV_DIR/versions/$RUBY_VERSION/bin"
[ -x "$RUBY_BIN/ruby" ] || die "ruby missing at $RUBY_BIN/ruby"
"$RUBY_BIN/ruby" --version
# A usable SDK must ship the headers mkmf actually compiles against: ruby.h in
# rubyhdrdir and the generated config.h in rubyarchhdrdir (mkmf sets
# `$config_h = '$(arch_hdrdir)/ruby/config.h'`). The system Ruby 2.6 that broke
# AUT-4290 has neither. Checking rubyhdrdir for config.h is wrong on Ruby 3.x
# and fails a perfectly good build.
HDRDIR="$("$RUBY_BIN/ruby" -e 'print RbConfig::CONFIG["rubyhdrdir"]')"
ARCHHDRDIR="$("$RUBY_BIN/ruby" -e 'print RbConfig::CONFIG["rubyarchhdrdir"]')"
[ -f "$HDRDIR/ruby/ruby.h" ] || die "ruby/ruby.h missing under $HDRDIR — native extensions would fail"
[ -f "$ARCHHDRDIR/ruby/config.h" ] || die "ruby/config.h missing under $ARCHHDRDIR — native extensions would fail"
say "ruby headers OK: $HDRDIR/ruby/ruby.h, $ARCHHDRDIR/ruby/config.h"

# AUT-4857: the extension ruby-build forced `--with-ext=...,psych,+` can still be
# skipped without failing the build on some paths, and a Ruby without psych breaks
# gem/bundler/fastlane YAML parsing at a much later, more confusing point. Prove it
# here, immediately after the build.
# `require "psych"` does not define the top-level YAML constant — that is `yaml`,
# which wraps psych. Call Psych directly so this checks psych and nothing else.
"$RUBY_BIN/ruby" -e 'require "psych"; Psych.safe_load("a: 1"); require "yaml"; YAML.safe_load("a: 1")' \
  || die "psych did not load — libyaml is missing; fastlane cannot parse YAML without it"
say "psych OK: $("$RUBY_BIN/ruby" -e 'require "psych"; print Psych::VERSION')"

# ------------------------------------------------------------- 2. fastlane gem
export GEM_HOME="$GEM_HOME_DIR"
export GEM_PATH="$GEM_HOME_DIR"
mkdir -p "$GEM_HOME_DIR"
say "installing fastlane $FASTLANE_VERSION into $GEM_HOME_DIR"
# Exact version, no floating constraint: an unpinned `gem install fastlane` is
# arbitrary code from rubygems.org compiled on the signing host (AUT-4882 F3).
"$RUBY_BIN/gem" install fastlane --version "$FASTLANE_VERSION" \
  --no-document --conservative \
  || die "gem install fastlane $FASTLANE_VERSION failed"
[ -x "$GEM_HOME_DIR/bin/fastlane" ] || die "fastlane not at $GEM_HOME_DIR/bin/fastlane"
[ "$(installed_fastlane)" = "fastlane $FASTLANE_VERSION" ] \
  || die "fastlane version mismatch: want $FASTLANE_VERSION, got '$(installed_fastlane)'"

# ------------------------------------------------------------- 3. env file
BREW_BIN=""
if [ -x /usr/local/bin/brew ]; then
  BREW_BIN="/usr/local/bin"
elif [ -x /opt/homebrew/bin/brew ]; then
  BREW_BIN="/opt/homebrew/bin"
fi

tmp="$(mktemp "$HOME/.autobrain-toolchain.env.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

{
  echo "# generated by scripts/macos/provision-runner.sh — do not edit by hand"
  [ -n "$BREW_BIN" ] && echo "export PATH=\"$BREW_BIN:\$PATH\""
  # $RUBY_BIN/$GEM_HOME_DIR expand now; only \$PATH is left for the consumer.
  echo "export PATH=\"$RUBY_BIN:$GEM_HOME_DIR/bin:\$PATH\""
  echo "export GEM_HOME=\"$GEM_HOME_DIR\""
  echo "export GEM_PATH=\"$GEM_HOME_DIR\""
} > "$tmp"
# chmod not umask: mktemp already created it 0600 and this also fixes up a file
# left over from an older run at 0644.
chmod 600 "$tmp"
# rename, never truncate-in-place: a concurrent step sourcing a half-written
# file would load a partial PATH (AUT-4882 F8).
mv -f "$tmp" "$ENV_FILE"
say "wrote $ENV_FILE (mode $(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || echo 600))"

# ------------------------------------------------------- 4. Homebrew (optional)
# Reported, never installed. There is no root path in this script on purpose
# (AUT-4882 F2): Homebrew's installer was reached by piping an unpinned
# `.../HEAD/install.sh` into a sudo'd root shell, which makes upstream
# compromise root on the signing host. If brew is missing, rbenv Ruby still
# provides fastlane; installing brew is a deliberate one-off by a human.
if [ -n "$BREW_BIN" ]; then
  say "Homebrew present at $BREW_BIN/brew"
else
  warn "Homebrew absent; continuing on rbenv Ruby (fastlane still works)."
  warn "To add brew, Nathan runs its installer once by hand — this script will not."
fi

# ----------------------------------------------------------------- 5. verify
# shellcheck disable=SC1090
. "$ENV_FILE"
command -v fastlane >/dev/null || die "fastlane still not on PATH after sourcing $ENV_FILE"
fastlane --version
say "toolchain OK — source scripts/macos/toolchain-env.sh in later steps"
