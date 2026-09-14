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
#
# The Pushover endpoint is pointed at a port nothing listens on, and this is the
# only lane that needs saying so. roles/beszel gates its credential check on
# --tags platform_verify_beszel, which is exactly what this wrapper passes, so
# the check does run here -- against a vault holding the ephemeral Pushover
# stand-ins, none of which was ever a Pushover credential. Every such call would
# be a 4xx against the household's own applications, and Pushover temporarily
# blocks an IP that sends enough of them. The integration lanes need no equivalent: they converge
# site.yml with lane tags and never run verify.yml, so the tag gate excludes
# them by itself.
#
# Here rather than in inventory/group_vars/mac_hosts, because a URL is portable
# configuration rather than a machine fact and tests/policy_platform_test.rb
# refuses one there by name -- measured, not guessed. Here rather than in the
# Immich fixture vars file too, because that file is regenerated and compared
# against itself. An unreachable endpoint is the honest answer rather than a
# workaround: a lane holding stand-in credentials cannot find out whether the
# real pair works, and "did not find out" is a state the check reports and
# passes on.
mac_ansible_playbook -i "$mac_repo_dir/inventory/mac.yml" \
  "$mac_repo_dir/verify.yml" \
  --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE" \
  -e @"$PLATFORM_MAC_VAULT_FILE" \
  -e @"$PLATFORM_MAC_FIXTURE_VARS_FILE" \
  -e "platform_vault_file=$PLATFORM_MAC_VAULT_FILE" \
  -e "beszel_pushover_validation_url=http://127.0.0.1:1/1/users/validate.json" \
  --tags platform_verify_media_acquisition_foundation,platform_verify_ntfy,platform_verify_beszel,platform_verify_dozzle,platform_verify_audiobookshelf,platform_verify_komga,platform_verify_arr,platform_verify_downloaders,platform_verify_bindery,platform_verify_kapowarr,platform_verify_pinchflat,platform_verify_trailarr,platform_verify_jellyfin,platform_verify_seerr,platform_verify_immich,platform_verify_paperless,platform_verify_nextcloud,platform_verify_vaultwarden,platform_verify_karakeep

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
