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

  mac_container_ids=$(for mac_service_project in "$mac_project-beszel" "$mac_project-ntfy"; do
    docker ps -aq --filter "label=com.docker.compose.project=$mac_service_project" || exit 1
  done) || return 1
  for mac_container_id in $mac_container_ids; do
    docker rm -f "$mac_container_id" >/dev/null || return 1
  done
  mac_network_ids=$(for mac_service_project in "$mac_project-beszel" "$mac_project-ntfy"; do
    docker network ls -q --filter "label=com.docker.compose.project=$mac_service_project" || exit 1
  done) || return 1
  for mac_network_id in $mac_network_ids; do
    docker network rm "$mac_network_id" >/dev/null || return 1
  done
  mac_volume_ids=$(for mac_service_project in "$mac_project-beszel" "$mac_project-ntfy"; do
    docker volume ls -q --filter "label=com.docker.compose.project=$mac_service_project" || exit 1
  done) || return 1
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

force_final_rmdir_failure() {
  mac_failure_parent=$1
  mac_failure_name=$2
  mac_failure_preserve=$3
  mac_failure_program=$(mktemp "$mac_failure_parent/mac-cleanup-program.XXXXXX") || return 1
  cleanup_sandbox_program > "$mac_failure_program"
  mac_failure_program_name=$(basename -- "$mac_failure_program")

  docker run --rm -i -v "$mac_failure_parent:/sandbox-parent" \
    "$cleanup_sandbox_image" python - "$mac_failure_name" \
    "$mac_failure_preserve" "$mac_failure_program_name" <<'PY'
import errno
import os
import sys


name = sys.argv[1]
preserve = sys.argv[2]
program = sys.argv[3]
real_rmdir = os.rmdir
forced = False


def fail_final_rmdir(path, *args, **kwargs):
    global forced
    if not forced and path == name and kwargs.get("dir_fd") is not None:
        forced = True
        raise OSError(errno.ENOTEMPTY, "forced final rmdir failure", path)
    return real_rmdir(path, *args, **kwargs)


os.rmdir = fail_final_rmdir
sys.argv = [program, name, preserve]
try:
    with open(f"/sandbox-parent/{program}", encoding="utf-8") as source:
        exec(compile(source.read(), program, "exec"))
except OSError as error:
    if not forced or error.errno != errno.ENOTEMPTY:
        raise
    sys.exit(42)
raise RuntimeError("forced final rmdir was not reached")
PY
  mac_failure_status=$?
  rm -f -- "$mac_failure_program"
  return "$mac_failure_status"
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
  mac_project_suffix=$(printf '%s' "$mac_suffix" | tr '[:upper:]' '[:lower:]')
  printf 'schema=1\nproject=nas-platform-mac-%s\n' "$mac_project_suffix" \
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
  mac_marker_copy=$(mktemp "$mac_test_parent/mac-cleanup-marker.XXXXXX")
  cp -p "$mac_owned/.nas-platform-mac-owned" "$mac_marker_copy"
  mac_marker_mode=$(mac_file_mode "$mac_owned/.nas-platform-mac-owned")
  mac_marker_uid=$(mac_owner_id "$mac_owned/.nas-platform-mac-owned")
  case $(uname -s) in
    Darwin) mac_marker_gid=$(stat -f '%g' "$mac_owned/.nas-platform-mac-owned") ;;
    *) mac_marker_gid=$(stat -c '%g' "$mac_owned/.nas-platform-mac-owned") ;;
  esac
  printf 'payload removed before final rmdir\n' > "$mac_owned/payload"
  if force_final_rmdir_failure "$mac_test_parent" "$(basename -- "$mac_owned")" \
      ".nas-platform-mac-owned" >/dev/null 2>&1; then
    mac_forced_status=0
  else
    mac_forced_status=$?
  fi
  [ "$mac_forced_status" -eq 42 ] || {
    printf 'cleanup self-test did not authenticate final rmdir failure\n' >&2
    exit 1
  }
  [ ! -e "$mac_owned/payload" ] && [ ! -L "$mac_owned/payload" ] || {
    printf 'cleanup self-test failed before clearing sandbox payload\n' >&2
    exit 1
  }
  [ -d "$mac_owned" ] && [ ! -L "$mac_owned" ] || {
    printf 'cleanup self-test did not preserve sandbox after final rmdir failure\n' >&2
    exit 1
  }
  cmp -s "$mac_marker_copy" "$mac_owned/.nas-platform-mac-owned" || {
    printf 'cleanup self-test did not restore exact marker bytes\n' >&2
    exit 1
  }
  [ "$(mac_file_mode "$mac_owned/.nas-platform-mac-owned")" = "$mac_marker_mode" ] &&
    [ "$(mac_owner_id "$mac_owned/.nas-platform-mac-owned")" = "$mac_marker_uid" ] || {
      printf 'cleanup self-test did not restore marker mode and uid\n' >&2
      exit 1
    }
  case $(uname -s) in
    Darwin) mac_restored_gid=$(stat -f '%g' "$mac_owned/.nas-platform-mac-owned") ;;
    *) mac_restored_gid=$(stat -c '%g' "$mac_owned/.nas-platform-mac-owned") ;;
  esac
  [ "$mac_restored_gid" = "$mac_marker_gid" ] || {
    printf 'cleanup self-test did not restore marker gid\n' >&2
    exit 1
  }
  "$0" "$mac_owned"
  [ ! -e "$mac_owned" ] && [ ! -L "$mac_owned" ] || {
    printf 'cleanup self-test could not clean recovered sandbox\n' >&2
    exit 1
  }
  rm -f -- "$mac_alias" "$mac_marker_copy"
  rmdir -- "$mac_arbitrary"
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
