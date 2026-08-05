#!/bin/sh
set -eu
set +x

mac_script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)

: "${PLATFORM_MAC_VAULT_FILE:?}"
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?}"
: "${PLATFORM_DOCKER_ROOT:?}"
: "${PLATFORM_MEDIA_ROOT:?}"
: "${PLATFORM_FIXTURE_ROOT:?}"
: "${PLATFORM_REPORT_ROOT:?}"
: "${PLATFORM_DOZZLE_PORT:?}"
: "${PLATFORM_NTFY_PORT:?}"

export PLATFORM_KIND=mac
export PLATFORM_CONTRACT_VAULT_FILE=$PLATFORM_MAC_VAULT_FILE
export PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=$PLATFORM_MAC_VAULT_PASSWORD_FILE

exec "$mac_repo_dir/tests/contracts/dozzle.sh" "$@"
