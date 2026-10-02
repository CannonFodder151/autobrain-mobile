#!/usr/bin/env bash
# Self-check for the AUT-4845 macOS runner provisioning. No framework: asserts
# and exits non-zero on the first failure.
#
#   bash scripts/macos/provision-runner.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
fails=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

for f in provision-runner.sh toolchain-env.sh; do
  bash -n "$DIR/$f" && ok "$f parses" || fail "$f has a syntax error"
done

# toolchain-env.sh must fail loudly instead of silently exporting a stale PATH.
if TOOLCHAIN_ENV_FILE="$ROOT/does-not-exist" bash -c ". '$DIR/toolchain-env.sh'" >/dev/null 2>&1; then
  fail "toolchain-env.sh exits 0 when the env file is missing"
else
  ok "toolchain-env.sh fails when the env file is missing"
fi

# A well-formed env file must land Ruby and fastlane ahead of the system PATH.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/env" <<EOF
export PATH="/fake/rbenv/bin:/fake/gem/bin:\$PATH"
export GEM_HOME="/fake/gem"
EOF
out="$(TOOLCHAIN_ENV_FILE="$tmp/env" bash -c ". '$DIR/toolchain-env.sh'; echo \"\$PATH\"; echo \"\$GEM_HOME\"" 2>&1)"
case "$out" in
  /fake/rbenv/bin:/fake/gem/bin:*) ok "toolchain-env.sh prepends the toolchain to PATH" ;;
  *) fail "toolchain-env.sh did not prepend the toolchain: $out" ;;
esac
grep -qx '/fake/gem' <<<"$out" && ok "toolchain-env.sh exports GEM_HOME" \
  || fail "toolchain-env.sh did not export GEM_HOME: $out"

# provision-runner.sh must gate on a working SDK: mkmf compiles against
# rubyhdrdir/ruby.h and rubyarchhdrdir/ruby/config.h, and the CommandLineTools
# Ruby 2.6 that broke AUT-4290 has neither.
grep -q 'rubyarchhdrdir' "$DIR/provision-runner.sh" && ok "provision checks rubyarchhdrdir" \
  || fail "provision does not check rubyarchhdrdir"
grep -q 'ruby/ruby.h' "$DIR/provision-runner.sh" && ok "provision checks for ruby/ruby.h" \
  || fail "provision does not check for ruby/ruby.h"

# ruby-build vendors OpenSSL but not libyaml, and forces `--with-ext=psych`,
# so the build dies on macOS CommandLineTools unless libyaml is supplied. The
# script must both build it and pin its checksum.
grep -q 'with-libyaml-dir=' "$DIR/provision-runner.sh" && ok "provision supplies libyaml to ruby configure" \
  || fail "provision does not pass --with-libyaml-dir (psych will fail to build)"
grep -qE 'LIBYAML_SHA256=[0-9a-f]{64}' "$DIR/provision-runner.sh" && ok "libyaml tarball checksum is pinned" \
  || fail "libyaml tarball has no pinned sha256"

# AUT-4857: a build that silently skipped psych is still "BUILD SUCCESSFUL", and
# fastlane --version passes anyway because it parses YAML lazily. Both the script
# and the workflow must therefore assert psych loads.
grep -q 'require "psych"' "$DIR/provision-runner.sh" && ok "provision asserts psych loads" \
  || fail "provision does not assert psych loads (a skipped psych extension passes silently)"
grep -q 'require "psych"' "$ROOT/.github/workflows/install-fastlane.yml" \
  && ok "install-fastlane.yml asserts psych loads in the fresh step" \
  || fail "install-fastlane.yml does not assert psych loads"

# The greps above cannot tell a *working* assertion from one that dies on a bad
# Ruby API — AUT-4857 shipped `YAML.safe_load` right after `require "psych"`,
# which raises `uninitialized constant YAML` because `yaml` is the wrapper. That
# only surfaced on the runner. So execute the real snippet whenever a Ruby
# exists: it is the one assertion here that can actually be wrong.
psych_snippet() {
  # Match both `ruby -e '...'` and the script's `"$RUBY_BIN/ruby" -e '...'`, and
  # pick the psych one — other `ruby -e` calls (RbConfig probes) would match first.
  grep -oE "[^ ]*ruby\"? -e '[^']*'" "$1" \
    | grep 'require "psych"' | head -1 \
    | sed "s/.*ruby\"\? -e '//; s/'$//"
}
for f in "$DIR/provision-runner.sh" "$ROOT/.github/workflows/install-fastlane.yml"; do
  snip="$(psych_snippet "$f")"
  [ -n "$snip" ] || { fail "could not extract the psych assertion from ${f##*/}"; continue; }
  if ! command -v ruby >/dev/null 2>&1; then
    echo "skip - no ruby on this host to execute the psych assertion from ${f##*/}"
  elif out="$(ruby -e "$snip" 2>&1)"; then
    ok "psych assertion from ${f##*/} executes cleanly"
  else
    fail "psych assertion from ${f##*/} raised: $out"
  fi
done

# The env file is written by an inline block, so run that block for real with a
# fake prefix and assert every path landed expanded. A `\`-escaped own-variable
# writes the literal `$GEM_HOME_DIR` and the consuming step dies with
# "GEM_HOME_DIR: unbound variable" under `set -u` (run 36840539520).
gen="$(awk '/^\{$/{f=1;next} /^\} > /{f=0} f' "$DIR/provision-runner.sh")"
out="$(bash -c "set -eu
GEM_HOME_DIR=/fake/gem; RUBY_BIN=/fake/rbenv/bin; BREW_BIN=''
$gen" 2>&1)"
case "$out" in
  *'$GEM_HOME_DIR'*|*'$RUBY_BIN'*) fail "env file block emits unexpanded variables: $out" ;;
  *'PATH="/fake/rbenv/bin:/fake/gem/bin:$PATH"'*) ok "env file block expands paths and defers only \$PATH" ;;
  *) fail "env file block produced unexpected output: $out" ;;
esac

# The workflow must stay dispatch-only (runner isolation rules 1/4).
wf="$ROOT/.github/workflows/install-fastlane.yml"
grep -qE '^on:' "$wf" && grep -q 'workflow_dispatch' "$wf" && ok "install-fastlane.yml is dispatch-only" \
  || fail "install-fastlane.yml must be workflow_dispatch only"
grep -vE '^[[:space:]]*#' "$wf" | grep -qE '\$\{\{[[:space:]]*secrets\.' \
  && fail "install-fastlane.yml reads secrets" || ok "install-fastlane.yml reads no secrets"
grep -q 'scripts/macos/provision-runner.sh' "$wf" && ok "workflow calls the committed provisioning script" \
  || fail "workflow does not call scripts/macos/provision-runner.sh"
grep -qE '^concurrency:' "$wf" && grep -q 'macos-provision' "$wf" \
  && ok "install-fastlane.yml has a concurrency group" \
  || fail "install-fastlane.yml has no concurrency group (concurrent runs interleave GEM_HOME)"

# AUT-4882 F2: no root path at all. Piping a live network response into a sudo
# root shell from a moving `HEAD` ref is root on the signing host.
prov="$DIR/provision-runner.sh"
if grep -vE '^[[:space:]]*#' "$prov" | grep -qE 'sudo|NOPASSWD|sudoers'; then
  fail "provision-runner.sh still has a sudo/root path"
else
  ok "provision-runner.sh has no sudo/root path"
fi
if grep -qE 'curl[^|]*\|[[:space:]]*(sudo|bash|sh)' "$prov"; then
  fail "provision-runner.sh pipes a network response into a shell"
else
  ok "provision-runner.sh pipes no network response into a shell"
fi

# AUT-4964: `fastlane --version` is not a one-line command. fastlane's own
# `bin/fastlane` wrapper prints a three-line install-path preamble *before*
# commander's version line, and UpdateChecker appends an upgrade banner to
# stderr *after* it. The gate read the first line and compared it to
# "fastlane <version>", so a successful gem install died with
# `got 'fastlane installation at path:'`. Run the real function against a fake
# fastlane that reproduces that output shape.
gate_fn="$(awk '/^installed_fastlane\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$prov")"
run_gate() { # $1 = fake --version output (empty = no binary installed)
  rm -rf "$tmp/gem"; mkdir -p "$tmp/gem/bin"
  if [ -n "$1" ]; then
    { echo '#!/bin/sh'; echo "cat <<'STUB_EOF'"; printf '%s\n' "$1"; echo STUB_EOF; } > "$tmp/gem/bin/fastlane"
    chmod +x "$tmp/gem/bin/fastlane"
  fi
  GEM_HOME_DIR="$tmp/gem" bash -c "$gate_fn
installed_fastlane" 2>/dev/null
}
# The shape from the failing run: preamble, then the version, then a stderr
# upgrade banner — all merged, as a user actually sees them.
PREAMBLE='fastlane installation at path:
/fake/bundled
-----
fastlane 2.240.1
A new version of fastlane is available: 2.241.0'
for case in "$PREAMBLE" 'fastlane 2.239.0'; do
  got="$(run_gate "$case")"; rc=$?
  want="$(sed -nE 's/^(fastlane )?([0-9]+(\.[0-9]+)*)$/\2/p' <<<"$case" | head -1)"
  if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then
    ok "installed_fastlane extracts '${want:-<none>}' from multi-line output"
  else
    fail "installed_fastlane on [$(head -1 <<<"$case")…] -> rc=$rc got='$got' want='$want'"
  fi
done
got="$(run_gate '')"; rc=$?
[ "$rc" -ne 0 ] && [ -z "$got" ] && ok "installed_fastlane reports not-installed with rc 1, not an empty version" \
  || fail "installed_fastlane with no binary -> rc=$rc got='$got' (want rc!=0 and no version)"
# And the gate must compare bare, so the caller's short-circuit is not fooled.
grep -qE '\[ "\$have" = "\$FASTLANE_VERSION" \]' "$prov" \
  && ok "gate compares the bare version" || fail "gate does not compare the bare version"
grep -q 'head -1' "$prov" && fail "provision-runner.sh still reads a fixed output line" \
  || ok "provision-runner.sh reads no fixed output line"

# AUT-4882 F3: rbenv, ruby-build and fastlane must all be pinned. A moving
# default branch here is code exec that every later job sources through
# $HOME/.rbenv.
grep -qE 'RBENV_SHA="[0-9a-f]{40}"' "$prov" && grep -qE 'RUBY_BUILD_SHA="[0-9a-f]{40}"' "$prov" \
  && ok "rbenv and ruby-build are pinned to commit SHAs" \
  || fail "rbenv/ruby-build are not pinned to commit SHAs"
grep -q 'checkout --detach' "$prov" && ok "clones check out the pinned SHA" \
  || fail "clones do not check out a pinned SHA"
grep -qE 'gem"? install fastlane --version' "$prov" && ok "fastlane install is version-pinned" \
  || fail "fastlane install has no version constraint"
grep -qE '^FASTLANE_VERSION="\$\{AUTOBRAIN_FASTLANE_VERSION:-[0-9]+\.[0-9]+\.[0-9]+\}"' "$prov" \
  && ok "fastlane version is pinned in the script" || fail "no pinned fastlane version"

# AUT-4882 F7/F8: the env file is executed by every later job on a persistent
# runner. It must land 0600 and be renamed into place, not truncated in place.
grep -q 'chmod 600' "$prov" && grep -qE 'mv -f "\$tmp" "\$ENV_FILE"' "$prov" \
  && ok "env file is chmod 600 and renamed into place" \
  || fail "env file is not written atomically at 0600"
grep -qE '\[ ! -O "\$TOOLCHAIN_ENV_FILE" \]' "$DIR/toolchain-env.sh" \
  && ok "toolchain-env.sh refuses a file it does not own" \
  || fail "toolchain-env.sh does not verify env file ownership"

bash "$ROOT/scripts/check-workflow-runner-isolation.sh" >/dev/null 2>&1 \
  && ok "runner isolation gate passes" || fail "runner isolation gate fails"

if [ "$fails" -gt 0 ]; then
  echo "$fails check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
