#!/bin/sh
set -eu
set +x

# `run` is the default because tests/run_contracts.rb spawns contracts with no argument.
# No restart-persistence mode: the worst-case restart verdict (450s) exceeds the 300s
# ceiling; the lane's second converge proves trusted_domains survives instead.
mode=${1:-run}
case $mode in
  static|run) ;;
  *)
    printf '%s\n' 'nextcloud contract accepts only static or run' >&2
    exit 2
    ;;
esac

# $contract_repo_dir holds this script's programs; $repo_dir is the tree they inspect.
contract_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$contract_repo_dir}
static_program=$contract_repo_dir/tests/contracts/nextcloud-static.rb
runtime_program=$contract_repo_dir/tests/contracts/nextcloud-runtime.rb
# The static program reads tests/policy_support.rb from the INSPECTED tree.
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_REPO_DIR
ruby "$static_program" "$repo_dir" </dev/null

[ "$mode" = static ] && {
  printf '%s\n' 'nextcloud static contract: gated four-container document store ownership holds'
  exit 0
}

: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
# Explicit messages rather than bare `:?`, so tests can pin wording that bash and dash
# would phrase differently.
: "${PLATFORM_CONTRACT_VAULT_FILE:?PLATFORM_CONTRACT_VAULT_FILE is required}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:?PLATFORM_CONTRACT_VAULT_PASSWORD_FILE is required}"
: "${PLATFORM_DOCKER_ROOT:?PLATFORM_DOCKER_ROOT is required}"
# Must equal nextcloud_port in roles/nextcloud/defaults/main.yml; the static half checks.
: "${PLATFORM_NEXTCLOUD_PORT:=8084}"
# Container names derive from the sandbox namespace, as the overrides' do.
PLATFORM_NEXTCLOUD_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}nextcloud
PLATFORM_NEXTCLOUD_CRON_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}nextcloud-cron
PLATFORM_NEXTCLOUD_DB_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}nextcloud-db
PLATFORM_NEXTCLOUD_CACHE_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}nextcloud-cache
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_DOCKER_ROOT PLATFORM_NEXTCLOUD_PORT
export PLATFORM_NEXTCLOUD_CONTAINER PLATFORM_NEXTCLOUD_CRON_CONTAINER
export PLATFORM_NEXTCLOUD_DB_CONTAINER PLATFORM_NEXTCLOUD_CACHE_CONTAINER

exec ruby "$runtime_program" "$mode" </dev/null
