#!/bin/sh
set -eu
set +x

mode=${1:-run}
# Two roots, and they are not the same thing. $contract_repo_dir is the checkout
# this script belongs to, which is where its two Ruby programs live -- a heredoc
# had that property by construction, because the program travelled inside the
# file. $repo_dir is the tree those programs *inspect*, which
# PLATFORM_CONTRACT_REPO_DIR lets a caller point at a fixture. Resolving a
# program from $repo_dir would make this contract read its own assertions out of
# the tree it is judging.
contract_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$contract_repo_dir}
static_program=$contract_repo_dir/tests/contracts/komga-static.rb
runtime_program=$contract_repo_dir/tests/contracts/komga-runtime.rb
# The static program reads tests/policy_support.rb from the INSPECTED tree
# instead of carrying its own copy of flatten_tasks, so this export stays
# bound to $repo_dir rather than to the checkout. That is deliberate rather
# than an oversight of the two-roots rule above: it is the inspected tree's
# own flatten helpers that must agree with the inspected tree's task files.
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_REPO_DIR
compose=$repo_dir/services/komga/compose.yml
mac_compose=$repo_dir/services/komga/compose.mac.yml
role=$repo_dir/roles/komga/tasks/main.yml
defaults=$repo_dir/roles/komga/defaults/main.yml
argument_specs=$repo_dir/roles/komga/meta/argument_specs.yml
environment=$repo_dir/roles/komga/templates/env.j2

fail_contract() {
  printf 'Komga contract failed: %s\n' "$1" >&2
  exit 1
}

[ -f "$role" ] || fail_contract 'roles/komga/tasks/main.yml is absent'
[ -f "$defaults" ] || fail_contract 'roles/komga/defaults/main.yml is absent'
[ -f "$argument_specs" ] || fail_contract 'roles/komga/meta/argument_specs.yml is absent'
[ -f "$compose" ] || fail_contract 'services/komga/compose.yml is absent'
[ -f "$mac_compose" ] || fail_contract 'services/komga/compose.mac.yml is absent'
[ -f "$environment" ] || fail_contract 'roles/komga/templates/env.j2 is absent'
grep -qx 'FIXTURE_SCAN_TIMEOUT_SECONDS = 240' "$runtime_program" ||
  fail_contract 'fixture scan timeout differs'

ruby -ryaml "$static_program" "$compose" "$mac_compose" "$role" "$defaults" \
  "$argument_specs" "$environment" </dev/null

grep -q '^UNRELATED_LIBRARY_ROOT = "/config/\.nas-platform-unmanaged"$' "$runtime_program" ||
  fail_contract 'unrelated library fixture API root can collide with /data'
# 02d60e2 (2026-08-17) removed the unrelated-library fixture root -- a Pathname
# built from the fixture config path's environment name -- along with the
# adoption lane that seeded it, leaving two guards over a variable no code
# reads. The sibling of the one below, a plain grep for that fetch reading "$0",
# was deleted with this commit: its pattern was its own only subject, so no
# content of the contract could make it fail. This one is kept because it still
# bites -- a fallback planted in the runtime program is refused -- and it pairs
# with tests/mac/run.sh, which reserves the same variable as required-unset.
# What the deleted guard was really protecting is a platform property, not a
# fixture one: config storage must not land under the media root, or Komga's
# database ends up inside the read-only library it indexes. That is asserted in
# komga-static.rb against roles/komga/templates/env.j2, which is what decides
# the two host paths today.
if grep -E 'ENV\.fetch\("PLATFORM_KOMGA_CONFIG_PATH",[[:space:]]*MEDIA_ROOT' \
    "$runtime_program" >/dev/null; then
  fail_contract 'Komga fixture config path has an unsafe media-root fallback'
fi

[ "$mode" = static ] && { printf '%s\n' 'Komga static contract passed'; exit 0; }

: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_MEDIA_ROOT:?}"
: "${PLATFORM_REPORT_ROOT:?}"
: "${PLATFORM_KOMGA_PORT:=25600}"
: "${PLATFORM_KOMGA_FIXTURE_PRESEEDED:=false}"
if [ "${PLATFORM_KIND:-}" = integration ]; then
  : "${PLATFORM_KOMGA_RUNTIME_CONTEXT:=base}"
  case $PLATFORM_KOMGA_RUNTIME_CONTEXT in
    base) ;;
    *) fail_contract 'integration Komga runtime context differs' ;;
  esac
elif [ -z "${PLATFORM_KOMGA_RUNTIME_CONTEXT:-}" ]; then
  PLATFORM_KOMGA_RUNTIME_CONTEXT=base
fi
# Disposable lanes deploy Komga under a project namespace and name the container
# after it; production leaves the namespace empty and keeps the canonical Compose
# name.
case $PLATFORM_KOMGA_RUNTIME_CONTEXT in
  base)
    PLATFORM_KOMGA_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}komga
    PLATFORM_KOMGA_DOCKER_HEALTH_REQUIRED=true
    ;;
  mac-managed)
    : "${PLATFORM_PROJECT_NAME:?PLATFORM_PROJECT_NAME is required for managed Mac Komga}"
    PLATFORM_KOMGA_CONTAINER=$PLATFORM_PROJECT_NAME-komga
    PLATFORM_KOMGA_DOCKER_HEALTH_REQUIRED=true
    ;;
  *) fail_contract 'Komga runtime context is invalid' ;;
esac
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_MEDIA_ROOT PLATFORM_REPORT_ROOT PLATFORM_KOMGA_PORT
export PLATFORM_KOMGA_FIXTURE_PRESEEDED PLATFORM_KOMGA_CONTAINER
export PLATFORM_KOMGA_DOCKER_HEALTH_REQUIRED

shift || true
exec ruby "$runtime_program" "$mode" "$@" </dev/null
