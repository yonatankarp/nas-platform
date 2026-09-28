#!/bin/sh
set -eu
set +x

mode=${1:-run}
# Programs come from this checkout; $repo_dir is the tree they inspect.
# Never resolve a program from $repo_dir, or the contract judges itself; every
# other $repo_dir use names the inspected tree on purpose.
contract_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$contract_repo_dir}
# The inspected tree's policy_support.rb, deliberately.
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_REPO_DIR
compose=$repo_dir/services/audiobookshelf/compose.yml
mac_compose=$repo_dir/services/audiobookshelf/compose.mac.yml
role=$repo_dir/roles/audiobookshelf/tasks/main.yml
defaults=$repo_dir/roles/audiobookshelf/defaults/main.yml
argument_specs=$repo_dir/roles/audiobookshelf/meta/argument_specs.yml
environment_template=$repo_dir/roles/audiobookshelf/templates/env.j2
# The scenario markers are spelled in the controller, not the launcher.
integration=$repo_dir/tests/integration_controller.sh
storage_inventory=$repo_dir/inventory/group_vars/all/service_audiobookshelf.yml
# The inspected tree's runtime source, read for its drift-commit branch.
runtime_source=$repo_dir/tests/contracts/audiobookshelf-runtime.rb

fail_contract() {
  printf 'Audiobookshelf contract failed: %s\n' "$1" >&2
  exit 1
}

[ -f "$role" ] || fail_contract 'roles/audiobookshelf/tasks/main.yml is absent'
[ -f "$defaults" ] || fail_contract 'roles/audiobookshelf/defaults/main.yml is absent'
[ -f "$compose" ] || fail_contract 'services/audiobookshelf/compose.yml is absent'
[ -f "$mac_compose" ] || fail_contract 'services/audiobookshelf/compose.mac.yml is absent'
[ -f "$argument_specs" ] || fail_contract 'roles/audiobookshelf/meta/argument_specs.yml is absent'
[ -f "$environment_template" ] || fail_contract 'roles/audiobookshelf/templates/env.j2 is absent'

# -ryaml is required (the program does not require yaml itself); stdin stays at
# EOF so it can never consume the caller's.
ruby -ryaml "$contract_repo_dir/tests/contracts/audiobookshelf-static.rb" \
  "$compose" "$mac_compose" "$role" "$defaults" \
  "$argument_specs" "$environment_template" "$integration" "$storage_inventory" \
  "$runtime_source" "$mode" </dev/null

[ "$mode" = static ] && { printf '%s\n' 'Audiobookshelf static contract passed'; exit 0; }

: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_MEDIA_ROOT:?PLATFORM_MEDIA_ROOT is required}"
: "${PLATFORM_REPORT_ROOT:?PLATFORM_REPORT_ROOT is required}"
: "${PLATFORM_AUDIOBOOKSHELF_PORT:=13378}"
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_MEDIA_ROOT PLATFORM_REPORT_ROOT PLATFORM_AUDIOBOOKSHELF_PORT
PLATFORM_REPO_ROOT=$repo_dir
export PLATFORM_REPO_ROOT

shift || true
exec ruby "$contract_repo_dir/tests/contracts/audiobookshelf-runtime.rb" \
  "$mode" "$@" </dev/null
