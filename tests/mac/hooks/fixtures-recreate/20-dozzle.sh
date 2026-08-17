#!/bin/sh
set -eu

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"
current=$PLATFORM_DOCKER_ROOT/nas-platform/current/services/dozzle
runtime=$PLATFORM_DOCKER_ROOT/nas-platform/runtime/services/dozzle/.env

set -- docker compose --project-name "$PLATFORM_PROJECT_NAME-dozzle" --env-file "$runtime"
compose_arguments=$(mac_compose_files "$current")
while IFS= read -r compose_argument; do set -- "$@" "$compose_argument"; done <<EOF
$compose_arguments
EOF
"$@" up -d --force-recreate --wait alert-relay dozzle socket-proxy
"$mac_hook_dir/../../run-dozzle-contract.sh" verify
