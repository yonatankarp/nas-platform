#!/bin/sh
set -eu

mac_test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$mac_test_dir/../.." && pwd -P)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-config-isolation.XXXXXX")
trap 'rm -f -- "$temporary_dir"/*.json; rmdir -- "$temporary_dir"' EXIT HUP INT TERM
export PLATFORM_CONTAINER_CPUSET=0-2

render() {
  label=$1
  base_name=$2
  beszel_port=$3
  ntfy_port=$4
  dozzle_port=$5
  audiobookshelf_port=$6
  komga_port=$7
  jellyfin_port=$8
  immich_port=$9
  paperless_port=${10}
  radarr_port=${11}
  sonarr_port=${12}
  prowlarr_port=${13}
  bazarr_port=${14}
  sabnzbd_port=${15}
  pinchflat_port=${16}
  kapowarr_port=${17}
  bindery_port=${18}
  trailarr_port=${19}
  seerr_port=${20}

  env PLATFORM_PROJECT_NAME="$base_name" BESZEL_HOST_PORT="$beszel_port" \
    NAS_DOCKER_ROOT="$temporary_dir/$label" NAS_MEDIA_ROOT="$temporary_dir/$label-media" \
    NAS_RENDER_DEVICE=/dev/null BESZEL_APP_URL="http://127.0.0.1:$beszel_port" \
    BESZEL_SYSTEM_NAME=test BESZEL_AGENT_KEY=test BESZEL_AGENT_TOKEN=test TZ=UTC \
    docker compose --project-name "$base_name-beszel" \
      -f "$repo_dir/services/beszel/compose.yml" \
      -f "$repo_dir/services/beszel/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-beszel.json"

  env PLATFORM_PROJECT_NAME="$base_name" NTFY_HOST_PORT="$ntfy_port" \
    NAS_DOCKER_ROOT="$temporary_dir/$label" NAS_UID=1000 NAS_GID=100 \
    NTFY_BASE_URL="http://127.0.0.1:$ntfy_port" NTFY_AUTH_USERS= \
    NTFY_AUTH_ACCESS= NTFY_AUTH_TOKENS= TZ=UTC \
    docker compose --project-name "$base_name-ntfy" \
      -f "$repo_dir/services/ntfy/compose.yml" \
      -f "$repo_dir/services/ntfy/compose.mac.yml" config --format json \
    > "$temporary_dir/$label-ntfy.json"

  env PLATFORM_PROJECT_NAME="$base_name" DOZZLE_HOST_PORT="$dozzle_port" \
    NAS_DOCKER_ROOT="$temporary_dir/$label" NAS_UID=1000 NAS_GID=100 TZ=UTC \
    PLATFORM_CURRENT_DIR="$repo_dir" DOZZLE_STATE_ROOT="$temporary_dir/$label/dozzle/data" \
    ALERT_RELAY_SCRIPT_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    ALERT_RELAY_TOKEN=test-relay-token ALERT_RELAY_PORT=8081 \
    NTFY_PUBLISH_URL="http://127.0.0.1:$ntfy_port/" \
    NTFY_TOPIC=nas-critical NTFY_CONTAINERS_TOPIC=nas-containers NTFY_TOKEN=test-ntfy-token \
    docker compose --project-name "$base_name-dozzle" \
      -f "$repo_dir/services/dozzle/compose.yml" \
      -f "$repo_dir/services/dozzle/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-dozzle.json"

  env PLATFORM_PROJECT_NAME="$base_name" AUDIOBOOKSHELF_HOST_PORT="$audiobookshelf_port" \
    PLATFORM_MEDIA_NETWORK="$base_name-media-control" NAS_UID=1000 NAS_GID=100 \
    PLATFORM_DOCKER_ROOT="$temporary_dir/$label" \
    AUDIOBOOKSHELF_CONFIG_PATH="$temporary_dir/$label-audiobookshelf-config" \
    AUDIOBOOKSHELF_METADATA_PATH="$temporary_dir/$label-audiobookshelf-metadata" \
    AUDIOBOOKSHELF_MEDIA_PATH="$temporary_dir/$label-audiobooks" \
    AUDIOBOOKSHELF_BACKUP_PATH="$temporary_dir/$label/audiobookshelf/backups" TZ=UTC \
    docker compose --project-name "$base_name-audiobookshelf" \
      -f "$repo_dir/services/audiobookshelf/compose.yml" \
      -f "$repo_dir/services/audiobookshelf/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-audiobookshelf.json"

  env PLATFORM_PROJECT_NAME="$base_name" KOMGA_HOST_PORT="$komga_port" \
    NAS_UID=1000 NAS_GID=100 \
    KOMGA_CONFIG_PATH="$temporary_dir/$label-komga-config" \
    KOMGA_LIBRARY_PATH="$temporary_dir/$label-books" TZ=UTC \
    docker compose --project-name "$base_name-komga" \
      -f "$repo_dir/services/komga/compose.yml" \
      -f "$repo_dir/services/komga/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-komga.json"

  env PLATFORM_PROJECT_NAME="$base_name" JELLYFIN_HOST_PORT="$jellyfin_port" \
    PLATFORM_MEDIA_NETWORK="$base_name-media-control" NAS_UID=1000 NAS_GID=100 \
    JELLYFIN_CONFIG_PATH="$temporary_dir/$label-jellyfin-config" \
    JELLYFIN_CACHE_PATH="$temporary_dir/$label-jellyfin-cache" \
    JELLYFIN_MEDIA_PATH="$temporary_dir/$label-media" TZ=UTC \
    docker compose --project-name "$base_name-jellyfin" \
      -f "$repo_dir/services/jellyfin/compose.yml" \
      -f "$repo_dir/services/jellyfin/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-jellyfin.json"

  env PLATFORM_PROJECT_NAME="$base_name" IMMICH_HOST_PORT="$immich_port" \
    NAS_DOCKER_ROOT="$temporary_dir/$label" NAS_MEDIA_ROOT="$temporary_dir/$label-media" \
    IMMICH_DB_NAME=test IMMICH_DB_USERNAME=test IMMICH_DB_PASSWORD=test TZ=UTC \
    docker compose --project-name "$base_name-immich" \
      -f "$repo_dir/services/immich/compose.yml" \
      -f "$repo_dir/services/immich/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-immich.json"

  env PLATFORM_PROJECT_NAME="$base_name" PAPERLESS_HOST_PORT="$paperless_port" \
    PAPERLESS_POSTGRES_PATH="$temporary_dir/$label-paperless-postgres" \
    PAPERLESS_REDIS_PATH="$temporary_dir/$label-paperless-redis" \
    PAPERLESS_DATA_PATH="$temporary_dir/$label-paperless-data" \
    PAPERLESS_CACHE_PATH="$temporary_dir/$label-paperless-cache" \
    PAPERLESS_TESSDATA_PATH="$temporary_dir/$label-paperless-tessdata" \
    PAPERLESS_MEDIA_PATH="$temporary_dir/$label-paperless-media" \
    PAPERLESS_CONSUME_PATH="$temporary_dir/$label-paperless-consume" \
    PAPERLESS_EXPORT_PATH="$temporary_dir/$label-paperless-export" \
    PAPERLESS_ADMIN_USER=test PAPERLESS_ADMIN_PASSWORD=test PAPERLESS_ADMIN_MAIL=test@example.invalid \
    PAPERLESS_DBHOST=db PAPERLESS_REDIS=redis://broker:6379 \
    PAPERLESS_TIKA_ENDPOINT=http://tika:9998 PAPERLESS_GOTENBERG_ENDPOINT=http://gotenberg:3000 \
    PAPERLESS_AI_ENABLED=false PAPERLESS_AI_LLM_ENDPOINT=http://example.invalid:11434 \
    PAPERLESS_AI_LLM_MODEL=test-model \
    PAPERLESS_SECRET_KEY=test DB_NAME=test DB_USER=test DB_PASSWORD=test \
    USER_ID=1000 GROUP_ID=100 TZ=UTC \
    docker compose --project-name "$base_name-paperless" \
      -f "$repo_dir/services/paperless-ngx/compose.yml" \
      -f "$repo_dir/services/paperless-ngx/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-paperless.json"

  env PLATFORM_PROJECT_NAME="$base_name" PLATFORM_MEDIA_NETWORK="$base_name-media-control" \
    PLATFORM_CONTAINER_CPUSET=0-2 NAS_UID=1000 NAS_GID=100 TZ=UTC \
    MEDIA_ROOT="$temporary_dir/$label-media" \
    RADARR_CONFIG_PATH="$temporary_dir/$label-radarr-config" RADARR_HOST_PORT="$radarr_port" \
    SONARR_CONFIG_PATH="$temporary_dir/$label-sonarr-config" SONARR_HOST_PORT="$sonarr_port" \
    PROWLARR_CONFIG_PATH="$temporary_dir/$label-prowlarr-config" PROWLARR_HOST_PORT="$prowlarr_port" \
    BAZARR_CONFIG_PATH="$temporary_dir/$label-bazarr-config" BAZARR_HOST_PORT="$bazarr_port" \
    CONFIGARR_CONFIG_PATH="$temporary_dir/$label-configarr.yml" \
    CONFIGARR_SECRETS_PATH="$temporary_dir/$label-configarr-secrets.yml" \
    CONFIGARR_REPOS_PATH="$temporary_dir/$label-configarr-repos" \
    docker compose --project-name "$base_name-arr" \
      -f "$repo_dir/services/arr/compose.yml" \
      -f "$repo_dir/services/arr/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-arr.json"

  env PLATFORM_PROJECT_NAME="$base_name" PLATFORM_MEDIA_NETWORK="$base_name-media-control" \
    PLATFORM_CONTAINER_CPUSET=0-2 NAS_UID=1000 NAS_GID=100 TZ=UTC \
    SABNZBD_CONFIG_PATH="$temporary_dir/$label-sabnzbd-config" \
    MEDIA_ACQUISITION_PATH="$temporary_dir/$label-media/Media/.acquisition" \
    BOOKS_ACQUISITION_PATH="$temporary_dir/$label-media/Books/.acquisition" \
    SABNZBD_HOST_PORT="$sabnzbd_port" SABNZBD_API_KEY=test \
    RADARR_API_KEY=test SONARR_API_KEY=test \
    docker compose --project-name "$base_name-downloaders" \
      -f "$repo_dir/services/downloaders/compose.yml" \
      -f "$repo_dir/services/downloaders/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-downloaders.json"

  env PLATFORM_PROJECT_NAME="$base_name" PLATFORM_CONTAINER_CPUSET=0-2 \
    NAS_UID=1000 NAS_GID=100 TZ=UTC \
    PINCHFLAT_CONFIG_PATH="$temporary_dir/$label-pinchflat-config" \
    PINCHFLAT_DOWNLOADS_PATH="$temporary_dir/$label-media/Media/YouTube" \
    PINCHFLAT_YTDLP_PATH="$temporary_dir/$label-pinchflat-bin/yt-dlp" \
    PINCHFLAT_HOST_PORT="$pinchflat_port" \
    PINCHFLAT_BASIC_AUTH_USERNAME=test PINCHFLAT_BASIC_AUTH_PASSWORD=test \
    docker compose --project-name "$base_name-pinchflat" \
      -f "$repo_dir/services/pinchflat/compose.yml" \
      -f "$repo_dir/services/pinchflat/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-pinchflat.json"

  env PLATFORM_PROJECT_NAME="$base_name" PLATFORM_CONTAINER_CPUSET=0-2 \
    NAS_UID=1000 NAS_GID=100 TZ=UTC \
    KAPOWARR_CONFIG_PATH="$temporary_dir/$label-kapowarr-config" \
    KAPOWARR_BOOKS_PATH="$temporary_dir/$label-media/Books" \
    KAPOWARR_HOST_PORT="$kapowarr_port" \
    docker compose --project-name "$base_name-kapowarr" \
      -f "$repo_dir/services/kapowarr/compose.yml" \
      -f "$repo_dir/services/kapowarr/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-kapowarr.json"

  env PLATFORM_PROJECT_NAME="$base_name" PLATFORM_CONTAINER_CPUSET=0-2 \
    PLATFORM_MEDIA_NETWORK="$base_name-media-control" \
    NAS_UID=1000 NAS_GID=100 TZ=UTC \
    BINDERY_API_KEY=00000000000000000000000000000000 \
    BINDERY_CONFIG_PATH="$temporary_dir/$label-bindery-config" \
    BINDERY_BOOKS_PATH="$temporary_dir/$label-media/Books" \
    BINDERY_MEDIA_PATH="$temporary_dir/$label-media/Media" \
    BINDERY_HOST_PORT="$bindery_port" \
    docker compose --project-name "$base_name-bindery" \
      -f "$repo_dir/services/bindery/compose.yml" \
      -f "$repo_dir/services/bindery/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-bindery.json"

  env PLATFORM_PROJECT_NAME="$base_name" PLATFORM_CONTAINER_CPUSET=0-2 \
    PLATFORM_MEDIA_NETWORK="$base_name-media-control" \
    NAS_UID=1000 NAS_GID=100 TZ=UTC \
    TRAILARR_API_KEY=00000000000000000000000000000000 \
    TRAILARR_WEBUI_USERNAME=isolation \
    TRAILARR_WEBUI_PASSWORD_HASH='$2b$12$00000000000000000000000000000000000000000000000000000' \
    TRAILARR_MONITOR_ENABLED=False \
    TRAILARR_DOWNLOADS_ENABLED=False \
    TRAILARR_CONFIG_PATH="$temporary_dir/$label-trailarr-config" \
    TRAILARR_MOVIES_PATH="$temporary_dir/$label-media/Media/Movies" \
    TRAILARR_SERIES_PATH="$temporary_dir/$label-media/Media/Series" \
    TRAILARR_HOST_PORT="$trailarr_port" \
    docker compose --project-name "$base_name-trailarr" \
      -f "$repo_dir/services/trailarr/compose.yml" \
      -f "$repo_dir/services/trailarr/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-trailarr.json"

  env PLATFORM_PROJECT_NAME="$base_name" PLATFORM_CONTAINER_CPUSET=0-2 \
    PLATFORM_MEDIA_NETWORK="$base_name-media-control" \
    NAS_UID=1000 NAS_GID=100 TZ=UTC \
    SEERR_API_KEY=00000000000000000000000000000000 \
    SEERR_CONFIG_PATH="$temporary_dir/$label-seerr-config" \
    SEERR_HOST_PORT="$seerr_port" \
    docker compose --project-name "$base_name-seerr" \
      -f "$repo_dir/services/seerr/compose.yml" \
      -f "$repo_dir/services/seerr/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-seerr.json"
}

render first nas-platform-mac-first 38090 32586 38080 33378 35600 38096 32283 38000 \
  37878 38989 36969 36767 38082 38945 35656 38787 37889 35055
render second nas-platform-mac-second 38091 32587 38081 33379 35601 38097 32284 38001 \
  37879 38990 36970 36768 38083 38946 35657 38788 37890 35056

# The 219 lines of assertions that used to follow as a `<<'RUBY'` heredoc are
# config-isolation.rb, where sh -n, ruby -c and a reader can all reach them.
# Resolve it from this script's own directory, not from $repo_dir: the two are
# the same tree today, but $repo_dir is what this script renders Compose files
# out of, and a program is part of the script rather than part of the tree it
# inspects. stdin stays at end-of-file because the heredoc exhausted it.
"$mac_test_dir/config-isolation.rb" "$temporary_dir" </dev/null
