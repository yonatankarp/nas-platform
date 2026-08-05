#!/bin/sh

cleanup_sandbox_contents() {
  cleanup_contents_parent=$1
  cleanup_contents_name=$2
  cleanup_image=docker.io/library/python:3.13-alpine@sha256:399babc8b49529dabfd9c922f2b5eea81d611e4512e3ed250d75bd2e7683f4b0

  docker run --rm -i -v "$cleanup_contents_parent:/sandbox-parent" "$cleanup_image" \
    python - "$cleanup_contents_name" <<'PY'
import os
import re
import stat
import sys


name = sys.argv[1]
supported_names = (
    r"nas-platform-integration\.[A-Za-z0-9]{6}",
    r"nas-platform-cleanup\.[A-Za-z0-9]{6}",
)
if not any(re.fullmatch(pattern, name) for pattern in supported_names):
    raise ValueError("invalid sandbox basename")

open_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def clear_directory(directory_fd):
    for entry in os.listdir(directory_fd):
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
        clear_directory(sandbox_fd)
    finally:
        os.close(sandbox_fd)
finally:
    os.close(parent_fd)
PY
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

  for cleanup_container in ntfy beszel beszel_agent beszel_socket_proxy; do
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
