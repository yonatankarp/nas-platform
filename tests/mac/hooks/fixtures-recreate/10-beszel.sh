#!/bin/sh
set -eu

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"
current=$PLATFORM_DOCKER_ROOT/nas-platform/current/services/beszel
runtime=$PLATFORM_DOCKER_ROOT/nas-platform/runtime/services/beszel/.env

set -- docker compose --project-name "$PLATFORM_PROJECT_NAME-beszel" --env-file "$runtime"
compose_arguments=$(mac_compose_files "$current")
while IFS= read -r compose_argument; do set -- "$@" "$compose_argument"; done <<EOF
$compose_arguments
EOF
"$@" up -d --force-recreate --wait hub agent-portable socket-proxy
"$mac_hook_dir/../../run-beszel-contract.sh" verify
