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

# The workflow must stay dispatch-only (runner isolation rule 3).
wf="$ROOT/.github/workflows/install-fastlane.yml"
grep -qE '^on:' "$wf" && grep -q 'workflow_dispatch' "$wf" && ok "install-fastlane.yml is dispatch-only" \
  || fail "install-fastlane.yml must be workflow_dispatch only"
grep -vE '^[[:space:]]*#' "$wf" | grep -qE '\$\{\{[[:space:]]*secrets\.' \
  && fail "install-fastlane.yml reads secrets" || ok "install-fastlane.yml reads no secrets"
grep -q 'scripts/macos/provision-runner.sh' "$wf" && ok "workflow calls the committed provisioning script" \
  || fail "workflow does not call scripts/macos/provision-runner.sh"

bash "$ROOT/scripts/check-workflow-runner-isolation.sh" >/dev/null 2>&1 \
  && ok "runner isolation gate passes" || fail "runner isolation gate fails"

if [ "$fails" -gt 0 ]; then
  echo "$fails check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
