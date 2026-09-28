#!/bin/sh
set -eu
set +x
umask 077

# Coordinated Immich snapshot/rollback: PostgreSQL, originals and the profile and
# thumbnail trees move together or not at all. The Valkey queue is discarded on
# restore, since it holds work queued against the replaced database state.
mac_script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

usage() {
  printf '%s\n' \
    'usage: snapshot-immich.sh --self-test | snapshot DIR | restore DIR | drill DIR' >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
mode=$1
shift

if [ "$mode" = --self-test ]; then
  [ "$#" -eq 0 ] || usage
  exec "$mac_script_dir/snapshot-immich-test.rb" </dev/null
fi

case $mode in
  snapshot|restore|drill) ;;
  *) usage ;;
esac
[ "$#" -eq 1 ] || usage
snapshot_dir=$1

# The drill deletes every asset; refuse anywhere but a throwaway sandbox project.
if [ "$mode" = drill ]; then
  case ${PLATFORM_PROJECT_NAME:-} in
    nas-platform-mac-[abcdefghijklmnopqrstuvwxyz0123456789]*) ;;
    *)
      printf '%s\n' 'drill refuses to run outside a disposable Mac sandbox project' >&2
      exit 1
      ;;
  esac
fi

: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_FILE:?PLATFORM_MAC_VAULT_FILE is required}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:?PLATFORM_MAC_VAULT_PASSWORD_FILE is required}"
: "${PLATFORM_DOCKER_ROOT:?}"
: "${PLATFORM_MEDIA_ROOT:?}"
: "${PLATFORM_IMMICH_PORT:=2283}"
if [ -n "${PLATFORM_PROJECT_NAME:-}" ]; then
  : "${PLATFORM_IMMICH_SERVER_CONTAINER:=$PLATFORM_PROJECT_NAME-immich-server}"
  : "${PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER:=$PLATFORM_PROJECT_NAME-immich-machine-learning}"
  : "${PLATFORM_IMMICH_POSTGRES_CONTAINER:=$PLATFORM_PROJECT_NAME-immich-postgres}"
  : "${PLATFORM_IMMICH_REDIS_CONTAINER:=$PLATFORM_PROJECT_NAME-immich-redis}"
else
  : "${PLATFORM_IMMICH_SERVER_CONTAINER:=immich_server}"
  : "${PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER:=immich_machine_learning}"
  : "${PLATFORM_IMMICH_POSTGRES_CONTAINER:=immich_postgres}"
  : "${PLATFORM_IMMICH_REDIS_CONTAINER:=immich_redis}"
fi
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_DOCKER_ROOT PLATFORM_MEDIA_ROOT PLATFORM_IMMICH_PORT
export PLATFORM_IMMICH_SERVER_CONTAINER PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER
export PLATFORM_IMMICH_POSTGRES_CONTAINER PLATFORM_IMMICH_REDIS_CONTAINER

# Sibling programs resolve from this script's own directory; stdin held at EOF (#315).
exec "$mac_script_dir/snapshot-immich.rb" "$mode" "$snapshot_dir" </dev/null
