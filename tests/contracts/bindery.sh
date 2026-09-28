#!/bin/sh
set -eu
set +x

mode=${1:-run}
case $mode in
  static|run|seed|verify) ;;
  *)
    printf '%s\n' 'bindery contract accepts only static, run, seed or verify' >&2
    exit 2
    ;;
esac

# Programs come from this checkout; $repo_dir is the tree they inspect.
# Never resolve a program from $repo_dir, or the contract judges itself.
contract_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$contract_repo_dir}
static_program=$contract_repo_dir/tests/contracts/bindery-static.rb
runtime_program=$contract_repo_dir/tests/contracts/bindery-runtime.rb
# The upgrade lane's seed-and-verify half (#773), named so its absence is loud.
upgrade_program=$contract_repo_dir/tests/contracts/bindery-upgrade.rb
# No PLATFORM_CONTRACT_REPO_DIR export: neither program reads the tree through the
# environment. The upgrade modes skip the static half: the lane is repinning the tree.
case $mode in
  seed|verify) ;;
  *) ruby "$static_program" "$repo_dir" </dev/null ;;
esac

[ "$mode" = static ] && {
  printf '%s\n' 'bindery static contract: two-library acquisition ownership holds'
  exit 0
}

# Lanes namespace the container name; production keeps the canonical one.
: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_FILE:?PLATFORM_CONTRACT_VAULT_FILE is required}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:?PLATFORM_CONTRACT_VAULT_PASSWORD_FILE is required}"
: "${PLATFORM_DOCKER_ROOT:?PLATFORM_DOCKER_ROOT is required}"
: "${PLATFORM_BINDERY_PORT:=8787}"
# The lane states whether it enabled the transport; the contract does not guess.
: "${PLATFORM_BINDERY_USENET:=false}"
PLATFORM_BINDERY_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}bindery
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_DOCKER_ROOT PLATFORM_BINDERY_PORT PLATFORM_BINDERY_CONTAINER
export PLATFORM_BINDERY_USENET

case $mode in
  seed|verify) exec ruby "$upgrade_program" "$mode" </dev/null ;;
esac

exec ruby "$runtime_program" </dev/null
