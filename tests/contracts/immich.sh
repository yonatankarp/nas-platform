#!/bin/sh
set -eu
set +x

# Two roots, deliberately separate. The checkout this script belongs to is where
# its two Ruby programs live; $repo_dir is the tree they inspect, and a caller
# may point PLATFORM_CONTRACT_REPO_DIR at a fixture repository instead. A
# heredoc kept the two apart by construction -- the program travelled inside
# this file -- so resolving the sibling programs from $repo_dir would silently
# make a contract read its assertions out of the tree it is judging.
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

# The platform decides which capability contract applies. It defaults to the
# contract environment ABI so the integration lane needs no extra argument.
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

# The 936-line Ruby program this used to pipe in from a quoted heredoc is now
# immich-static.rb, where sh -n, a linter and tests/immich_contract_test.rb can
# all reach it. Three things about this invocation are load-bearing:
#
#   * The program comes from $contract_repo_dir and the tree to inspect is an
#     argument. Resolving the program from $repo_dir would make the contract read
#     its own assertions out of the tree it is judging.
#   * -ryaml is the heredoc's own preload, carried verbatim. The program does not
#     require yaml itself, so dropping this breaks it.
#   * Its stdin was that heredoc, exhausted by the time the program ran; keep
#     stdin at end-of-file so it can never consume the caller's.
ruby -ryaml "$contract_repo_dir/tests/contracts/immich-static.rb" \
  "$repo_dir" "$platform" </dev/null

[ "$mode" = static ] && exit 0

: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_MEDIA_ROOT:?}"
: "${PLATFORM_DOCKER_ROOT:?}"
: "${PLATFORM_REPORT_ROOT:?}"
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

# immich-runtime.rb takes the mode and passes through any remaining arguments,
# exactly as the heredoc did; everything else is the environment exported above,
# PLATFORM_CONTRACT_REPO_DIR included, which it reads as REPO_DIR. That variable
# is bound to $repo_dir rather than $contract_repo_dir on purpose: the runtime
# half inspects the deployed tree too, and pointing it at this checkout would be
# the same defect as resolving the program from $repo_dir, one line over. The
# heredoc carried no -r preloads, so neither does this. The </dev/null is the
# same rule as above.
exec ruby "$contract_repo_dir/tests/contracts/immich-runtime.rb" "$mode" "$@" </dev/null
