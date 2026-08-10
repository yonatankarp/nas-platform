#!/bin/sh
set -eu
set +x
umask 077
dir=${PLATFORM_ADOPTION_SCRIPT_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)}
sandbox=${PLATFORM_MAC_SANDBOX:?}
project=${PLATFORM_PROJECT_NAME:?}
export PLATFORM_CONTRACT_VAULT_FILE=${PLATFORM_MAC_VAULT_FILE:?}
export PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=${PLATFORM_MAC_VAULT_PASSWORD_FILE:?}
if ! PLATFORM_IMMICH_UPLOAD_ROOT="$sandbox/legacy/immich/data/upload" \
  PLATFORM_IMMICH_THUMBNAIL_ROOT="$sandbox/legacy/immich/thumbs" \
  PLATFORM_IMMICH_SERVER_CONTAINER="$project-legacy-immich-immich-server-1" \
  PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER="$project-legacy-immich-immich-machine-learning-1" \
  PLATFORM_IMMICH_REDIS_CONTAINER="$project-legacy-immich-redis-1" \
  PLATFORM_IMMICH_POSTGRES_CONTAINER="$project-legacy-immich-database-1" \
  "$dir/../contracts/immich.sh" --platform mac assert-persistence >/dev/null 2>&1; then
  printf '%s\n' 'adoption-probe-error: immich evidence unavailable' >&2
  exit 1
fi
exec ruby "$dir/adoption-baseline.rb" --emit-probe immich
