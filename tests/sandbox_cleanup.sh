#!/bin/sh

cleanup_sandbox_image=docker.io/library/python:3.14-alpine@sha256:05b2b8b732ecd268fee8727a369f936f022d1321b59befd13c30ede22769dcdc

cleanup_sandbox_program() {
  cat <<'PY'
import os
import re
import stat
import sys


name = sys.argv[1]
preserve = sys.argv[2]
supported_names = (
    r"nas-platform-integration\.[A-Za-z0-9]{6}",
    r"nas-platform-cleanup\.[A-Za-z0-9]{6}",
    r"nas-platform-mac\.[A-Za-z0-9]{6}",
    r"nas-platform-mac\.[A-Za-z0-9]{6}\.reports",
)
if not any(re.fullmatch(pattern, name) for pattern in supported_names):
    raise ValueError("invalid sandbox basename")
if preserve and not (
    (re.fullmatch(r"nas-platform-mac\.[A-Za-z0-9]{6}", name)
     and preserve == ".nas-platform-mac-owned")
    or (re.fullmatch(r"nas-platform-mac\.[A-Za-z0-9]{6}\.reports", name)
        and preserve == ".nas-platform-mac-report-owned")
):
    raise ValueError("invalid preserved marker")

open_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def clear_directory(directory_fd, preserved_entry=""):
    for entry in os.listdir(directory_fd):
        if entry == preserved_entry:
            continue
        entry_stat = os.stat(
            entry, dir_fd=directory_fd, follow_symlinks=False
        )
        if stat.S_ISDIR(entry_stat.st_mode):
            child_fd = os.open(entry, open_flags, dir_fd=directory_fd)
            try:
                clear_directory(child_fd)
            finally:
                os.close(child_fd)
            os.rmdir(entry, dir_fd=directory_fd)
        else:
            os.unlink(entry, dir_fd=directory_fd)


parent_fd = os.open("/sandbox-parent", open_flags)
try:
    sandbox_fd = os.open(name, open_flags, dir_fd=parent_fd)
    try:
        if preserve:
            marker_fd = os.open(preserve, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=sandbox_fd)
            try:
                marker_stat = os.fstat(marker_fd)
                if not stat.S_ISREG(marker_stat.st_mode):
                    raise ValueError("preserved marker is not regular")
                marker_data = os.read(marker_fd, 4097)
                if len(marker_data) > 4096:
                    raise ValueError("preserved marker is unexpectedly large")
            finally:
                os.close(marker_fd)

            clear_directory(sandbox_fd, preserve)
            os.unlink(preserve, dir_fd=sandbox_fd)
            try:
                os.rmdir(name, dir_fd=parent_fd)
            except OSError:
                recovery_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
                recovery_fd = os.open(
                    preserve,
                    recovery_flags,
                    stat.S_IMODE(marker_stat.st_mode),
                    dir_fd=sandbox_fd,
                )
                try:
                    os.write(recovery_fd, marker_data)
                    os.fchmod(recovery_fd, stat.S_IMODE(marker_stat.st_mode))
                    os.fchown(recovery_fd, marker_stat.st_uid, marker_stat.st_gid)
                finally:
                    os.close(recovery_fd)
                raise
        else:
            clear_directory(sandbox_fd)
    finally:
        os.close(sandbox_fd)
finally:
    os.close(parent_fd)
PY
}

cleanup_sandbox_contents() {
  cleanup_contents_parent=$1
  cleanup_contents_name=$2
  cleanup_contents_preserve=${3-}

  cleanup_sandbox_program | docker run --rm -i \
    -v "$cleanup_contents_parent:/sandbox-parent" "$cleanup_sandbox_image" \
    python - "$cleanup_contents_name" "$cleanup_contents_preserve"
}

cleanup_sandbox() {
  cleanup_sandbox_path=${1-}
  cleanup_temporary_parent=${TMPDIR:-/tmp}

  case "$cleanup_sandbox_path" in
    /*) ;;
    *)
      printf 'refusing to remove unexpected sandbox path: %s\n' "$cleanup_sandbox_path" >&2
      return 1
      ;;
  esac

  cleanup_sandbox_parent=${cleanup_sandbox_path%/*}
  cleanup_sandbox_name=${cleanup_sandbox_path##*/}

  cleanup_expected_parent=$(CDPATH= cd -P "$cleanup_temporary_parent" 2>/dev/null && pwd -P) || return 1
  cleanup_actual_parent=$(CDPATH= cd -P "$cleanup_sandbox_parent" 2>/dev/null && pwd -P) || cleanup_actual_parent=

  case "$cleanup_sandbox_name" in
    nas-platform-integration.??????|nas-platform-cleanup.??????) ;;
    *) cleanup_actual_parent= ;;
  esac
  cleanup_sandbox_suffix=${cleanup_sandbox_name##*.}
  case "$cleanup_sandbox_suffix" in
    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789]*) cleanup_actual_parent= ;;
  esac

  cleanup_sandbox_target=$cleanup_expected_parent/$cleanup_sandbox_name

  if [ -z "$cleanup_sandbox_path" ] ||
     [ "$cleanup_actual_parent" != "$cleanup_expected_parent" ] ||
     [ ! -d "$cleanup_sandbox_target" ] ||
     [ -L "$cleanup_sandbox_target" ]; then
    printf 'refusing to remove unexpected sandbox path: %s\n' "$cleanup_sandbox_path" >&2
    return 1
  fi

  for cleanup_container in ntfy beszel beszel_agent beszel_agent_portable beszel_socket_proxy \
      dozzle_alert_relay dozzle dozzle_socket_proxy audiobookshelf komga jellyfin \
      immich_server immich_machine_learning immich_redis immich_postgres \
      paperless_redis paperless_postgres paperless_webserver paperless_gotenberg paperless_tika; do
    cleanup_container_ids=$(docker ps -aq --filter "name=^${cleanup_container}$") || return 1
    for cleanup_container_id in $cleanup_container_ids; do
      docker rm -f "$cleanup_container_id" >/dev/null || return 1
    done
  done

  if [ ! -d "$cleanup_sandbox_target" ] || [ -L "$cleanup_sandbox_target" ]; then
    printf 'refusing to remove unexpected sandbox path: %s\n' "$cleanup_sandbox_path" >&2
    return 1
  fi

  cleanup_sandbox_contents "$cleanup_expected_parent" "$cleanup_sandbox_name" || return 1
  rmdir "$cleanup_sandbox_target"
}

cleanup_sandbox_on_exit() {
  cleanup_exit_path=$1
  cleanup_exit_status=$2
  trap - EXIT HUP INT TERM
  if ! cleanup_sandbox "$cleanup_exit_path"; then
    [ "$cleanup_exit_status" -ne 0 ] || cleanup_exit_status=1
  fi
  exit "$cleanup_exit_status"
}
