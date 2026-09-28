#!/bin/sh
set -eu
set +x
umask 077

# Sibling Ruby programs resolve from this script's own checkout (#147).
mac_script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)

usage() {
  printf '%s\n' \
    'usage: snapshot-paperless.sh --self-test | snapshot DIR | restore DIR | drill DIR' >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
mode=$1
shift

if [ "$mode" = --self-test ]; then
  [ "$#" -eq 0 ] || usage
  # Spelled repository-relative so classify_changes_test.rb's harness closure
  # reaches it and a change selects a suite; stdin held at EOF (#315).
  exec "$mac_repo_dir/tests/mac/snapshot-paperless-test.rb" </dev/null
fi

case $mode in
  snapshot|restore|drill) ;;
  *) usage ;;
esac
[ "$#" -eq 1 ] || usage
snapshot_dir=$1

if [ "$mode" = drill ]; then
  case ${PLATFORM_PROOF_PLATFORM:-mac}:${PLATFORM_PROOF_LANE:-fresh}:${PLATFORM_KIND:-}:${PLATFORM_PROJECT_NAME:-} in
    integration:fresh:integration:nas-platform-mac-[abcdefghijklmnopqrstuvwxyz0123456789]*)
      paperless_integration_drill=true
      ;;
    mac:fresh:integration:)
      paperless_integration_drill=false
      ;;
    mac:*:mac:nas-platform-mac-[abcdefghijklmnopqrstuvwxyz0123456789]*|\
    mac:*::nas-platform-mac-[abcdefghijklmnopqrstuvwxyz0123456789]*)
      paperless_integration_drill=false
      ;;
    *)
      printf '%s\n' 'drill refuses to run outside a disposable Mac or integration sandbox' >&2
      exit 1
      ;;
  esac
fi

: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_DOCKER_ROOT:?}"
: "${PLATFORM_MEDIA_ROOT:?}"
: "${PLATFORM_PAPERLESS_PORT:=8000}"
# Recovery's valkey wait; declared here so the regression test can shorten it.
# The Ruby side floors it.
: "${PLATFORM_PAPERLESS_RECOVERY_DEADLINE:=60}"
if [ "$mode" = drill ] && [ "${paperless_integration_drill:-false}" = true ]; then
  : "${PLATFORM_MAC_SANDBOX:?}"
  paperless_drill_root=$(CDPATH= cd -- "$PLATFORM_MAC_SANDBOX" && pwd -P)
  case $(basename -- "$paperless_drill_root") in nas-platform-mac.??????) ;; *) exit 1 ;; esac
  paperless_suffix=$(printf '%s' "${paperless_drill_root##*.}" | tr '[:upper:]' '[:lower:]')
  [ "$paperless_drill_root" = "$PLATFORM_MAC_SANDBOX" ] &&
    [ "$PLATFORM_DOCKER_ROOT" = "$paperless_drill_root/service-data/docker" ] &&
    [ "$PLATFORM_MEDIA_ROOT" = "$paperless_drill_root/service-data/media" ] || {
    printf '%s\n' 'integration drill roots differ from the owned Mac sandbox' >&2
    exit 1
  }
  marker=$paperless_drill_root/.nas-platform-mac-owned
  case $(uname -s) in
    Darwin)
      paperless_marker_uid=$(stat -f '%u' "$marker" 2>/dev/null || true)
      paperless_marker_mode=$(stat -f '%Lp' "$marker" 2>/dev/null || true)
      ;;
    *)
      paperless_marker_uid=$(stat -c '%u' "$marker" 2>/dev/null || true)
      paperless_marker_mode=$(stat -c '%a' "$marker" 2>/dev/null || true)
      ;;
  esac
  [ -f "$marker" ] && [ ! -L "$marker" ] &&
    [ "$paperless_marker_uid" = "$(id -u)" ] && [ "$paperless_marker_mode" = 600 ] &&
    [ "$(sed -n 's/^project=//p' "$marker")" = "$PLATFORM_PROJECT_NAME" ] &&
    [ "$PLATFORM_PROJECT_NAME" = "nas-platform-mac-$paperless_suffix" ] &&
    grep -qx schema=1 "$marker" &&
    [ "$(wc -l < "$marker" | tr -d ' ')" -eq 2 ] || {
    printf '%s\n' 'integration adoption drill project is not owned' >&2
    exit 1
  }
elif [ "$mode" = drill ] && [ "${PLATFORM_KIND:-}" = integration ]; then
  paperless_drill_root=$(CDPATH= cd -- "$PLATFORM_DOCKER_ROOT/../.." && pwd -P)
  paperless_media_parent=$(CDPATH= cd -- "$PLATFORM_MEDIA_ROOT/.." && pwd -P)
  case $(basename -- "$paperless_drill_root") in
    nas-platform-integration.*) ;;
    *)
      printf '%s\n' 'integration drill root is not disposable' >&2
      exit 1
      ;;
  esac
  [ "$paperless_drill_root" = "$paperless_media_parent" ] || {
    printf '%s\n' 'integration drill roots do not share one sandbox' >&2
    exit 1
  }
fi
# Both disposable lanes resolve one namespaced container identity.
if [ -n "${PLATFORM_PROJECT_NAME:-}" ]; then
  : "${PLATFORM_PAPERLESS_WEBSERVER_CONTAINER:=$PLATFORM_PROJECT_NAME-paperless-webserver}"
  : "${PLATFORM_PAPERLESS_POSTGRES_CONTAINER:=$PLATFORM_PROJECT_NAME-paperless-postgres}"
  : "${PLATFORM_PAPERLESS_REDIS_CONTAINER:=$PLATFORM_PROJECT_NAME-paperless-redis}"
else
  : "${PLATFORM_PAPERLESS_WEBSERVER_CONTAINER:=paperless_webserver}"
  : "${PLATFORM_PAPERLESS_POSTGRES_CONTAINER:=paperless_postgres}"
  : "${PLATFORM_PAPERLESS_REDIS_CONTAINER:=paperless_redis}"
fi
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_DOCKER_ROOT PLATFORM_MEDIA_ROOT PLATFORM_PAPERLESS_PORT
export PLATFORM_PAPERLESS_RECOVERY_DEADLINE
export PLATFORM_PAPERLESS_WEBSERVER_CONTAINER PLATFORM_PAPERLESS_POSTGRES_CONTAINER
export PLATFORM_PAPERLESS_REDIS_CONTAINER

exec "$mac_repo_dir/tests/mac/snapshot-paperless.rb" "$mode" "$snapshot_dir" </dev/null
