#!/bin/sh
set -eu

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

: "${PLATFORM_MAC_FIXTURE_VARS_FILE:?PLATFORM_MAC_FIXTURE_VARS_FILE is required}"
mac_ansible_playbook -i "$mac_repo_dir/inventory/mac.yml" "$mac_repo_dir/verify.yml" \
  --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE" \
  -e @"$PLATFORM_MAC_VAULT_FILE" \
  -e @"$PLATFORM_MAC_FIXTURE_VARS_FILE" \
  -e "platform_vault_file=$PLATFORM_MAC_VAULT_FILE" \
  --tags platform_verify_tinymediamanager
"$mac_script_dir/run-tinymediamanager-contract.sh" assert-retired
