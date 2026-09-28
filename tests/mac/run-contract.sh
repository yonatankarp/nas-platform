#!/bin/sh
# One Mac wrapper for every contract suite. The registry resolves the service to its
# contract; the per-service Mac environment lives in the table at the bottom.
set -eu
set +x
# Suites write vault-derived files under PLATFORM_REPORT_ROOT; the drift hooks assert 0600.
umask 077

mac_script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

[ "$#" -ge 2 ] || mac_die 'usage: run-contract.sh SERVICE PHASE [ARGUMENT...]'
mac_service=$1
mac_phase=$2
shift 2

# A missing phase is refused rather than defaulted; each contract refuses unknown modes.
case $mac_phase in
  *[!abcdefghijklmnopqrstuvwxyz0123456789-]*|-*|*-)
    mac_die "Mac contract phase is invalid: $mac_phase"
    ;;
esac

# An unknown service is refused before any environment is touched.
mac_contract_path=$(mac_registry_contract_path "$mac_service")

# tests/mac/run.sh exports all of these; tests/policy_mac_test.rb pins that it does.
: "${PLATFORM_MAC_VAULT_FILE:?PLATFORM_MAC_VAULT_FILE is required}"
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?PLATFORM_MAC_VAULT_PASSWORD_FILE is required}"
: "${PLATFORM_DOCKER_ROOT:?PLATFORM_DOCKER_ROOT is required}"
: "${PLATFORM_MEDIA_ROOT:?PLATFORM_MEDIA_ROOT is required}"
: "${PLATFORM_FIXTURE_ROOT:?PLATFORM_FIXTURE_ROOT is required}"
: "${PLATFORM_REPORT_ROOT:?PLATFORM_REPORT_ROOT is required}"
: "${PLATFORM_PROJECT_NAME:?PLATFORM_PROJECT_NAME is required}"

# Default rather than pin: run.sh exports the lane's kind (Komga reads it), and the
# Beszel contract's own default of nas would demand GPU telemetry no Mac has.
: "${PLATFORM_KIND:=mac}"
export PLATFORM_KIND

PLATFORM_CONTRACT_VAULT_FILE=$PLATFORM_MAC_VAULT_FILE
PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=$PLATFORM_MAC_VAULT_PASSWORD_FILE
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE

set -- "$mac_phase" "$@"

# Per-service environment. A registered service with no arm is refused here;
# tests/policy_mac_test.rb also holds the arms to the registry both ways.
case $mac_service in
  audiobookshelf)
    : "${PLATFORM_AUDIOBOOKSHELF_PORT:?PLATFORM_AUDIOBOOKSHELF_PORT is required}"
    ;;
  beszel)
    : "${PLATFORM_BESZEL_PORT:?PLATFORM_BESZEL_PORT is required}"
    ;;
  dozzle)
    : "${PLATFORM_DOZZLE_PORT:?PLATFORM_DOZZLE_PORT is required}"
    ;;
  immich)
    : "${PLATFORM_IMMICH_PORT:?PLATFORM_IMMICH_PORT is required}"
    PLATFORM_IMMICH_SERVER_CONTAINER=$(mac_container_name immich-server)
    PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER=$(mac_container_name immich-machine-learning)
    PLATFORM_IMMICH_REDIS_CONTAINER=$(mac_container_name immich-redis)
    PLATFORM_IMMICH_POSTGRES_CONTAINER=$(mac_container_name immich-postgres)
    export PLATFORM_IMMICH_SERVER_CONTAINER PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER
    export PLATFORM_IMMICH_REDIS_CONTAINER PLATFORM_IMMICH_POSTGRES_CONTAINER
    # Both lanes converge with platform_kind=mac, so pass the option unconditionally.
    set -- --platform mac "$@"
    ;;
  jellyfin)
    : "${PLATFORM_JELLYFIN_PORT:?PLATFORM_JELLYFIN_PORT is required}"
    PLATFORM_JELLYFIN_CONTAINER=$(mac_container_name jellyfin)
    export PLATFORM_JELLYFIN_CONTAINER
    set -- --platform mac "$@"
    ;;
  komga)
    : "${PLATFORM_KOMGA_PORT:?PLATFORM_KOMGA_PORT is required}"
    # The integration lane runs Komga's base image, the Mac lane the managed one.
    if [ "${PLATFORM_KIND:-}" = integration ]; then
      PLATFORM_KOMGA_RUNTIME_CONTEXT=base
    else
      PLATFORM_KOMGA_RUNTIME_CONTEXT=mac-managed
    fi
    export PLATFORM_KOMGA_RUNTIME_CONTEXT
    ;;
  paperless)
    : "${PLATFORM_PAPERLESS_PORT:?PLATFORM_PAPERLESS_PORT is required}"
    PLATFORM_PAPERLESS_WEBSERVER_CONTAINER=$(mac_container_name paperless-webserver)
    export PLATFORM_PAPERLESS_WEBSERVER_CONTAINER
    ;;
  bindery)
    : "${PLATFORM_BINDERY_PORT:?PLATFORM_BINDERY_PORT is required}"
    ;;
  trailarr)
    : "${PLATFORM_TRAILARR_PORT:?PLATFORM_TRAILARR_PORT is required}"
    ;;
  seerr)
    : "${PLATFORM_SEERR_PORT:?PLATFORM_SEERR_PORT is required}"
    # mac_ansible_playbook blanks Seerr's Pushover pair (tests/seerr_contract_test.rb).
    PLATFORM_SEERR_PUSHOVER_BLANKED=true
    export PLATFORM_SEERR_PUSHOVER_BLANKED
    ;;
  kapowarr)
    : "${PLATFORM_KAPOWARR_PORT:?PLATFORM_KAPOWARR_PORT is required}"
    ;;
  pinchflat)
    : "${PLATFORM_PINCHFLAT_PORT:?PLATFORM_PINCHFLAT_PORT is required}"
    ;;
  # Nextcloud derives all four container names from PLATFORM_PROJECT_NAME itself.
  nextcloud)
    : "${PLATFORM_NEXTCLOUD_PORT:?PLATFORM_NEXTCLOUD_PORT is required}"
    ;;
  *) mac_die "registered service has no Mac contract environment: $mac_service" ;;
esac

exec "$mac_repo_dir/$mac_contract_path" "$@"
