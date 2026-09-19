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

# Two roots, and they are not the same thing. $contract_repo_dir is the checkout
# this script belongs to, which is where its two Ruby programs live -- a heredoc
# had that property by construction, because the program travelled inside the
# file. $repo_dir is the tree the static program *inspects*, which
# PLATFORM_CONTRACT_REPO_DIR lets a caller point at a fixture. Resolving a
# program from $repo_dir would make this contract read its own assertions out of
# the tree it is judging.
contract_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$contract_repo_dir}
static_program=$contract_repo_dir/tests/contracts/bindery-static.rb
runtime_program=$contract_repo_dir/tests/contracts/bindery-runtime.rb
# The upgrade lane's seed-and-verify half (#773). Resolved from the checkout
# this script belongs to, like the other two programs, and named here rather
# than derived so that its absence is a "no such file" at the top of a run
# instead of a mode that silently does nothing.
upgrade_program=$contract_repo_dir/tests/contracts/bindery-upgrade.rb
# No PLATFORM_CONTRACT_REPO_DIR export here, deliberately: unlike the Kapowarr
# contract, neither Bindery program reads the inspected tree through the
# environment. The static half carries its own flatten_tasks and takes the tree
# as its argument, and the runtime half reads none of the repository at all.
# The static half, which the upgrade modes skip: they assert what a deployed
# service holds across a version change, and the tree they would inspect is
# the one the lane is repinning underneath them.
case $mode in
  seed|verify) ;;
  *) ruby "$static_program" "$repo_dir" </dev/null ;;
esac

[ "$mode" = static ] && {
  printf '%s\n' 'bindery static contract: two-library acquisition ownership holds'
  exit 0
}

# The runtime half. Both disposable lanes deploy Bindery under a project
# namespace and name the container after it; production leaves the namespace
# empty and keeps the canonical Compose name.
: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_FILE:?PLATFORM_CONTRACT_VAULT_FILE is required}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:?PLATFORM_CONTRACT_VAULT_PASSWORD_FILE is required}"
: "${PLATFORM_DOCKER_ROOT:?PLATFORM_DOCKER_ROOT is required}"
: "${PLATFORM_BINDERY_PORT:=8787}"
# Prowlarr and SABnzbd only exist where the host enabled the transport, and the
# two integration rows cannot be written without them, so the lane says which
# state it converged rather than the contract guessing from what it finds.
: "${PLATFORM_BINDERY_USENET:=false}"
PLATFORM_BINDERY_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}bindery
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_DOCKER_ROOT PLATFORM_BINDERY_PORT PLATFORM_BINDERY_CONTAINER
export PLATFORM_BINDERY_USENET

case $mode in
  seed|verify) exec ruby "$upgrade_program" "$mode" </dev/null ;;
esac

exec ruby "$runtime_program" </dev/null
