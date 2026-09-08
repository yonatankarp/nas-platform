#!/bin/sh
set -eu
set +x

# Two modes, and the second one is what a registry sweep reaches.
# tests/run_contracts.rb spawns every registered contract with NO argument -- so
# `run` is the default -- under CONTRACT_TIMEOUT_SECONDS, 60 by default and
# capped at 300, and TERMs the process group when that expires.
#
# Seafile carries three more modes and this contract deliberately carries none of
# them, which is a decision rather than an omission. The mode worth wanting is a
# restart-persistence pair like Seafile's, proving that the trusted domain list
# roles/nextcloud reconciles survives a container restart. It cannot live here:
# services/nextcloud/compose.yml gives the application a 300s start_period and
# roles/nextcloud budgets 600s for the deployment wait, so the worst-case verdict
# on a restarted container is 450s -- above the 300s ceiling run_contracts.rb
# will accept for any mode at all, let alone the 60s a sweep allows.
#
# What buys the claim instead is the lane's own second converge.
# run_enabled_idempotence nextcloud reconverges and requires a clean recap, so a
# Nextcloud that rewrote trusted_domains on every start would make the
# reconciliation report changed on run 2 and fail the lane there. That is the
# same refutation arriving one layer out, for no extra budget.
mode=${1:-run}
case $mode in
  static|run) ;;
  *)
    printf '%s\n' 'nextcloud contract accepts only static or run' >&2
    exit 2
    ;;
esac

# Two roots, and they are not the same thing. $contract_repo_dir is the checkout
# this script belongs to, which is where its two Ruby programs live. $repo_dir is
# the tree the static program *inspects*, which PLATFORM_CONTRACT_REPO_DIR lets a
# caller point at a fixture. Resolving a program from $repo_dir would make this
# contract read its own assertions out of the tree it is judging.
contract_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$contract_repo_dir}
static_program=$contract_repo_dir/tests/contracts/nextcloud-static.rb
runtime_program=$contract_repo_dir/tests/contracts/nextcloud-runtime.rb
# The static program reads tests/policy_support.rb from the INSPECTED tree
# instead of carrying its own copy of flatten_tasks, so this export stays bound
# to $repo_dir rather than to the checkout, exactly as the Seafile contract's
# does and for the same reason: it is the inspected tree's own flatten helpers
# that must agree with the inspected tree's task files.
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_REPO_DIR
ruby "$static_program" "$repo_dir" </dev/null

[ "$mode" = static ] && {
  printf '%s\n' 'nextcloud static contract: gated four-container document store ownership holds'
  exit 0
}

: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
# Every requirement carries its own message rather than a bare `:?`, so
# tests/nextcloud_contract_test.rb can pin the wrapper's own wording: bash and
# dash word the shell's own null-or-unset diagnostic differently, and a row
# asserting either of those spellings is asserting the shell rather than this
# contract.
: "${PLATFORM_CONTRACT_VAULT_FILE:?PLATFORM_CONTRACT_VAULT_FILE is required}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:?PLATFORM_CONTRACT_VAULT_PASSWORD_FILE is required}"
: "${PLATFORM_DOCKER_ROOT:?PLATFORM_DOCKER_ROOT is required}"
# 8084, and it must equal roles/nextcloud/defaults/main.yml's nextcloud_port. The
# static half asserts that equality against this very line, so the two cannot
# drift apart silently.
: "${PLATFORM_NEXTCLOUD_PORT:=8084}"
# All four container names derive from the sandbox namespace the harness exports,
# exactly as the disposable overrides derive theirs, so nothing here has to know
# whether it is talking to the production stack or to a sandbox copy of it.
PLATFORM_NEXTCLOUD_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}nextcloud
PLATFORM_NEXTCLOUD_CRON_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}nextcloud-cron
PLATFORM_NEXTCLOUD_DB_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}nextcloud-db
PLATFORM_NEXTCLOUD_CACHE_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}nextcloud-cache
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_DOCKER_ROOT PLATFORM_NEXTCLOUD_PORT
export PLATFORM_NEXTCLOUD_CONTAINER PLATFORM_NEXTCLOUD_CRON_CONTAINER
export PLATFORM_NEXTCLOUD_DB_CONTAINER PLATFORM_NEXTCLOUD_CACHE_CONTAINER

exec ruby "$runtime_program" "$mode" </dev/null
