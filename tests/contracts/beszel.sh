#!/bin/sh
set -eu
set +x
umask 077

mode=${1:-verify}
case $mode in static|telemetry-fixtures|verify|drift|drift-verify|duplicate|wrong-owner|remove-duplicate|notify) ;; *) exit 2 ;; esac

# Two roots, and they are not the same thing. $contract_repo_dir is the checkout
# this script belongs to, which is where its three Ruby programs live -- a
# heredoc had that property by construction, because the program travelled
# inside the file. $repo_dir is the tree those programs *inspect*, which
# PLATFORM_CONTRACT_REPO_DIR lets a caller point at a fixture. Resolving a
# program from $repo_dir would make this contract read its own assertions out of
# the tree it is judging.
contract_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$contract_repo_dir}
static_program=$contract_repo_dir/tests/contracts/beszel-static.rb
telemetry_fixtures_program=$contract_repo_dir/tests/contracts/beszel-telemetry-fixtures.rb
runtime_program=$contract_repo_dir/tests/contracts/beszel-runtime.rb
# beszel-static.rb reads tests/policy_support.rb from the INSPECTED tree
# instead of carrying its own copy of flatten_tasks, and beszel-runtime.rb
# requires the shared telemetry evaluator from there too -- past its exec. So
# this export stays bound to $repo_dir rather than to the checkout. That is
# deliberate rather than an oversight of the two-roots rule above: it is the
# inspected tree's own helpers that must agree with the inspected tree's files.
# Both assignment/export pairs below are transcribed verbatim; the second is
# redundant, and deduping it is a behaviour-preserving change that does not
# belong in this one.
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
: "${PLATFORM_NTFY_PORT:=2586}"
: "${PLATFORM_KIND:=nas}"
export PLATFORM_BESZEL_PORT PLATFORM_NTFY_PORT PLATFORM_KIND

exec ruby "$runtime_program" "$mode" </dev/null
