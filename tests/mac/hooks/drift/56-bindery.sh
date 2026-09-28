#!/bin/sh
# Bindery's drift is a deleted audiobook root folder, which silently collapses to
# one library. Not the identity: Bindery's user API makes that unrepairable by
# rewrite. Left drifted for reconcile.
set -eu
set +x
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

: "${PLATFORM_BINDERY_PORT:?PLATFORM_BINDERY_PORT is required}"
: "${PLATFORM_REPORT_ROOT:?PLATFORM_REPORT_ROOT is required}"
: "${PLATFORM_MAC_VAULT_FILE:?PLATFORM_MAC_VAULT_FILE is required}"
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?PLATFORM_MAC_VAULT_PASSWORD_FILE is required}"

expected_failure=$(mktemp "$PLATFORM_REPORT_ROOT/bindery-verify-drift.XXXXXX")
trap 'unlink "$expected_failure" >/dev/null 2>&1 || true' EXIT HUP INT TERM

# stdin at EOF so the program does not inherit the hook's.
PLATFORM_BINDERY_PORT=$PLATFORM_BINDERY_PORT \
PLATFORM_MAC_VAULT_FILE=$PLATFORM_MAC_VAULT_FILE \
PLATFORM_MAC_VAULT_PASSWORD_FILE=$PLATFORM_MAC_VAULT_PASSWORD_FILE \
  "$mac_repo_dir/tests/mac/hooks/drift/56-bindery.rb" </dev/null

if mac_ansible_playbook -i "$mac_repo_dir/inventory/mac.yml" "$mac_repo_dir/verify.yml" \
    --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE" \
    -e @"$PLATFORM_MAC_VAULT_FILE" \
    -e "platform_vault_file=$PLATFORM_MAC_VAULT_FILE" \
    --tags platform_verify_bindery >"$expected_failure" 2>&1; then
  printf '%s\n' 'verification-only run accepted Bindery destination root drift' >&2
  exit 1
fi
"$mac_repo_dir/tests/assert-no-vault-secrets.rb" \
  "$PLATFORM_MAC_VAULT_FILE" "$PLATFORM_MAC_VAULT_PASSWORD_FILE" "$expected_failure"
grep -qF 'owns exactly the declared ebook and audiobook destination roots' "$expected_failure" || {
  printf '%s\n' 'Bindery verification refused drift without its fixed diagnostic' >&2
  exit 1
}

printf '%s\n' 'Bindery drift: the removed audiobook root is rejected until the platform reconverges'
