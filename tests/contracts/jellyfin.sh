#!/bin/sh
set -eu
set +x

# $contract_repo_dir holds this script's programs; $repo_dir is the tree they inspect.
# Only the two program paths use $contract_repo_dir.
contract_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$contract_repo_dir}
# jellyfin-static.rb reads tests/policy_support.rb from the inspected tree.
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_REPO_DIR
compose=$repo_dir/services/jellyfin/compose.yml
role=$repo_dir/roles/jellyfin/tasks/main.yml
defaults=$repo_dir/roles/jellyfin/defaults/main.yml
avatar=$repo_dir/roles/jellyfin/files/yonatan-avatar.jpeg
argument_specs=$repo_dir/roles/jellyfin/meta/argument_specs.yml
environment_template=$repo_dir/roles/jellyfin/templates/env.j2

fail_contract() {
  printf 'Jellyfin contract failed: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf '%s\n' 'usage: jellyfin.sh [--platform mac|nas|integration] [MODE]' >&2
  exit 2
}

# Defaults to the contract environment ABI so the integration lane needs no argument.
platform=${PLATFORM_KIND:-nas}
mode=
while [ "$#" -gt 0 ]; do
  case $1 in
    --platform)
      [ "$#" -ge 2 ] || usage
      platform=$2
      shift 2
      ;;
    --) shift; break ;;
    -*) usage ;;
    *) mode=$1; shift; break ;;
  esac
done
: "${mode:=run}"
case $platform in
  mac|nas|integration) ;;
  *) fail_contract "unknown platform: $platform" ;;
esac

[ -f "$role" ] || fail_contract 'roles/jellyfin/tasks/main.yml is absent'
[ -f "$defaults" ] || fail_contract 'roles/jellyfin/defaults/main.yml is absent'
[ -f "$compose" ] || fail_contract 'services/jellyfin/compose.yml is absent'
[ -f "$avatar" ] || fail_contract 'approved administrator avatar is absent'

# Both -r preloads are required (#147). stdin stays at end-of-file so the program can
# never consume the caller's.
ruby -ryaml -rdigest "$contract_repo_dir/tests/contracts/jellyfin-static.rb" \
  "$repo_dir" "$platform" </dev/null

[ "$mode" = static ] && exit 0
: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_MEDIA_ROOT:?}"
: "${PLATFORM_DOCKER_ROOT:?}"
: "${PLATFORM_REPORT_ROOT:?}"
: "${PLATFORM_JELLYFIN_PORT:=8096}"
: "${PLATFORM_JELLYFIN_FIXTURE_PRESEEDED:=false}"
if [ -z "${PLATFORM_JELLYFIN_CONTAINER:-}" ]; then
  PLATFORM_JELLYFIN_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}jellyfin
fi
PLATFORM_JELLYFIN_PLATFORM=$platform
PLATFORM_JELLYFIN_AVATAR_PATH=$avatar
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_MEDIA_ROOT PLATFORM_DOCKER_ROOT PLATFORM_REPORT_ROOT
export PLATFORM_JELLYFIN_PORT PLATFORM_JELLYFIN_CONTAINER PLATFORM_JELLYFIN_PLATFORM
export PLATFORM_JELLYFIN_AVATAR_PATH
export PLATFORM_JELLYFIN_FIXTURE_PRESEEDED

# No -r preloads here: the runtime program requires what it uses.
exec ruby "$contract_repo_dir/tests/contracts/jellyfin-runtime.rb" \
  "$mode" "$@" </dev/null
