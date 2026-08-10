#!/bin/sh
set -eu
set +x
umask 077
dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
sandbox=${PLATFORM_MAC_SANDBOX:?}
export PLATFORM_CONTRACT_VAULT_FILE=${PLATFORM_MAC_VAULT_FILE:?}
export PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=${PLATFORM_MAC_VAULT_PASSWORD_FILE:?}
if ! PLATFORM_AUDIOBOOKSHELF_MEDIA_LIBRARY="$sandbox/legacy/audiobookshelf/media" \
  "$dir/../contracts/audiobookshelf.sh" assert-persistence >/dev/null 2>&1; then
  printf '%s\n' 'adoption-probe-error: audiobookshelf evidence unavailable' >&2
  exit 1
fi
exec ruby "$dir/adoption-baseline.rb" --emit-probe audiobookshelf
