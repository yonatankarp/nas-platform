#!/bin/sh
set -eu

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
current=$PLATFORM_DOCKER_ROOT/nas-platform/current/services/dozzle
runtime=$PLATFORM_DOCKER_ROOT/nas-platform/runtime/services/dozzle/.env

set -- docker compose --project-name "$PLATFORM_PROJECT_NAME-dozzle" \
  --env-file "$runtime" -f "$current/compose.yml" -f "$current/compose.mac.yml"
[ "$PLATFORM_PROOF_LANE" != adoption ] || set -- "$@" -f "$current/compose.adoption.yml"
"$@" up -d --force-recreate --wait
"$mac_hook_dir/../../run-dozzle-contract.sh" verify
