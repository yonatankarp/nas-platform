#!/bin/sh
set -eu
set +x

mac_script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_repo_dir/tests/contracts/legacy-fixture-paths.sh"
legacy_fixture_unset_controls

: "${PLATFORM_MAC_VAULT_FILE:?PLATFORM_MAC_VAULT_FILE is required}"
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?PLATFORM_MAC_VAULT_PASSWORD_FILE is required}"
: "${PLATFORM_DOCKER_ROOT:?PLATFORM_DOCKER_ROOT is required}"
: "${PLATFORM_MEDIA_ROOT:?PLATFORM_MEDIA_ROOT is required}"
: "${PLATFORM_REPORT_ROOT:?PLATFORM_REPORT_ROOT is required}"
: "${PLATFORM_PROJECT_NAME:?PLATFORM_PROJECT_NAME is required}"
: "${PLATFORM_JELLYFIN_PORT:?PLATFORM_JELLYFIN_PORT is required}"
case ${PLATFORM_PROOF_PLATFORM:-mac} in
  integration) PLATFORM_JELLYFIN_CONTAINER=jellyfin ;;
  mac) PLATFORM_JELLYFIN_CONTAINER=$PLATFORM_PROJECT_NAME-jellyfin ;;
  *) exit 1 ;;
esac
export PLATFORM_JELLYFIN_CONTAINER

PLATFORM_CONTRACT_VAULT_FILE=$PLATFORM_MAC_VAULT_FILE \
PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=$PLATFORM_MAC_VAULT_PASSWORD_FILE \
  exec "$mac_repo_dir/tests/contracts/jellyfin.sh" --platform mac "$@"
