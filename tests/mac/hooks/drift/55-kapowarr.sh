#!/bin/sh
# Kapowarr's drift is its identity, and unlike Pinchflat's it does not live in a
# file the platform renders: the application hashes both halves with a salt it
# generated at first start and keeps in its own database. The only hand edit
# that can be reproduced from outside is the one a person actually makes in the
# web interface — clearing the login — and it is also the dangerous one, because
# an unprotected Kapowarr hands its API key, and with it every route that
# renames or deletes comics, to anyone who can reach the port.
#
# The lane then requires that verification alone refuses the drifted deployment,
# and leaves it drifted for the reconcile phase to repair by converging.
set -eu
set +x
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

: "${PLATFORM_KAPOWARR_PORT:?PLATFORM_KAPOWARR_PORT is required}"
: "${PLATFORM_REPORT_ROOT:?PLATFORM_REPORT_ROOT is required}"
: "${PLATFORM_MAC_VAULT_FILE:?PLATFORM_MAC_VAULT_FILE is required}"
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?PLATFORM_MAC_VAULT_PASSWORD_FILE is required}"

expected_failure=$(mktemp "$PLATFORM_REPORT_ROOT/kapowarr-verify-drift.XXXXXX")
trap 'unlink "$expected_failure" >/dev/null 2>&1 || true' EXIT HUP INT TERM

# The mutation is 55-kapowarr.rb beside this file. It arrived here as a
# `<<'RUBY'` heredoc until #315, where sh -n, ruby -c and a reader could reach
# none of it. Resolve it from this hook's own checkout rather than from any tree
# an argument or the environment supplies, and hold standard input at
# end-of-file: a heredoc exhausted it by construction and a sibling program
# would inherit the hook's.
PLATFORM_KAPOWARR_PORT=$PLATFORM_KAPOWARR_PORT \
PLATFORM_MAC_VAULT_FILE=$PLATFORM_MAC_VAULT_FILE \
PLATFORM_MAC_VAULT_PASSWORD_FILE=$PLATFORM_MAC_VAULT_PASSWORD_FILE \
  "$mac_repo_dir/tests/mac/hooks/drift/55-kapowarr.rb" </dev/null

if mac_ansible_playbook -i "$mac_repo_dir/inventory/mac.yml" "$mac_repo_dir/verify.yml" \
    --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE" \
    -e @"$PLATFORM_MAC_VAULT_FILE" \
    -e "platform_vault_file=$PLATFORM_MAC_VAULT_FILE" \
    --tags platform_verify_kapowarr >"$expected_failure" 2>&1; then
  printf '%s\n' 'verification-only run accepted Kapowarr identity drift' >&2
  exit 1
fi
"$mac_repo_dir/tests/assert-no-vault-secrets.rb" \
  "$PLATFORM_MAC_VAULT_FILE" "$PLATFORM_MAC_VAULT_PASSWORD_FILE" "$expected_failure"
grep -qF 'no longer accepts exactly the vault-authored' "$expected_failure" || {
  printf '%s\n' 'Kapowarr verification refused drift without its fixed diagnostic' >&2
  exit 1
}

printf '%s\n' 'Kapowarr drift: the cleared login is rejected until the platform reconverges'
