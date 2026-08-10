#!/bin/sh
set -eu
set +x
umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$script_dir/lib.sh"

[ "${1-}" = seed ] && [ "$#" -eq 1 ] || mac_die 'usage: legacy-fixtures.sh seed'
: "${PLATFORM_MAC_SANDBOX:?PLATFORM_MAC_SANDBOX is required}"
: "${PLATFORM_PROJECT_NAME:?PLATFORM_PROJECT_NAME is required}"
PLATFORM_MAC_SANDBOX=$(mac_validate_sandbox "$PLATFORM_MAC_SANDBOX") ||
  mac_die 'owned sandbox is invalid'
owned_project=$(sed -n 's/^project=//p' "$PLATFORM_MAC_SANDBOX/.nas-platform-mac-owned")
[ "$PLATFORM_PROJECT_NAME" = "$owned_project" ] || mac_die 'project name differs from owned sandbox'
export PLATFORM_LEGACY_FIXTURE_MODE=nas-platform-owned-legacy-v1
export PLATFORM_LEGACY_FIXTURE_SANDBOX=$PLATFORM_MAC_SANDBOX

driver=${PLATFORM_LEGACY_FIXTURE_DRIVER:-$script_dir/legacy-fixture-service.sh}
[ -x "$driver" ] && [ ! -L "$driver" ] || mac_die 'legacy fixture driver is unavailable'
if [ "$driver" != "$script_dir/legacy-fixture-service.sh" ]; then
  mac_validate_lexical_path "$driver" 'legacy fixture driver' >/dev/null 2>&1 ||
    mac_die 'legacy fixture driver is unavailable'
  driver_parent=$(CDPATH= cd -- "$(dirname -- "$driver")" 2>/dev/null && pwd -P) ||
    mac_die 'legacy fixture driver is unavailable'
  case $driver in "$PLATFORM_MAC_SANDBOX"/*) ;; *) mac_die 'legacy fixture driver is unavailable' ;; esac
  [ "$driver_parent/$(basename -- "$driver")" = "$driver" ] &&
    [ "$(mac_owner_id "$driver")" = "$(id -u)" ] &&
    [ "$(mac_file_mode "$driver")" = 700 ] || mac_die 'legacy fixture driver is unavailable'
fi

run_fixture() {
  fixture_service=$1
  fixture_compose_service=$2
  fixture_mode=$3
  PLATFORM_FIXTURE_COMPOSE_PROJECT="$PLATFORM_PROJECT_NAME-legacy-$fixture_service" \
  PLATFORM_FIXTURE_COMPOSE_SERVICE="$fixture_compose_service" \
    "$driver" "$fixture_service" "$fixture_mode"
}

export PLATFORM_AUDIOBOOKSHELF_MEDIA_LIBRARY="$PLATFORM_MAC_SANDBOX/legacy/audiobookshelf/media"
run_fixture audiobookshelf audiobookshelf seed-progress
export PLATFORM_KOMGA_LIBRARY_PATH="$PLATFORM_MAC_SANDBOX/legacy/komga/library"
run_fixture komga komga seed
export PLATFORM_TINYMEDIAMANAGER_MOVIES_ROOT="$PLATFORM_MAC_SANDBOX/legacy/tinymediamanager/movies"
export PLATFORM_TINYMEDIAMANAGER_SERIES_ROOT="$PLATFORM_MAC_SANDBOX/legacy/tinymediamanager/series"
export PLATFORM_TINYMEDIAMANAGER_SETTINGS_ROOT="$PLATFORM_MAC_SANDBOX/legacy/tinymediamanager/data/data"
export PLATFORM_TINYMEDIAMANAGER_CONTAINER="$PLATFORM_PROJECT_NAME-legacy-tinymediamanager-tinymediamanager-1"
run_fixture tinymediamanager tinymediamanager seed
export PLATFORM_JELLYFIN_MEDIA_ROOT="$PLATFORM_MAC_SANDBOX/legacy/jellyfin/media"
export PLATFORM_JELLYFIN_TRANSCODE_ROOT="$PLATFORM_MAC_SANDBOX/legacy/jellyfin/cache/transcodes"
export PLATFORM_JELLYFIN_CONTAINER="$PLATFORM_PROJECT_NAME-legacy-jellyfin-jellyfin-1"
run_fixture jellyfin jellyfin seed
export PLATFORM_IMMICH_UPLOAD_ROOT="$PLATFORM_MAC_SANDBOX/legacy/immich/data/upload"
export PLATFORM_IMMICH_THUMBNAIL_ROOT="$PLATFORM_MAC_SANDBOX/legacy/immich/thumbs"
export PLATFORM_IMMICH_SERVER_CONTAINER="$PLATFORM_PROJECT_NAME-legacy-immich-immich-server-1"
export PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER="$PLATFORM_PROJECT_NAME-legacy-immich-immich-machine-learning-1"
export PLATFORM_IMMICH_REDIS_CONTAINER="$PLATFORM_PROJECT_NAME-legacy-immich-redis-1"
export PLATFORM_IMMICH_POSTGRES_CONTAINER="$PLATFORM_PROJECT_NAME-legacy-immich-database-1"
run_fixture immich immich-server seed
export PLATFORM_PAPERLESS_CONSUME_ROOT="$PLATFORM_MAC_SANDBOX/legacy/paperless-ngx/consume"
export PLATFORM_PAPERLESS_EXPORT_ROOT="$PLATFORM_MAC_SANDBOX/legacy/paperless-ngx/export"
export PLATFORM_PAPERLESS_WEBSERVER_CONTAINER="$PLATFORM_PROJECT_NAME-legacy-paperless-ngx-webserver-1"
run_fixture paperless-ngx webserver seed
