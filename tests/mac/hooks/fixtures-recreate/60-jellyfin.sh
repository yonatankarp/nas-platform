#!/bin/sh
set -eu

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
current=$PLATFORM_DOCKER_ROOT/nas-platform/current/services/jellyfin
runtime=$PLATFORM_DOCKER_ROOT/nas-platform/runtime/services/jellyfin/.env

docker compose --project-name "$PLATFORM_PROJECT_NAME-jellyfin" \
  --env-file "$runtime" -f "$current/compose.yml" -f "$current/compose.mac.yml" \
  up -d --force-recreate --wait
"$mac_hook_dir/../../run-jellyfin-contract.sh" run
