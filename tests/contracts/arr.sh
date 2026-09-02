#!/bin/sh
set -eu
set +x

mode=${1:-static}
[ "$mode" = static ] || {
  printf '%s\n' 'arr contract accepts only static' >&2
  exit 2
}

# Two roots, and they are not the same thing. $contract_repo_dir is the checkout
# this script belongs to, which is where its Ruby program lives -- a heredoc had
# that property by construction, because the program travelled inside the file.
# $repo_dir is the tree that program *inspects*, which
# PLATFORM_CONTRACT_REPO_DIR lets a caller point at a fixture. Resolving the
# program from $repo_dir would make this contract read its own assertions out of
# the tree it is judging.
contract_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$contract_repo_dir}
static_program=$contract_repo_dir/tests/contracts/arr-static.rb
# The program reads tests/policy_support.rb from the INSPECTED tree instead of
# carrying its own copy of flatten_tasks, so this export stays bound to
# $repo_dir rather than to the checkout. That is deliberate rather than an
# oversight of the two-roots rule above: it is the inspected tree's own flatten
# helpers that must agree with the inspected tree's task files, and rerooting it
# would quietly stop a fixture from being able to break that.
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_REPO_DIR
ruby "$static_program" "$repo_dir" </dev/null
