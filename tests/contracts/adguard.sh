#!/bin/sh
set -eu
set +x

mode=${1:-run}
case $mode in
  static|run) ;;
  *)
    printf '%s\n' 'adguard contract accepts only static or run' >&2
    exit 2
    ;;
esac

# Two roots, deliberately separate. The checkout this script belongs to is where
# its two Ruby programs live; $repo_dir is the tree they inspect, and a caller
# may point that at a fixture repository instead. Resolving the sibling programs
# from $repo_dir would silently make a contract read its assertions out of the
# tree it is judging.
contract_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$contract_repo_dir}
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_REPO_DIR
# stdin held at end-of-file for the reason every contract in this directory
# holds it there: the program's input is the environment, and inheriting the
# caller's stdin is a difference it must never be able to observe.
ruby "$contract_repo_dir/tests/contracts/adguard-static.rb" "$repo_dir" </dev/null

[ "$mode" = static ] && {
  printf '%s\n' 'adguard static contract: declared resolver, gated deployment and stored hash hold'
  exit 0
}

# The runtime half.
: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_FILE:?PLATFORM_CONTRACT_VAULT_FILE is required}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:?PLATFORM_CONTRACT_VAULT_PASSWORD_FILE is required}"
: "${PLATFORM_DOCKER_ROOT:?PLATFORM_DOCKER_ROOT is required}"
# Production's own numbers. A disposable lane overrides both, because neither the
# privileged 53 nor 8083 is free on a machine that is already resolving.
: "${PLATFORM_ADGUARD_PORT:=8083}"
: "${PLATFORM_ADGUARD_DNS_PORT:=53}"
PLATFORM_ADGUARD_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}adguard
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_DOCKER_ROOT PLATFORM_ADGUARD_PORT PLATFORM_ADGUARD_DNS_PORT
export PLATFORM_ADGUARD_CONTAINER

exec ruby "$contract_repo_dir/tests/contracts/adguard-runtime.rb" </dev/null
