#!/bin/sh
set -eu
set +x
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"
expected_failure=$(mktemp "$PLATFORM_REPORT_ROOT/immich-verify-drift.XXXXXX")
trap 'unlink "$expected_failure" >/dev/null 2>&1 || true' EXIT HUP INT TERM

"$mac_script_dir/run-immich-contract.sh" drift
"$mac_script_dir/run-immich-contract.sh" drift-verify
if mac_ansible_playbook -i "$mac_repo_dir/inventory/mac.yml" "$mac_repo_dir/verify.yml" \
    --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE" \
    -e @"$PLATFORM_MAC_VAULT_FILE" \
    -e @"$PLATFORM_MAC_FIXTURE_VARS_FILE" \
    -e "platform_vault_file=$PLATFORM_MAC_VAULT_FILE" \
    --tags platform_verify_immich >"$expected_failure" 2>&1; then
  printf '%s\n' 'verification-only run accepted Immich drift' >&2
  exit 1
fi
"$mac_repo_dir/tests/assert-no-vault-secrets.rb" \
  "$PLATFORM_MAC_VAULT_FILE" "$PLATFORM_MAC_VAULT_PASSWORD_FILE" "$expected_failure"
# Anchor on the fail_msg, not the task banner, which prints even when the guard
# passes (#428). no_log censors the result but ansible still prints the fail_msg line.
grep -qF "Task failed: Action failed: An Immich managed user's declared preference leaves differ from its effective profile." \
  "$expected_failure" || {
  printf '%s\n' 'Immich verification refused drift without its fixed diagnostic' >&2
  exit 1
}
