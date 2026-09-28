#!/bin/sh
# A settings toggle persists into /config/.env, which start.sh sources over the
# container environment, so a hand toggle wins against Compose on every restart.
# Left drifted for reconcile, which removes the line and restarts.
set -eu
set +x
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

: "${PLATFORM_TRAILARR_PORT:?PLATFORM_TRAILARR_PORT is required}"
: "${PLATFORM_REPORT_ROOT:?PLATFORM_REPORT_ROOT is required}"
: "${PLATFORM_MAC_VAULT_FILE:?PLATFORM_MAC_VAULT_FILE is required}"
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?PLATFORM_MAC_VAULT_PASSWORD_FILE is required}"

expected_failure=$(mktemp "$PLATFORM_REPORT_ROOT/trailarr-verify-drift.XXXXXX")
trap 'unlink "$expected_failure" >/dev/null 2>&1 || true' EXIT HUP INT TERM

# stdin at EOF so the program does not inherit the hook's.
PLATFORM_TRAILARR_PORT=$PLATFORM_TRAILARR_PORT \
PLATFORM_MAC_VAULT_FILE=$PLATFORM_MAC_VAULT_FILE \
PLATFORM_MAC_VAULT_PASSWORD_FILE=$PLATFORM_MAC_VAULT_PASSWORD_FILE \
  "$mac_repo_dir/tests/mac/hooks/drift/57-trailarr.rb" </dev/null

if mac_ansible_playbook -i "$mac_repo_dir/inventory/mac.yml" "$mac_repo_dir/verify.yml" \
    --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE" \
    -e @"$PLATFORM_MAC_VAULT_FILE" \
    -e "platform_vault_file=$PLATFORM_MAC_VAULT_FILE" \
    --tags platform_verify_trailarr >"$expected_failure" 2>&1; then
  printf '%s\n' 'verification-only run accepted Trailarr settings drift' >&2
  exit 1
fi
"$mac_repo_dir/tests/assert-no-vault-secrets.rb" \
  "$PLATFORM_MAC_VAULT_FILE" "$PLATFORM_MAC_VAULT_PASSWORD_FILE" "$expected_failure"
grep -qF 'declared settings to exactly the vault-authored identity' "$expected_failure" || {
  printf '%s\n' 'Trailarr verification refused drift without its fixed diagnostic' >&2
  exit 1
}

printf '%s\n' 'Trailarr drift: the hand-made setting is rejected until the platform reconverges'
