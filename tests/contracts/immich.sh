#!/bin/sh
set -eu
set +x

# Programs come from this checkout; $repo_dir is the tree they inspect.
# Never resolve a program from $repo_dir, or the contract judges itself.
contract_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$contract_repo_dir}
compose=$repo_dir/services/immich/compose.yml
role=$repo_dir/roles/immich/tasks/main.yml
user_onboarding_role=$repo_dir/roles/immich/tasks/user_onboarding.yml
configured_password_role=$repo_dir/roles/immich/tasks/configured_password.yml
defaults=$repo_dir/roles/immich/defaults/main.yml

fail_contract() {
  printf 'Immich contract failed: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf '%s\n' 'usage: immich.sh [--platform mac|nas|integration] [MODE]' >&2
  exit 2
}

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

[ -f "$role" ] || fail_contract 'roles/immich/tasks/main.yml is absent'
[ -f "$user_onboarding_role" ] ||
  fail_contract 'roles/immich/tasks/user_onboarding.yml is absent'
[ -f "$configured_password_role" ] ||
  fail_contract 'roles/immich/tasks/configured_password.yml is absent'
[ -f "$defaults" ] || fail_contract 'roles/immich/defaults/main.yml is absent'
[ -f "$compose" ] || fail_contract 'services/immich/compose.yml is absent'

# -ryaml is required (the program does not require yaml itself); stdin stays at
# EOF so it can never consume the caller's.
ruby -ryaml "$contract_repo_dir/tests/contracts/immich-static.rb" \
  "$repo_dir" "$platform" </dev/null

[ "$mode" = static ] && exit 0

: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_MEDIA_ROOT:?PLATFORM_MEDIA_ROOT is required}"
: "${PLATFORM_DOCKER_ROOT:?PLATFORM_DOCKER_ROOT is required}"
: "${PLATFORM_REPORT_ROOT:?PLATFORM_REPORT_ROOT is required}"
: "${PLATFORM_IMMICH_PORT:=2283}"
: "${PLATFORM_IMMICH_SERVER_CONTAINER:=immich_server}"
: "${PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER:=immich_machine_learning}"
: "${PLATFORM_IMMICH_REDIS_CONTAINER:=immich_redis}"
: "${PLATFORM_IMMICH_POSTGRES_CONTAINER:=immich_postgres}"
PLATFORM_IMMICH_PLATFORM=$platform
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_CONTRACT_REPO_DIR
export PLATFORM_MEDIA_ROOT PLATFORM_DOCKER_ROOT PLATFORM_REPORT_ROOT
export PLATFORM_IMMICH_PORT PLATFORM_IMMICH_PLATFORM
export PLATFORM_IMMICH_SERVER_CONTAINER PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER
export PLATFORM_IMMICH_REDIS_CONTAINER PLATFORM_IMMICH_POSTGRES_CONTAINER

# REPO_DIR is bound to $repo_dir on purpose: the runtime half inspects that tree too.
exec ruby "$contract_repo_dir/tests/contracts/immich-runtime.rb" "$mode" "$@" </dev/null
