#!/bin/sh
set -eu
set +x

mode=${1:-run}
# Programs come from this checkout ($contract_repo_dir); $repo_dir is the tree
# they inspect, which PLATFORM_CONTRACT_REPO_DIR may point at a fixture.
contract_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$contract_repo_dir}
static_program=$contract_repo_dir/tests/contracts/komga-static.rb
runtime_program=$contract_repo_dir/tests/contracts/komga-runtime.rb
# Deliberately the inspected tree: its flatten helpers must match its task files.
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_REPO_DIR
compose=$repo_dir/services/komga/compose.yml
mac_compose=$repo_dir/services/komga/compose.mac.yml
role=$repo_dir/roles/komga/tasks/main.yml
defaults=$repo_dir/roles/komga/defaults/main.yml
argument_specs=$repo_dir/roles/komga/meta/argument_specs.yml
environment=$repo_dir/roles/komga/templates/env.j2
# group_vars/all outranks role defaults, so it decides whether a root may move.
inventory=$repo_dir/inventory/group_vars/all/service_komga.yml

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
[ -f "$inventory" ] || fail_contract 'inventory/group_vars/all/service_komga.yml is absent'
grep -qx 'FIXTURE_SCAN_TIMEOUT_SECONDS = 240' "$runtime_program" ||
  fail_contract 'fixture scan timeout differs'

ruby -ryaml "$static_program" "$compose" "$mac_compose" "$role" "$defaults" \
  "$argument_specs" "$environment" "$inventory" </dev/null

grep -q '^UNRELATED_LIBRARY_ROOT = "/config/\.nas-platform-unmanaged"$' "$runtime_program" ||
  fail_contract 'unrelated library fixture API root can collide with /data'
# Refuses a fallback that would put Komga's config under the media root; pairs
# with tests/mac/run.sh, which requires the variable unset.
if grep -E 'ENV\.fetch\("PLATFORM_KOMGA_CONFIG_PATH",[[:space:]]*MEDIA_ROOT' \
    "$runtime_program" >/dev/null; then
  fail_contract 'Komga fixture config path has an unsafe media-root fallback'
fi

[ "$mode" = static ] && { printf '%s\n' 'Komga static contract passed'; exit 0; }

: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_MEDIA_ROOT:?PLATFORM_MEDIA_ROOT is required}"
: "${PLATFORM_REPORT_ROOT:?PLATFORM_REPORT_ROOT is required}"
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
