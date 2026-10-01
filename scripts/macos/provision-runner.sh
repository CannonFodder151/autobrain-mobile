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
# Homebrew
#   Homebrew's stock installer needs `sudo` to create /usr/local. Probed on this
#   host: `sudo -n true` fails (the runner user has no NOPASSWD sudo),
#   /usr/local is root:wheel, and the Actions PATH does not even contain
#   /usr/local/bin. So this script falls back to cloning Homebrew into a
#   $HOME-owned prefix, which needs no privileges, and prefers /usr/local when
#   SUDO_PASSWORD is supplied or brew is already installed there.
#
# What it does — no sudo, no system paths, no root
#   1. builds a self-contained Ruby 3.x under $HOME/.rbenv via ruby-build
#      (ruby-build compiles its own OpenSSL/libyaml when the system copies are
#      too old, so `gem install` can still reach rubygems.org over HTTPS)
#   2. installs fastlane into a private GEM_HOME ($HOME/.gem)
#   3. installs Homebrew into $HOME/.homebrew (or /usr/local when privileged)
#   4. writes $HOME/.autobrain-toolchain.env, which every workflow sources via
#      scripts/macos/toolchain-env.sh (Actions steps never read ~/.zshrc)
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
HOMEBREW_DIR="$HOME/.homebrew"
ENV_FILE="$HOME/.autobrain-toolchain.env"
RBENV_REPO="https://github.com/rbenv/rbenv.git"
RUBY_BUILD_REPO="https://github.com/rbenv/ruby-build.git"

say()  { echo "==> $*"; }
warn() { echo "::warning::$*" >&2; }
die()  { echo "::error::$*" >&2; exit 1; }

# ------------------------------------------------------------- fastlane gate
# Skip the Ruby build only when fastlane already works AND Homebrew is already
# on PATH. Gating on fastlane alone meant a re-run after fastlane was installed
# exited at the top and never provisioned Homebrew, so the Homebrew acceptance
# criterion could never be met by a re-run.
brew_on_path() {
  { [ -x /usr/local/bin/brew ] || [ -x /opt/homebrew/bin/brew ] || [ -x "$HOMEBREW_DIR/bin/brew" ]; }
}

if brew_on_path && [ -x "$GEM_HOME_DIR/bin/fastlane" ] \
   && "$GEM_HOME_DIR/bin/fastlane" --version >/dev/null 2>&1; then
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
HOMEBREW_VARS=""
if [ -x /usr/local/bin/brew ]; then
  BREW_BIN="/usr/local/bin"
elif [ -x /opt/homebrew/bin/brew ]; then
  BREW_BIN="/opt/homebrew/bin"
fi

# ------------------------------------------------- 4. Homebrew (no sudo needed)
# Order matters: detect/provision Homebrew before the env file is written, so a
# brew installed here lands in the same env file that puts Ruby and fastlane on
# PATH.
if [ -z "$BREW_BIN" ]; then
  if [ -n "${SUDO_PASSWORD:-}" ]; then
    say "installing Homebrew to /usr/local (SUDO_PASSWORD supplied)"
    printf '%s\n' "$SUDO_PASSWORD" | sudo -S -p '' /bin/bash -c \
      'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' \
      || warn "Homebrew install failed; rbenv Ruby still provides fastlane"
  fi
  if [ -x /usr/local/bin/brew ]; then
    BREW_BIN="/usr/local/bin"
  elif [ -x /opt/homebrew/bin/brew ]; then
    BREW_BIN="/opt/homebrew/bin"
  fi
fi

if [ -n "$BREW_BIN" ]; then
  say "Homebrew present at $BREW_BIN/brew"
else
  # Unprivileged fallback. The stock installer needs sudo to create
  # /usr/local, and the runner user has no NOPASSWD sudo, so clone brew into a
  # $HOME-owned prefix instead. Homebrew derives its prefix from where the
  # repository lives, so HOMEBREW_PREFIX/HOMEBREW_CELLAR/HOMEBREW_REPOSITORY are
  # all redundant here — they only pin the cache/temp dirs inside $HOME, which
  # the default would already do but which we set explicitly so later steps
  # cannot fall back to a root-owned path.
  # ponytail: a $HOME prefix is not one of Homebrew's supported prefixes, so
  # `brew update` and bottle installs that hardlink into /usr/local can still
  # misbehave. Upgrade path: give the runner user NOPASSWD sudo (or an admin
  # account with one) and re-run this script, which then installs to
  # /usr/local via SUDO_PASSWORD and drops this branch entirely.
  say "installing Homebrew to $HOME/.homebrew (no sudo available)"
  if git clone --depth 1 https://github.com/Homebrew/brew.git "$HOMEBREW_DIR" >/dev/null 2>&1; then
    HOMEBREW_VARS="export HOMEBREW_NO_ANALYTICS=1"
    BREW_BIN="$HOMEBREW_DIR/bin"
    say "Homebrew cloned to $HOMEBREW_DIR"
  else
    warn "Homebrew clone failed; rbenv Ruby still provides fastlane"
    warn "Nathan, to satisfy the Homebrew acceptance criterion for AUT-4845 run once on the iMac:"
    warn "  sudo sh -c 'printf \"nathan ALL=(ALL) NOPASSWD: ALL\n\" > /etc/sudoers.d/github-actions-runner && chmod 440 /etc/sudoers.d/github-actions-runner'"
    warn "then re-run the 'Provision macOS runner toolchain' workflow."
  fi
fi

{
  echo "# generated by scripts/macos/provision-runner.sh — do not edit by hand"
  [ -n "$BREW_BIN" ] && echo "export PATH=\"$BREW_BIN:\$PATH\""
  # $RUBY_BIN/$GEM_HOME_DIR expand now; only \$PATH is left for the consumer.
  echo "export PATH=\"$RUBY_BIN:$GEM_HOME_DIR/bin:\$PATH\""
  echo "export GEM_HOME=\"$GEM_HOME_DIR\""
  echo "export GEM_PATH=\"$GEM_HOME_DIR\""
  [ -n "$HOMEBREW_VARS" ] && echo "$HOMEBREW_VARS"
} > "$ENV_FILE"
say "wrote $ENV_FILE"

# ----------------------------------------------------------------- 5. verify
# shellcheck disable=SC1090
. "$ENV_FILE"
command -v fastlane >/dev/null || die "fastlane still not on PATH after sourcing $ENV_FILE"
fastlane --version
if command -v brew >/dev/null; then
  brew --version | head -1
else
  die "brew not on PATH after sourcing $ENV_FILE"
fi
say "toolchain OK — source scripts/macos/toolchain-env.sh in later steps"
