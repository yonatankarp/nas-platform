#!/bin/sh
set -eu
set +x
umask 077

mode=${1:-verify}
case $mode in static|telemetry-fixtures|verify|drift|drift-verify|duplicate|wrong-owner|remove-duplicate|notify) ;; *) exit 2 ;; esac

# Programs come from this checkout ($contract_repo_dir); $repo_dir is the tree
# they inspect, which PLATFORM_CONTRACT_REPO_DIR may point at a fixture.
contract_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$contract_repo_dir}
static_program=$contract_repo_dir/tests/contracts/beszel-static.rb
telemetry_fixtures_program=$contract_repo_dir/tests/contracts/beszel-telemetry-fixtures.rb
runtime_program=$contract_repo_dir/tests/contracts/beszel-runtime.rb
# Deliberately the inspected tree: its helpers must agree with its own files.
# The second assignment/export pair below is redundant.
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_REPO_DIR
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_REPO_DIR

if [ "$mode" = static ]; then
  ruby -ryaml "$static_program" "$repo_dir" </dev/null
  exit 0
fi

if [ "$mode" = telemetry-fixtures ]; then
  [ "$#" -eq 3 ] || exit 2
  exec ruby -rjson -r"$repo_dir/tests/contracts/support/beszel_telemetry" \
    "$telemetry_fixtures_program" "$2" "$3" </dev/null
fi

: "${PLATFORM_CONTRACT_VAULT_FILE:?}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:?}"
: "${PLATFORM_REPORT_ROOT:?}"
: "${PLATFORM_BESZEL_PORT:=8090}"
: "${PLATFORM_KIND:=nas}"
export PLATFORM_BESZEL_PORT PLATFORM_KIND

exec ruby "$runtime_program" "$mode" </dev/null
