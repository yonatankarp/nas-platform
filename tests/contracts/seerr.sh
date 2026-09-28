#!/bin/sh
set -eu
set +x

mode=${1:-run}
case $mode in
  static|run) ;;
  *)
    printf '%s\n' 'seerr contract accepts only static or run' >&2
    exit 2
    ;;
esac

# Programs come from this checkout; $repo_dir is the tree they inspect.
# Never resolve a program from $repo_dir, or the contract judges itself.
contract_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$contract_repo_dir}
static_program=$contract_repo_dir/tests/contracts/seerr-static.rb
runtime_program=$contract_repo_dir/tests/contracts/seerr-runtime.rb
# Bound to the INSPECTED tree deliberately: its own flatten helpers must agree
# with its own task files.
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_REPO_DIR
ruby "$static_program" "$repo_dir" </dev/null

[ "$mode" = static ] && {
  printf '%s\n' 'seerr static contract: bootstrapped request front end ownership holds'
  exit 0
}

: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_FILE:?PLATFORM_CONTRACT_VAULT_FILE is required}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:?PLATFORM_CONTRACT_VAULT_PASSWORD_FILE is required}"
: "${PLATFORM_DOCKER_ROOT:?PLATFORM_DOCKER_ROOT is required}"
: "${PLATFORM_SEERR_PORT:=5055}"
: "${PLATFORM_SEERR_ARRS:=false}"
: "${PLATFORM_SEERR_PUSHOVER_BLANKED:=false}"
PLATFORM_SEERR_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}seerr
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_DOCKER_ROOT PLATFORM_SEERR_PORT PLATFORM_SEERR_CONTAINER PLATFORM_SEERR_ARRS
export PLATFORM_SEERR_PUSHOVER_BLANKED

exec ruby "$runtime_program" </dev/null
