#!/bin/sh
set -eu
set +x

mode=${1:-run}
case $mode in
  static|run|seed|verify) ;;
  *)
    printf '%s\n' 'kapowarr contract accepts only static, run, seed or verify' >&2
    exit 2
    ;;
esac

# Programs come from this checkout ($contract_repo_dir); $repo_dir is the tree
# they inspect, which PLATFORM_CONTRACT_REPO_DIR may point at a fixture.
contract_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$contract_repo_dir}
static_program=$contract_repo_dir/tests/contracts/kapowarr-static.rb
runtime_program=$contract_repo_dir/tests/contracts/kapowarr-runtime.rb
# Named rather than derived, so its absence fails loudly (#773).
upgrade_program=$contract_repo_dir/tests/contracts/kapowarr-upgrade.rb
# Deliberately the inspected tree: its declarations must match the deployed service.
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_REPO_DIR
# Upgrade modes skip the static half: the lane repins the tree underneath them.
case $mode in
  seed|verify) ;;
  *) ruby "$static_program" "$repo_dir" </dev/null ;;
esac

[ "$mode" = static ] && {
  printf '%s\n' 'kapowarr static contract: authenticated comics writer ownership holds'
  exit 0
}

# Disposable lanes name the container after the project namespace.
: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_FILE:?PLATFORM_CONTRACT_VAULT_FILE is required}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:?PLATFORM_CONTRACT_VAULT_PASSWORD_FILE is required}"
: "${PLATFORM_DOCKER_ROOT:?PLATFORM_DOCKER_ROOT is required}"
: "${PLATFORM_KAPOWARR_PORT:=5656}"
PLATFORM_KAPOWARR_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}kapowarr
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_DOCKER_ROOT PLATFORM_KAPOWARR_PORT PLATFORM_KAPOWARR_CONTAINER
export PLATFORM_CONTRACT_REPO_DIR

case $mode in
  seed|verify) exec ruby "$upgrade_program" "$mode" </dev/null ;;
esac

exec ruby "$runtime_program" </dev/null
