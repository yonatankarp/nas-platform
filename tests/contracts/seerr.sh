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

# Two roots, and they are not the same thing. $contract_repo_dir is the checkout
# this script belongs to, which is where its two Ruby programs live -- a heredoc
# had that property by construction, because the program travelled inside the
# file. $repo_dir is the tree the static program *inspects*, which
# PLATFORM_CONTRACT_REPO_DIR lets a caller point at a fixture. Resolving a
# program from $repo_dir would make this contract read its own assertions out of
# the tree it is judging.
contract_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$contract_repo_dir}
static_program=$contract_repo_dir/tests/contracts/seerr-static.rb
runtime_program=$contract_repo_dir/tests/contracts/seerr-runtime.rb
# The static program reads tests/policy_support.rb from the INSPECTED tree
# instead of carrying its own copy of flatten_tasks, so this export stays bound
# to $repo_dir rather than to the checkout. That is deliberate rather than an
# oversight of the two-roots rule above: it is the inspected tree's own flatten
# helpers that must agree with the inspected tree's task files, and rerooting it
# would quietly stop a fixture from being able to break that.
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
PLATFORM_SEERR_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}seerr
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_DOCKER_ROOT PLATFORM_SEERR_PORT PLATFORM_SEERR_CONTAINER PLATFORM_SEERR_ARRS

exec ruby "$runtime_program" </dev/null
