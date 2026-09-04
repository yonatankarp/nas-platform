#!/bin/sh
set -eu
set +x
umask 077

# Coordinated snapshot and rollback for Immich. Immich keeps one application
# state in several places that must move together: PostgreSQL rows, the original
# files under the media root, and the profile and thumbnail trees under the
# Docker root. Backing up any one of them alone produces a restore that starts
# and then serves broken thumbnails or missing originals, so every operation
# here takes all of them or none.
#
# The Valkey job queue is the fourth participant and is handled differently: it
# is discarded on restore rather than captured, because it holds work queued
# against a database state the restore has just replaced.
#
# The two Ruby programs this dispatches to are siblings of this file, so they
# are resolved from this script's own directory. Nothing here inspects another
# checkout, but the rule is the same one #147 measured: a program is part of the
# script, not part of whatever tree the script was pointed at.
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

# The drill deletes every asset in the deployment and recovers only if the
# restore works. That is an acceptable thing to do to a disposable lane sandbox
# and an unacceptable thing to do to a NAS, so it refuses up front, before it
# reads a credential or touches a container, anywhere that is not one of the
# harness's own throwaway projects.
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

# The 305-line coordinated snapshot is snapshot-immich.rb, and the offline
# self-test above is snapshot-immich-test.rb. Both ran from `<<'RUBY'`
# heredocs here until #315, where sh -n, ruby -c and a reader could reach
# neither. Resolve them from this script's own directory rather than from any
# path an argument or the environment supplies, and hold stdin at end-of-file:
# a heredoc exhausted it by construction, a sibling program would inherit the
# caller's.
exec "$mac_script_dir/snapshot-immich.rb" "$mode" "$snapshot_dir" </dev/null
