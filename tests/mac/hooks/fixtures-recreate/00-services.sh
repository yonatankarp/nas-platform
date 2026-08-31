#!/bin/sh
# Container recreation for every deployed service, in the order the eight
# NN-service.sh hooks this replaces ran in. Each of those hooks was the same
# fifteen lines: force-recreate the service's containers from the deployed
# Compose bundle, then reassert the service's contract against the fresh
# containers. Only the bundle directory, the Compose project suffix, the Compose
# service names and the reassertion phase differed, so those four are the table.
set -eu
set +x
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

mac_recreated=

# service, deployed bundle directory, Compose project suffix, Compose service
# names, and the contract phase that reasserts the service afterwards.
mac_recreate_and_reassert() {
  mac_recreate_service=$1
  mac_recreate_directory=$2
  mac_recreate_project=$3
  mac_recreate_targets=$4
  mac_recreate_phase=$5
  mac_recreate_current=$PLATFORM_DOCKER_ROOT/nas-platform/current/services/$mac_recreate_directory
  mac_recreate_runtime=$PLATFORM_DOCKER_ROOT/nas-platform/runtime/services/$mac_recreate_directory/.env

  set -- docker compose \
    --project-name "${PLATFORM_PROJECT_NAME:?PLATFORM_PROJECT_NAME is required}-$mac_recreate_project" \
    --env-file "$mac_recreate_runtime"
  mac_recreate_compose_arguments=$(mac_compose_files "$mac_recreate_current")
  while IFS= read -r mac_recreate_compose_argument; do
    set -- "$@" "$mac_recreate_compose_argument"
  done <<EOF
$mac_recreate_compose_arguments
EOF
  set -- "$@" up -d --force-recreate --wait
  for mac_recreate_target in $mac_recreate_targets; do
    set -- "$@" "$mac_recreate_target"
  done
  "$@"

  if [ -n "$mac_recreate_phase" ]; then
    "$mac_script_dir/run-contract.sh" "$mac_recreate_service" "$mac_recreate_phase"
  else
    # ntfy is the one recreated service with no contract suite of its own, so its
    # verify hook is the reassertion, exactly as 15-ntfy.sh did.
    "$mac_hook_dir/../verify/15-ntfy.sh"
  fi
  mac_recreated="$mac_recreated$mac_recreate_service
"
}

mac_recreate_and_reassert beszel beszel beszel 'hub agent-portable socket-proxy' verify
mac_recreate_and_reassert ntfy ntfy ntfy ntfy ''
mac_recreate_and_reassert dozzle dozzle dozzle 'alert-relay dozzle socket-proxy' verify
mac_recreate_and_reassert audiobookshelf audiobookshelf audiobookshelf audiobookshelf run
mac_recreate_and_reassert komga komga komga komga run
mac_recreate_and_reassert jellyfin jellyfin jellyfin jellyfin run
mac_recreate_and_reassert immich immich immich \
  'immich-server immich-machine-learning redis database' run
mac_recreate_and_reassert paperless paperless-ngx paperless \
  'broker db webserver gotenberg tika' run
mac_recreate_and_reassert pinchflat pinchflat pinchflat pinchflat run
mac_recreate_and_reassert kapowarr kapowarr kapowarr kapowarr run
mac_recreate_and_reassert bindery bindery bindery bindery run

mac_assert_service_coverage fixtures-recreate 00-services.sh "$mac_recreated" \
  'arr=its Phase 1 runtime is default-disabled in the Mac lane and proved by its Docker integration suite
downloaders=its Phase 1 runtime is default-disabled in the Mac lane and proved by its Docker integration suite'
