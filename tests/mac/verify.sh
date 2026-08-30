#!/bin/sh
set -eu
set +x

mac_script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

: "${PLATFORM_MAC_VAULT_FILE:?PLATFORM_MAC_VAULT_FILE is required}"
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?PLATFORM_MAC_VAULT_PASSWORD_FILE is required}"
: "${PLATFORM_MAC_FIXTURE_VARS_FILE:?PLATFORM_MAC_FIXTURE_VARS_FILE is required}"

# This wrapper deliberately names only verify.yml. Calling site.yml here would
# reconverge state and could turn a verification defect into a false pass.
mac_ansible_playbook -i "$mac_repo_dir/inventory/mac.yml" \
  "$mac_repo_dir/verify.yml" \
  --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE" \
  -e @"$PLATFORM_MAC_VAULT_FILE" \
  -e @"$PLATFORM_MAC_FIXTURE_VARS_FILE" \
  -e "platform_vault_file=$PLATFORM_MAC_VAULT_FILE" \
  --tags platform_verify_media_acquisition_foundation,platform_verify_ntfy,platform_verify_beszel,platform_verify_dozzle,platform_verify_audiobookshelf,platform_verify_komga,platform_verify_arr,platform_verify_downloaders,platform_verify_kapowarr,platform_verify_pinchflat,platform_verify_jellyfin,platform_verify_immich,platform_verify_paperless

for mac_verify_hook in $MAC_VERIFY_INFRASTRUCTURE_HOOKS; do
  mac_verify_hook_path=$mac_script_dir/hooks/verify/$mac_verify_hook
  [ -f "$mac_verify_hook_path" ] && [ ! -L "$mac_verify_hook_path" ] &&
    [ -x "$mac_verify_hook_path" ] ||
    mac_die "unsafe or non-executable Mac verify hook: $mac_verify_hook_path"
  "$mac_verify_hook_path"
done

mac_verify_services_hook=$mac_script_dir/hooks/verify/30-services.sh
[ -f "$mac_verify_services_hook" ] && [ ! -L "$mac_verify_services_hook" ] &&
  [ -x "$mac_verify_services_hook" ] ||
  mac_die "unsafe or non-executable Mac verify hook: $mac_verify_services_hook"
"$mac_verify_services_hook"
