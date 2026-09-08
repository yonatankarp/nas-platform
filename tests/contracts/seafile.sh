#!/bin/sh
set -eu
set +x

# Five modes, and three of them exist because of how contracts are swept.
# tests/run_contracts.rb spawns every registered contract with NO argument --
# so `run` is what a registry sweep reaches -- under CONTRACT_TIMEOUT_SECONDS,
# 60 by default, and TERMs the process group when that expires. Restarting the
# Seafile server and waiting for it to serve again is minutes of work
# (roles/seafile budgets 600 seconds for the deployment wait alone), so it
# cannot live in `run`; dropping three databases and restoring them is both
# slower and destructive. They are modes of their own, invoked by the seafile
# lane directly, on the precedent tests/contracts/immich.sh set with its
# clean-restore-seed / clean-restore-assert pair: modes the registry sweep never
# selects because it passes no argument at all.
#
# The two rehearsal modes are a pair with a converge between them. The seed
# uploads a file, the lane then runs roles/seafile with
# seafile_pre_upgrade_backup_force so that THIS PLATFORM'S backup is what gets
# taken, and the assert restores that backup and downloads the file back. A
# single mode could not do that without dumping the database itself, which would
# prove the contract rather than the platform.
mode=${1:-run}
case $mode in
  static|run|restart-persistence|restore-rehearsal-seed|restore-rehearsal-assert) ;;
  *)
    printf '%s\n' 'seafile contract accepts only static, run, restart-persistence, restore-rehearsal-seed or restore-rehearsal-assert' >&2
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
static_program=$contract_repo_dir/tests/contracts/seafile-static.rb
runtime_program=$contract_repo_dir/tests/contracts/seafile-runtime.rb
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
  printf '%s\n' 'seafile static contract: gated three-container file store ownership holds'
  exit 0
}

: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
# Every requirement carries its own message rather than a bare `:?`, so
# tests/seafile_contract_test.rb can pin the wrapper's own wording: bash and dash
# word the shell's own null-or-unset diagnostic differently, and a row asserting
# either of those spellings is asserting the shell rather than this contract.
: "${PLATFORM_CONTRACT_VAULT_FILE:?PLATFORM_CONTRACT_VAULT_FILE is required}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:?PLATFORM_CONTRACT_VAULT_PASSWORD_FILE is required}"
: "${PLATFORM_DOCKER_ROOT:?PLATFORM_DOCKER_ROOT is required}"
# 8083, and it must equal roles/seafile/defaults/main.yml's seafile_port. The
# static half asserts that equality against this very line, so the two cannot
# drift apart silently.
: "${PLATFORM_SEAFILE_PORT:=8083}"
# All three container names derive from the sandbox namespace the harness
# exports, exactly as the disposable overrides derive theirs, so nothing here
# has to know whether it is talking to the production stack or to a sandbox
# copy of it.
PLATFORM_SEAFILE_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}seafile
PLATFORM_SEAFILE_DB_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}seafile-db
PLATFORM_SEAFILE_CACHE_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}seafile-cache
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_DOCKER_ROOT PLATFORM_SEAFILE_PORT
export PLATFORM_SEAFILE_CONTAINER PLATFORM_SEAFILE_DB_CONTAINER PLATFORM_SEAFILE_CACHE_CONTAINER

exec ruby "$runtime_program" "$mode" </dev/null
