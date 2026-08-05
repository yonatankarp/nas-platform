#!/bin/sh
set -eu
set +x

mac_script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"
. "$mac_repo_dir/tests/sandbox_cleanup.sh"
. "$mac_repo_dir/tests/integration_lock.sh"

cleanup_mac_sandbox() {
  mac_cleanup_target=$(mac_validate_sandbox "$1") || return 1
  mac_marker=$mac_cleanup_target/.nas-platform-mac-owned
  mac_project=$(sed -n 's/^project=//p' "$mac_marker")

  mac_container_ids=$(docker ps -aq \
    --filter "label=com.docker.compose.project=$mac_project") || return 1
  for mac_container_id in $mac_container_ids; do
    docker rm -f "$mac_container_id" >/dev/null || return 1
  done
  mac_network_ids=$(docker network ls -q \
    --filter "label=com.docker.compose.project=$mac_project") || return 1
  for mac_network_id in $mac_network_ids; do
    docker network rm "$mac_network_id" >/dev/null || return 1
  done
  mac_volume_ids=$(docker volume ls -q \
    --filter "label=com.docker.compose.project=$mac_project") || return 1
  for mac_volume_id in $mac_volume_ids; do
    docker volume rm "$mac_volume_id" >/dev/null || return 1
  done

  # Revalidate immediately before the descriptor-relative removal. The shared
  # helper opens both parent and children with O_NOFOLLOW inside the pinned
  # cleanup image, so a concurrent symlink swap cannot redirect traversal.
  [ "$(mac_validate_sandbox "$mac_cleanup_target")" = "$mac_cleanup_target" ] || return 1
  cleanup_sandbox_contents "$(dirname -- "$mac_cleanup_target")" \
    "$(basename -- "$mac_cleanup_target")" ".nas-platform-mac-owned" || return 1
  [ ! -e "$mac_cleanup_target" ] && [ ! -L "$mac_cleanup_target" ]
}

cleanup_self_test() {
  mac_test_parent=$(mac_temporary_parent)
  mac_repo_root=$(CDPATH= cd -- "$mac_repo_dir" && pwd -P)
  mac_arbitrary=$(mktemp -d "$mac_test_parent/mac-cleanup-arbitrary.XXXXXX")
  chmod 0700 "$mac_arbitrary"
  mac_unmarked=$(mktemp -d "$mac_test_parent/nas-platform-mac.XXXXXX")
  chmod 0700 "$mac_unmarked"

  for mac_unsafe in '' / "$mac_repo_root" "$mac_arbitrary" "$mac_unmarked"; do
    if "$0" "$mac_unsafe" >/dev/null 2>&1; then
      printf 'cleanup self-test accepted unsafe path: %s\n' "$mac_unsafe" >&2
      exit 1
    fi
    [ -z "$mac_unsafe" ] || [ -e "$mac_unsafe" ] || {
      printf 'cleanup self-test mutated refused target: %s\n' "$mac_unsafe" >&2
      exit 1
    }
  done
  rmdir -- "$mac_unmarked"

  mac_owned=$(mktemp -d "$mac_test_parent/nas-platform-mac.XXXXXX")
  chmod 0700 "$mac_owned"
  mac_suffix=${mac_owned##*.}
  printf 'schema=1\nproject=nas-platform-mac-%s\n' "$mac_suffix" \
    > "$mac_owned/.nas-platform-mac-owned"
  chmod 0600 "$mac_owned/.nas-platform-mac-owned"
  mac_alias="$mac_test_parent/nas-platform-mac.alias.$$"
  ln -s "$mac_owned" "$mac_alias"
  for mac_unsafe in "$mac_alias" "$mac_alias/" "$mac_owned/." \
    "$mac_test_parent//$(basename -- "$mac_owned")"; do
    if "$0" "$mac_unsafe" >/dev/null 2>&1; then
      printf 'cleanup self-test accepted alias: %s\n' "$mac_unsafe" >&2
      exit 1
    fi
    [ -d "$mac_owned" ] || {
      printf 'cleanup self-test did not preserve alias target\n' >&2
      exit 1
    }
  done
  chmod 0644 "$mac_owned/.nas-platform-mac-owned"
  if "$0" "$mac_owned" >/dev/null 2>&1; then
    printf 'cleanup self-test accepted an unsafe marker mode\n' >&2
    exit 1
  fi
  [ -d "$mac_owned" ] || {
    printf 'cleanup self-test did not preserve unsafe-marker target\n' >&2
    exit 1
  }
  chmod 0600 "$mac_owned/.nas-platform-mac-owned"
  rm -f -- "$mac_alias" "$mac_owned/.nas-platform-mac-owned"
  rmdir -- "$mac_owned" "$mac_arbitrary"
  printf 'cleanup: all safety properties hold\n'
}

cleanup_lock_held=false
release_cleanup_lock_on_exit() {
  mac_cleanup_exit_status=$?
  trap - EXIT HUP INT TERM
  if [ "$cleanup_lock_held" = true ] && ! release_integration_lock; then
    [ "$mac_cleanup_exit_status" -ne 0 ] || mac_cleanup_exit_status=1
  fi
  exit "$mac_cleanup_exit_status"
}

cleanup_with_lock() {
  mac_cleanup_validated=$(mac_validate_sandbox "$1") || return 1
  mac_cleanup_parent=$(dirname -- "$mac_cleanup_validated")
  acquire_integration_lock "$mac_cleanup_parent" || return 1
  cleanup_lock_held=true
  trap release_cleanup_lock_on_exit EXIT
  trap 'exit 130' HUP INT TERM
  cleanup_mac_sandbox "$mac_cleanup_validated"
}

case ${1-} in
  --self-test)
    [ "$#" -eq 1 ] || mac_die 'usage: cleanup.sh --self-test | SANDBOX'
    cleanup_self_test
    ;;
  '') mac_die 'usage: cleanup.sh --self-test | SANDBOX' ;;
  *)
    [ "$#" -eq 1 ] || mac_die 'usage: cleanup.sh --self-test | SANDBOX'
    cleanup_with_lock "$1"
    ;;
esac
