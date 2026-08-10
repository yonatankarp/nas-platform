#!/bin/sh
set -eu
set +x
umask 077
dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
sandbox=${PLATFORM_MAC_SANDBOX:?}
project=${PLATFORM_PROJECT_NAME:?}
export PLATFORM_CONTRACT_VAULT_FILE=${PLATFORM_MAC_VAULT_FILE:?}
export PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=${PLATFORM_MAC_VAULT_PASSWORD_FILE:?}
if ! PLATFORM_JELLYFIN_MEDIA_ROOT="$sandbox/legacy/jellyfin/media" \
  PLATFORM_JELLYFIN_TRANSCODE_ROOT="$sandbox/legacy/jellyfin/cache/transcodes" \
  PLATFORM_JELLYFIN_CONTAINER="$project-legacy-jellyfin-jellyfin-1" \
  "$dir/../contracts/jellyfin.sh" --platform mac assert-persistence >/dev/null 2>&1; then
  printf '%s\n' 'adoption-probe-error: jellyfin evidence unavailable' >&2
  exit 1
fi
exec ruby "$dir/adoption-baseline.rb" --emit-probe jellyfin
