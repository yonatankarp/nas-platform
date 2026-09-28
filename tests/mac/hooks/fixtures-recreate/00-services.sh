#!/bin/sh
# Recreate every deployed service from the deployed bundle, then reassert its contract.
set -eu
set +x
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

mac_recreated=

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

  # Every recreated row names its phase: run-contract.sh refuses an empty one,
  # so a row without a contract to reassert with cannot pass in silence.
  "$mac_script_dir/run-contract.sh" "$mac_recreate_service" "$mac_recreate_phase"
  mac_recreated="$mac_recreated$mac_recreate_service
"
}

mac_recreate_and_reassert beszel beszel beszel 'hub agent-portable socket-proxy' verify
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
mac_recreate_and_reassert trailarr trailarr trailarr trailarr run
mac_recreate_and_reassert seerr seerr seerr seerr run
# Whole stacks, so the claim covers data outliving containers. Nextcloud's census
# notices an empty /var/www/html through both health probes; backgroundjobs_mode
# would not, since it lives in Postgres on a separate volume.
mac_recreate_and_reassert nextcloud nextcloud nextcloud 'nextcloud cron db cache' run

mac_assert_service_coverage fixtures-recreate 00-services.sh "$mac_recreated" \
  'arr=its Phase 1 runtime is default-disabled in the Mac lane and proved by its Docker integration suite
downloaders=its Phase 1 runtime is default-disabled in the Mac lane and proved by its Docker integration suite
vaultwarden=it has no contract suite of its own to reassert after a recreate; its store is a single SQLite database on one bind mount and the verification play is what reads the server back
karakeep=it has no contract suite of its own to reassert after a recreate; its administrator lives in db.db on one bind mount and the verification play is what signs back in as it'
