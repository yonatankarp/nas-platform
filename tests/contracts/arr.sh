#!/bin/sh
set -eu
set +x

mode=${1:-static}
[ "$mode" = static ] || {
  printf '%s\n' 'arr contract accepts only static' >&2
  exit 2
}

# The program comes from this checkout ($contract_repo_dir); $repo_dir is the tree
# it inspects, which PLATFORM_CONTRACT_REPO_DIR may point at a fixture.
contract_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$contract_repo_dir}
static_program=$contract_repo_dir/tests/contracts/arr-static.rb
# Deliberately the inspected tree: its flatten helpers must match its task files.
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_REPO_DIR
ruby "$static_program" "$repo_dir" </dev/null
