#!/bin/sh

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

  cleanup_image=docker.io/library/python:3.13-alpine@sha256:399babc8b49529dabfd9c922f2b5eea81d611e4512e3ed250d75bd2e7683f4b0
  if [ ! -d "$cleanup_sandbox_target" ] || [ -L "$cleanup_sandbox_target" ]; then
    printf 'refusing to remove unexpected sandbox path: %s\n' "$cleanup_sandbox_path" >&2
    return 1
  fi

  # Bind the stable parent, then check the child without following symlinks in
  # the container. A child swapped after the host check cannot redirect the bind.
  docker run --rm -v "$cleanup_expected_parent:/sandbox-parent" "$cleanup_image" \
    sh -c '
      cleanup_target=/sandbox-parent/$1
      [ -d "$cleanup_target" ] && [ ! -L "$cleanup_target" ] || exit 1
      find "$cleanup_target" -depth -mindepth 1 -delete
    ' sh "$cleanup_sandbox_name" >/dev/null || return 1
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
