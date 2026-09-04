#!/bin/sh
# Seerr's drift is one toggle in the web interface, and it is the toggle the
# whole permission design rests on. newPlexLogin ships true, and with it true
# any Jellyfin user who signs in is silently created in Seerr holding
# defaultPermissions — which is how "newly discovered Jellyfin users do not
# inherit these permissions automatically" stops being true without anybody
# deleting a rule or editing a file.
#
# It is chosen over the other candidates because it is invisible: nothing about
# the running service looks different afterwards, no container restarts, and
# the only place it shows is a field in the anonymous public settings. A hook
# that toggled a Radarr row instead would be caught by the arr reconcile
# anyway.
#
# The lane requires that verification alone refuses the drifted deployment, and
# leaves it drifted for the reconcile phase to repair by converging: the role
# compares the declared subset of the main settings and posts on drift.
set -eu
set +x
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

: "${PLATFORM_SEERR_PORT:?PLATFORM_SEERR_PORT is required}"
: "${PLATFORM_REPORT_ROOT:?PLATFORM_REPORT_ROOT is required}"
: "${PLATFORM_MAC_VAULT_FILE:?PLATFORM_MAC_VAULT_FILE is required}"
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?PLATFORM_MAC_VAULT_PASSWORD_FILE is required}"

expected_failure=$(mktemp "$PLATFORM_REPORT_ROOT/seerr-verify-drift.XXXXXX")
trap 'unlink "$expected_failure" >/dev/null 2>&1 || true' EXIT HUP INT TERM

# The mutation is 58-seerr.rb beside this file. It arrived here as a
# `<<'RUBY'` heredoc until #315, where sh -n, ruby -c and a reader could reach
# none of it. Resolve it from this hook's own checkout rather than from any tree
# an argument or the environment supplies, and hold standard input at
# end-of-file: a heredoc exhausted it by construction and a sibling program
# would inherit the hook's.
PLATFORM_SEERR_PORT=$PLATFORM_SEERR_PORT \
PLATFORM_MAC_VAULT_FILE=$PLATFORM_MAC_VAULT_FILE \
PLATFORM_MAC_VAULT_PASSWORD_FILE=$PLATFORM_MAC_VAULT_PASSWORD_FILE \
  "$mac_repo_dir/tests/mac/hooks/drift/58-seerr.rb" </dev/null

if mac_ansible_playbook -i "$mac_repo_dir/inventory/mac.yml" "$mac_repo_dir/verify.yml" \
    --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE" \
    -e @"$PLATFORM_MAC_VAULT_FILE" \
    -e "platform_vault_file=$PLATFORM_MAC_VAULT_FILE" \
    --tags platform_verify_seerr >"$expected_failure" 2>&1; then
  printf '%s\n' 'verification-only run accepted Seerr sign-in policy drift' >&2
  exit 1
fi
"$mac_repo_dir/tests/assert-no-vault-secrets.rb" \
  "$PLATFORM_MAC_VAULT_FILE" "$PLATFORM_MAC_VAULT_PASSWORD_FILE" "$expected_failure"
grep -qF 'sign-in policy' "$expected_failure" || {
  printf '%s\n' 'Seerr verification refused drift without its fixed diagnostic' >&2
  exit 1
}

printf '%s\n' 'Seerr drift: the hand-made sign-in policy is rejected until the platform reconverges'
