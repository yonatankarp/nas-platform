#!/bin/sh
set -eu
set +x

mac_script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_repo_dir/tests/contracts/legacy-fixture-paths.sh"
legacy_fixture_unset_controls

: "${PLATFORM_MAC_VAULT_FILE:?PLATFORM_MAC_VAULT_FILE is required}"
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?PLATFORM_MAC_VAULT_PASSWORD_FILE is required}"
: "${PLATFORM_MEDIA_ROOT:?PLATFORM_MEDIA_ROOT is required}"
: "${PLATFORM_REPORT_ROOT:?PLATFORM_REPORT_ROOT is required}"
: "${PLATFORM_PROJECT_NAME:?PLATFORM_PROJECT_NAME is required}"
: "${PLATFORM_PAPERLESS_PORT:?PLATFORM_PAPERLESS_PORT is required}"

PLATFORM_CONTRACT_VAULT_FILE=$PLATFORM_MAC_VAULT_FILE
PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=$PLATFORM_MAC_VAULT_PASSWORD_FILE
PLATFORM_PAPERLESS_WEBSERVER_CONTAINER=$PLATFORM_PROJECT_NAME-paperless-webserver
export PLATFORM_PAPERLESS_WEBSERVER_CONTAINER
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
exec "$mac_repo_dir/tests/contracts/paperless.sh" "$@"
