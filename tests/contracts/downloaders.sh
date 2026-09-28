#!/bin/sh
set -eu
set +x

mode=${1:-static}
[ "$mode" = static ] || {
  printf '%s\n' 'downloaders contract accepts only static' >&2
  exit 2
}

# Programs come from this checkout; $repo_dir is the tree they inspect.
# Never resolve a program from $repo_dir, or the contract judges itself.
contract_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$contract_repo_dir}
static_program=$contract_repo_dir/tests/contracts/downloaders-static.rb
# Bound to the INSPECTED tree deliberately: its own flatten helpers must agree
# with its own task files.
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_REPO_DIR
ruby "$static_program" "$repo_dir" </dev/null
