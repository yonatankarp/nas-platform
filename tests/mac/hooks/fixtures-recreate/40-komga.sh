#!/bin/sh
set -eu

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
current=$PLATFORM_DOCKER_ROOT/nas-platform/current/services/komga
runtime=$PLATFORM_DOCKER_ROOT/nas-platform/runtime/services/komga/.env

docker compose --project-name "$PLATFORM_PROJECT_NAME-komga" \
  --env-file "$runtime" -f "$current/compose.yml" -f "$current/compose.mac.yml" \
  up -d --force-recreate --wait
"$mac_hook_dir/../../run-komga-contract.sh" run
