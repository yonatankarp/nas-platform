#!/bin/sh
set -eu
set +x

: "${PLATFORM_MAC_VAULT_FILE:?PLATFORM_MAC_VAULT_FILE is required}"
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?PLATFORM_MAC_VAULT_PASSWORD_FILE is required}"
: "${PLATFORM_NTFY_PORT:?PLATFORM_NTFY_PORT is required}"
: "${PLATFORM_NTFY_TOPICS:=nas-critical nas-deployment nas-containers nas-requests}"

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_hook_dir/../../../.." && pwd -P)

ntfy_hook_base_url=http://127.0.0.1:$PLATFORM_NTFY_PORT
# The account verification is 15-ntfy.rb beside this file. It arrived here as a
# `<<'RUBY'` heredoc opened on file descriptor 3 until #315, where sh -n, ruby -c
# and a reader could reach none of it, and its four `-r` preloads are now
# requires inside it. Resolve it from this hook's own checkout rather than from
# any tree an argument or the environment supplies.
#
# Deliberately no `</dev/null` here, unlike every other program #315 lifted out
# of a heredoc: the decrypted vault is piped in, and this program reads it from
# standard input. That is why the heredoc was on descriptor 3 in the first place.
ansible-vault view \
  --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE" \
  "$PLATFORM_MAC_VAULT_FILE" 2>/dev/null |
  PLATFORM_NTFY_BASE_URL=$ntfy_hook_base_url \
  PLATFORM_NTFY_TOPICS="$PLATFORM_NTFY_TOPICS" \
    "$mac_repo_dir/tests/mac/hooks/verify/15-ntfy.rb"
