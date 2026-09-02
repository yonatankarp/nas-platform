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

fail_contract() {
  printf 'Komga contract failed: %s\n' "$1" >&2
  exit 1
}

[ -f "$role" ] || fail_contract 'roles/komga/tasks/main.yml is absent'
[ -f "$defaults" ] || fail_contract 'roles/komga/defaults/main.yml is absent'
[ -f "$argument_specs" ] || fail_contract 'roles/komga/meta/argument_specs.yml is absent'
[ -f "$compose" ] || fail_contract 'services/komga/compose.yml is absent'
[ -f "$mac_compose" ] || fail_contract 'services/komga/compose.mac.yml is absent'
grep -qx 'FIXTURE_SCAN_TIMEOUT_SECONDS = 240' "$runtime_program" ||
  fail_contract 'fixture scan timeout differs'

ruby -ryaml "$static_program" "$compose" "$mac_compose" "$role" "$defaults" \
  "$argument_specs" </dev/null

grep -q '^UNRELATED_LIBRARY_ROOT = "/config/\.nas-platform-unmanaged"$' "$runtime_program" ||
  fail_contract 'unrelated library fixture API root can collide with /data'
# This guard is a tautology, and has been one since 02d60e2 (2026-08-17) removed
# the unrelated-library fixture root -- a Pathname built from that environment
# name -- from the runtime half along with the adoption lane that seeded it. The
# literal now occurs nowhere in this contract but the grep line below, so the
# pattern and its only subject are the same text and no content of the contract
# can make it fail. Deliberately still reading "$0", because that is exactly
# what it does today: repointing it at the runtime program would make the
# contract refuse a clean tree, which is a repair rather than a move. The three
# greps around it have their subject in the runtime program and moved with it.
grep -F 'ENV.fetch("PLATFORM_KOMGA_CONFIG_PATH")' "$0" >/dev/null ||
  fail_contract 'Komga fixture config path must be explicit'
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
