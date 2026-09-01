#!/bin/sh
set -eu
set +x

mode=${1:-run}
# Two roots, deliberately separate. $contract_repo_dir is the checkout this
# script belongs to, which is where its two Ruby programs live; $repo_dir is the
# tree those programs inspect, and a caller may point that at a fixture
# repository instead. A heredoc kept the two apart by construction -- the program
# travelled inside this file -- so resolving a sibling program from $repo_dir
# would silently make the contract read its assertions out of the tree it is
# judging. Only the program paths below move to $contract_repo_dir: every other
# use of $repo_dir here, PLATFORM_CONTRACT_REPO_DIR and PLATFORM_REPO_ROOT
# included, names the inspected tree on purpose.
contract_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$contract_repo_dir}
# Both programs read tests/policy_support.rb from here instead of carrying their
# own copy of flatten_tasks, and it is the inspected tree's copy they must read.
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_REPO_DIR
compose=$repo_dir/services/audiobookshelf/compose.yml
mac_compose=$repo_dir/services/audiobookshelf/compose.mac.yml
role=$repo_dir/roles/audiobookshelf/tasks/main.yml
defaults=$repo_dir/roles/audiobookshelf/defaults/main.yml
argument_specs=$repo_dir/roles/audiobookshelf/meta/argument_specs.yml
environment_template=$repo_dir/roles/audiobookshelf/templates/env.j2
integration=$repo_dir/tests/integration.sh
storage_inventory=$repo_dir/inventory/group_vars/all/main.yml
# The static half reads the runtime half's source for its drift-commit
# branch. That source was this file; it is audiobookshelf-runtime.rb now, and
# it is the *inspected* tree's copy that has to be read.
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

# The 217-line Ruby program this used to pipe in from a quoted heredoc is now
# audiobookshelf-static.rb, where sh -n, a linter and
# tests/audiobookshelf_contract_test.rb can all reach it. The -ryaml preload
# moves verbatim -- the program never requires yaml itself. Its stdin was that
# heredoc, exhausted by the time the program ran; keep stdin at end-of-file so
# it can never consume the caller's.
ruby -ryaml "$contract_repo_dir/tests/contracts/audiobookshelf-static.rb" \
  "$compose" "$mac_compose" "$role" "$defaults" \
  "$argument_specs" "$environment_template" "$integration" "$storage_inventory" \
  "$runtime_source" "$mode" </dev/null

[ "$mode" = static ] && { printf '%s\n' 'Audiobookshelf static contract passed'; exit 0; }

: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_MEDIA_ROOT:?}"
: "${PLATFORM_REPORT_ROOT:?}"
: "${PLATFORM_AUDIOBOOKSHELF_PORT:=13378}"
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_MEDIA_ROOT PLATFORM_REPORT_ROOT PLATFORM_AUDIOBOOKSHELF_PORT
PLATFORM_REPO_ROOT=$repo_dir
export PLATFORM_REPO_ROOT

shift || true
# The 1,268-line runtime program, likewise. It takes the mode and whatever the
# caller passed after it, and reads everything else out of the environment
# exported above. The </dev/null is the same rule as the static half's.
exec ruby "$contract_repo_dir/tests/contracts/audiobookshelf-runtime.rb" \
  "$mode" "$@" </dev/null
