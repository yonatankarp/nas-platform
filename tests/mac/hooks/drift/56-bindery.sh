#!/bin/sh
# Bindery's drift is a destination root, and it is the hand edit a person
# actually makes: the web interface offers a delete button beside every root
# folder, and removing the audiobook one is invisible everywhere else — the
# container stays healthy, the administrator still logs in, and imports simply
# fall back to the ebook library, which is the single-library collapse the
# design forbids.
#
# The identity is deliberately not the drift here. Bindery answers 500 to a
# duplicate user, refuses to delete its last administrator, and its login
# limiter answers 429 to the correct password after five failures, so a drifted
# identity is not a state a converge may repair by rewriting. A root folder is:
# the role reads the declared roots and creates only the missing ones.
#
# The lane requires that verification alone refuses the drifted deployment, and
# leaves it drifted for the reconcile phase to repair by converging.
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

# The mutation is 56-bindery.rb beside this file. It arrived here as a
# `<<'RUBY'` heredoc until #315, where sh -n, ruby -c and a reader could reach
# none of it. Resolve it from this hook's own checkout rather than from any tree
# an argument or the environment supplies, and hold standard input at
# end-of-file: a heredoc exhausted it by construction and a sibling program
# would inherit the hook's.
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
