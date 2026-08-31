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

# Two roots, deliberately separate. The checkout this script belongs to is where
# its two Ruby programs live; $repo_dir is the tree they inspect, and a caller
# may point that at a fixture repository instead. A heredoc kept the two apart by
# construction -- the program travelled inside this file -- so resolving the
# sibling programs from $repo_dir would silently make a contract read its
# assertions out of the tree it is judging.
contract_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$contract_repo_dir}
# pinchflat-static.rb reads tests/policy_support.rb from here instead of
# carrying its own copy of flatten_tasks.
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_REPO_DIR
# The 168-line Ruby program this used to pipe in from a quoted heredoc is now
# pinchflat-static.rb, where sh -n, a linter and tests/pinchflat_contract_test.rb
# can all reach it. Its stdin was that heredoc, exhausted by the time the program
# ran; keep stdin at end-of-file so it can never consume the caller's.
ruby "$contract_repo_dir/tests/contracts/pinchflat-static.rb" "$repo_dir" </dev/null

[ "$mode" = static ] && {
  printf '%s\n' 'pinchflat static contract: authenticated YouTube writer ownership holds'
  exit 0
}

# The runtime half. Both disposable lanes deploy Pinchflat under a project
# namespace and name the container after it; production leaves the namespace
# empty and keeps the canonical Compose name.
: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_FILE:?PLATFORM_CONTRACT_VAULT_FILE is required}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:?PLATFORM_CONTRACT_VAULT_PASSWORD_FILE is required}"
: "${PLATFORM_DOCKER_ROOT:?PLATFORM_DOCKER_ROOT is required}"
: "${PLATFORM_PINCHFLAT_PORT:=8945}"
PLATFORM_PINCHFLAT_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}pinchflat
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_DOCKER_ROOT PLATFORM_PINCHFLAT_PORT PLATFORM_PINCHFLAT_CONTAINER

# pinchflat-runtime.rb reads no arguments: everything exported above is its
# input. The </dev/null is the same rule as above -- the heredoc it replaced was
# this program's stdin, and inheriting the caller's instead is a difference the
# program must never be able to observe.
exec ruby "$contract_repo_dir/tests/contracts/pinchflat-runtime.rb" </dev/null
