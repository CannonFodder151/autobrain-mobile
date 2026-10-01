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
#   Homebrew's installer needs `sudo` to create /usr/local. Probed on this host:
#   `sudo -n true` fails (the runner user has no NOPASSWD sudo), /usr/local is
#   root:wheel, and the Actions PATH does not even contain /usr/local/bin. So
#   Homebrew cannot be provisioned unattended; see the NOPASSWD note at the end
#   of this script for the one command Nathan has to run once.
#
# What it does instead — no sudo, no system paths, no root
#   1. builds a self-contained Ruby 3.x under $HOME/.rbenv via ruby-build
#      (ruby-build compiles its own OpenSSL/libyaml when the system copies are
#      too old, so `gem install` can still reach rubygems.org over HTTPS)
#   2. installs fastlane into a private GEM_HOME ($HOME/.gem)
#   3. writes $HOME/.autobrain-toolchain.env, which every workflow sources via
#      scripts/macos/toolchain-env.sh (Actions steps never read ~/.zshrc)
#   4. best-effort Homebrew install when privileged access is available
#
# Idempotent: re-running is cheap and safe. Exits 0 once `fastlane --version`
# works, so it is safe to call from a provisioning workflow and from a
# re-provisioning step after a runner reimage.
#
# Env knobs:
#   AUTOBRAIN_RUBY_VERSION   Ruby to build (default 3.3.6)
#   SUDO_PASSWORD            if set, Homebrew is installed to /usr/local as well
set -euo pipefail

RUBY_VERSION="${AUTOBRAIN_RUBY_VERSION:-3.3.6}"
RBENV_DIR="$HOME/.rbenv"
GEM_HOME_DIR="$HOME/.gem"
ENV_FILE="$HOME/.autobrain-toolchain.env"
RBENV_REPO="https://github.com/rbenv/rbenv.git"
RUBY_BUILD_REPO="https://github.com/rbenv/ruby-build.git"

say()  { echo "==> $*"; }
warn() { echo "::warning::$*" >&2; }
die()  { echo "::error::$*" >&2; exit 1; }

# ---------------------------------------------------------------- fastlane gate
if [ -x "$GEM_HOME_DIR/bin/fastlane" ] && "$GEM_HOME_DIR/bin/fastlane" --version >/dev/null 2>&1; then
  say "fastlane already installed: $("$GEM_HOME_DIR/bin/fastlane" --version | head -1)"
  say "toolchain env: $ENV_FILE"
  exit 0
fi

# ----------------------------------------------------------------- 1. rbenv
if [ ! -x "$RBENV_DIR/bin/rbenv" ]; then
  say "installing rbenv -> $RBENV_DIR"
  git clone --depth 1 "$RBENV_REPO" "$RBENV_DIR"
  git clone --depth 1 "$RUBY_BUILD_REPO" "$RBENV_DIR/plugins/ruby-build"
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
say "installing fastlane into $GEM_HOME_DIR"
"$RUBY_BIN/gem" install fastlane --no-document --conservative \
  || die "gem install fastlane failed"
[ -x "$GEM_HOME_DIR/bin/fastlane" ] || die "fastlane not at $GEM_HOME_DIR/bin/fastlane"

# ------------------------------------------------------------- 3. env file
BREW_BIN=""
if [ -x /usr/local/bin/brew ]; then
  BREW_BIN="/usr/local/bin"
elif [ -x /opt/homebrew/bin/brew ]; then
  BREW_BIN="/opt/homebrew/bin"
fi

{
  echo "# generated by scripts/macos/provision-runner.sh — do not edit by hand"
  [ -n "$BREW_BIN" ] && echo "export PATH=\"$BREW_BIN:\$PATH\""
  # $RUBY_BIN/$GEM_HOME_DIR expand now; only \$PATH is left for the consumer.
  echo "export PATH=\"$RUBY_BIN:$GEM_HOME_DIR/bin:\$PATH\""
  echo "export GEM_HOME=\"$GEM_HOME_DIR\""
  echo "export GEM_PATH=\"$GEM_HOME_DIR\""
} > "$ENV_FILE"
say "wrote $ENV_FILE"

# ------------------------------------------- 4. best-effort Homebrew (needs sudo)
if [ -n "$BREW_BIN" ]; then
  say "Homebrew present at $BREW_BIN/brew"
elif [ -n "${SUDO_PASSWORD:-}" ]; then
  say "installing Homebrew to /usr/local (SUDO_PASSWORD supplied)"
  printf '%s\n' "$SUDO_PASSWORD" | sudo -S -p '' /bin/bash -c \
    'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' \
    || warn "Homebrew install failed; rbenv Ruby still provides fastlane"
else
  warn "Homebrew skipped: no passwordless sudo on this host."
  warn "Nathan, to satisfy the Homebrew acceptance criterion for AUT-4845 run once on the iMac:"
  warn "  sudo sh -c 'printf \"nathan ALL=(ALL) NOPASSWD: ALL\n\" > /etc/sudoers.d/github-actions-runner && chmod 440 /etc/sudoers.d/github-actions-runner'"
  warn "then re-run the 'Provision macOS runner toolchain' workflow."
fi

# ----------------------------------------------------------------- 5. verify
# shellcheck disable=SC1090
. "$ENV_FILE"
command -v fastlane >/dev/null || die "fastlane still not on PATH after sourcing $ENV_FILE"
fastlane --version
say "toolchain OK — source scripts/macos/toolchain-env.sh in later steps"
