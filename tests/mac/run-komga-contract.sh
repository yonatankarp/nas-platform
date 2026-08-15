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
: "${PLATFORM_KOMGA_PORT:?PLATFORM_KOMGA_PORT is required}"

if [ "${1-}" = seed ] && [ "${PLATFORM_PROOF_LANE:-}" = adoption ] &&
    [ "${PLATFORM_ADOPTION_PROBE_TARGET:-false}" != true ]; then
  : "${PLATFORM_MAC_SANDBOX:?PLATFORM_MAC_SANDBOX is required}"
  PLATFORM_KOMGA_CONFIG_PATH=$PLATFORM_MAC_SANDBOX/legacy/komga/config
  export PLATFORM_KOMGA_CONFIG_PATH
  PLATFORM_KOMGA_RUNTIME_CONTEXT=legacy
else
  PLATFORM_KOMGA_RUNTIME_CONTEXT=mac-managed
fi
export PLATFORM_KOMGA_RUNTIME_CONTEXT

PLATFORM_CONTRACT_VAULT_FILE=$PLATFORM_MAC_VAULT_FILE \
PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=$PLATFORM_MAC_VAULT_PASSWORD_FILE \
  exec "$mac_repo_dir/tests/contracts/komga.sh" "$@"
