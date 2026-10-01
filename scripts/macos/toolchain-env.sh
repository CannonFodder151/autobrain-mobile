#!/usr/bin/env bash
#
# PATH/GEM_HOME for the AutoBrain macOS runner toolchain.
#
# AUT-4845: GitHub Actions steps run `/bin/bash -e` with a non-login shell and
# a launchd-inherited PATH (/usr/bin:/bin:/usr/sbin:/sbin), so `~/.zshrc` and
# friends are never read. Sourcing this file is the only supported way for a
# step to see the provisioned Ruby and fastlane.
#
# Source, do not execute:
#   source "$HOME/.autobrain-toolchain.env"
#
# The env file is written by scripts/macos/provision-runner.sh. If it is
# missing (fresh host, runner reimage) run the provision script first.

TOOLCHAIN_ENV_FILE="${TOOLCHAIN_ENV_FILE:-$HOME/.autobrain-toolchain.env}"

if [ ! -f "$TOOLCHAIN_ENV_FILE" ]; then
  echo "::error::no toolchain env at $TOOLCHAIN_ENV_FILE; run scripts/macos/provision-runner.sh on this runner first" >&2
  return 1 2>/dev/null || exit 1
fi

# shellcheck disable=SC1090
. "$TOOLCHAIN_ENV_FILE"
