#!/bin/sh
set -eu
set +x

mac_script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

: "${PLATFORM_MAC_VAULT_FILE:?PLATFORM_MAC_VAULT_FILE is required}"
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?PLATFORM_MAC_VAULT_PASSWORD_FILE is required}"

# This wrapper deliberately names only verify.yml. Calling site.yml here would
# reconverge state and could turn a verification defect into a false pass.
mac_ansible_playbook -i "$mac_repo_dir/inventory/mac.yml" \
  "$mac_repo_dir/verify.yml" \
  --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE" \
  -e @"$PLATFORM_MAC_VAULT_FILE" \
  -e "platform_vault_file=$PLATFORM_MAC_VAULT_FILE" \
  --tags platform_verify_ntfy,platform_verify_beszel,platform_verify_dozzle,platform_verify_audiobookshelf,platform_verify_komga,platform_verify_tinymediamanager,platform_verify_jellyfin,platform_verify_immich,platform_verify_paperless

mac_run_hooks verify
