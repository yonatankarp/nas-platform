#!/bin/sh
set -eu
set +x
umask 077
dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
sandbox=${PLATFORM_MAC_SANDBOX:?}
export PLATFORM_CONTRACT_VAULT_FILE=${PLATFORM_MAC_VAULT_FILE:?}
export PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=${PLATFORM_MAC_VAULT_PASSWORD_FILE:?}
if ! PLATFORM_KOMGA_LIBRARY_PATH="$sandbox/legacy/komga/library" \
  "$dir/../contracts/komga.sh" assert-persistence >/dev/null 2>&1; then
  printf '%s\n' 'adoption-probe-error: komga evidence unavailable' >&2
  exit 1
fi
exec ruby "$dir/adoption-baseline.rb" --emit-probe komga
