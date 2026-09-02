#!/bin/sh
set -eu
set +x

# Two roots, deliberately separate. $contract_repo_dir is the checkout this
# script belongs to, which is where its two Ruby programs live; $repo_dir is the
# tree those programs inspect, and a caller may point that at a fixture
# repository. A heredoc kept the two apart by construction -- the program
# travelled inside this file -- so resolving a sibling program from $repo_dir
# would silently make the contract read its assertions out of the tree it is
# judging. Only the two program paths below move to $contract_repo_dir. Every
# other use of $repo_dir here, PLATFORM_CONTRACT_REPO_DIR included, names the
# inspected tree on purpose, and so does the static half's read of the runtime
# half's source.
contract_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$contract_repo_dir}
# jellyfin-static.rb reads tests/policy_support.rb from here instead of carrying
# its own copy of flatten_tasks, and it is the inspected tree's copy it must
# read.
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

[ -f "$role" ] || fail_contract 'roles/jellyfin/tasks/main.yml is absent'
[ -f "$defaults" ] || fail_contract 'roles/jellyfin/defaults/main.yml is absent'
[ -f "$compose" ] || fail_contract 'services/jellyfin/compose.yml is absent'
[ -f "$avatar" ] || fail_contract 'approved administrator avatar is absent'

# The 354-line Ruby program this used to pipe in from a quoted heredoc is now
# jellyfin-static.rb, where sh -n, a linter and
# tests/jellyfin_contract_test.rb can all reach it. Both -r preloads move
# verbatim: the program calls YAML.safe_load_file and Digest::SHA256 and
# requires neither, so run bare it raises NameError. Its stdin was that heredoc,
# exhausted by the time the program ran; keep stdin at end-of-file so it can
# never consume the caller's. It prints its own success line, so the mode guard
# below stays a bare `exit 0`.
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

# The 922-line runtime program, likewise, and with no -r preloads because the
# heredoc had none -- it requires every library it uses. It takes the mode and
# whatever the caller passed after it, and reads everything else out of the
# environment exported above. The </dev/null is the same rule as the static
# half's.
exec ruby "$contract_repo_dir/tests/contracts/jellyfin-runtime.rb" \
  "$mode" "$@" </dev/null
