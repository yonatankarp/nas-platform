#!/bin/sh
set -eu
set +x

mac_script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)

: "${PLATFORM_MAC_VAULT_FILE:?PLATFORM_MAC_VAULT_FILE is required}"
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?PLATFORM_MAC_VAULT_PASSWORD_FILE is required}"
: "${PLATFORM_MEDIA_ROOT:?PLATFORM_MEDIA_ROOT is required}"
: "${PLATFORM_REPORT_ROOT:?PLATFORM_REPORT_ROOT is required}"
: "${PLATFORM_KOMGA_PORT:?PLATFORM_KOMGA_PORT is required}"

if [ "${PLATFORM_KIND:-}" = integration ]; then
  PLATFORM_KOMGA_RUNTIME_CONTEXT=base
else
  PLATFORM_KOMGA_RUNTIME_CONTEXT=mac-managed
fi
export PLATFORM_KOMGA_RUNTIME_CONTEXT

PLATFORM_CONTRACT_VAULT_FILE=$PLATFORM_MAC_VAULT_FILE \
PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=$PLATFORM_MAC_VAULT_PASSWORD_FILE \
  exec "$mac_repo_dir/tests/contracts/komga.sh" "$@"
