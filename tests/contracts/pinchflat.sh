#!/bin/sh
set -eu
set +x

mode=${1:-run}
case $mode in
  static|run) ;;
  *)
    printf '%s\n' 'pinchflat contract accepts only static or run' >&2
    exit 2
    ;;
esac

# $contract_repo_dir holds this script's programs; $repo_dir is the tree they inspect.
contract_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$contract_repo_dir}
# pinchflat-static.rb reads tests/policy_support.rb from the inspected tree.
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_REPO_DIR
# stdin stays at end-of-file so the program can never consume the caller's.
ruby "$contract_repo_dir/tests/contracts/pinchflat-static.rb" "$repo_dir" </dev/null

[ "$mode" = static ] && {
  printf '%s\n' 'pinchflat static contract: authenticated YouTube writer ownership holds'
  exit 0
}

# Disposable lanes namespace the container name; production leaves it canonical.
: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_FILE:?PLATFORM_CONTRACT_VAULT_FILE is required}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:?PLATFORM_CONTRACT_VAULT_PASSWORD_FILE is required}"
: "${PLATFORM_DOCKER_ROOT:?PLATFORM_DOCKER_ROOT is required}"
: "${PLATFORM_PINCHFLAT_PORT:=8945}"
PLATFORM_PINCHFLAT_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}pinchflat
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_DOCKER_ROOT PLATFORM_PINCHFLAT_PORT PLATFORM_PINCHFLAT_CONTAINER

# No arguments: the exports above are its whole input.
exec ruby "$contract_repo_dir/tests/contracts/pinchflat-runtime.rb" </dev/null
