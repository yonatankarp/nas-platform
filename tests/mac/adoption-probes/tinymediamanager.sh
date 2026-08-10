#!/bin/sh
set -eu
set +x
umask 077
dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
sandbox=${PLATFORM_MAC_SANDBOX:?}
project=${PLATFORM_PROJECT_NAME:?}
export PLATFORM_CONTRACT_VAULT_FILE=${PLATFORM_MAC_VAULT_FILE:?}
export PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=${PLATFORM_MAC_VAULT_PASSWORD_FILE:?}
if ! PLATFORM_TINYMEDIAMANAGER_MOVIES_ROOT="$sandbox/legacy/tinymediamanager/movies" \
  PLATFORM_TINYMEDIAMANAGER_SERIES_ROOT="$sandbox/legacy/tinymediamanager/series" \
  PLATFORM_TINYMEDIAMANAGER_SETTINGS_ROOT="$sandbox/legacy/tinymediamanager/data/data" \
  PLATFORM_TINYMEDIAMANAGER_CONTAINER="$project-legacy-tinymediamanager-tinymediamanager-1" \
  "$dir/../contracts/tinymediamanager.sh" assert-persistence >/dev/null 2>&1; then
  printf '%s\n' 'adoption-probe-error: tinymediamanager evidence unavailable' >&2
  exit 1
fi
exec ruby "$dir/adoption-baseline.rb" --emit-probe tinymediamanager
