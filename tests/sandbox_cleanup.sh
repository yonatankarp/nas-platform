#!/bin/sh

cleanup_sandbox() {
  cleanup_sandbox_path=${1-}
  cleanup_temporary_parent=${TMPDIR:-/tmp}
  cleanup_sandbox_parent=${cleanup_sandbox_path%/*}
  cleanup_sandbox_name=${cleanup_sandbox_path##*/}

  cleanup_expected_parent=$(CDPATH= cd -- "$cleanup_temporary_parent" 2>/dev/null && pwd -P) || return 1
  cleanup_actual_parent=$(CDPATH= cd -- "$cleanup_sandbox_parent" 2>/dev/null && pwd -P) || cleanup_actual_parent=

  case "$cleanup_sandbox_name" in
    nas-platform-?*.??????) ;;
    *) cleanup_actual_parent= ;;
  esac

  if [ -z "$cleanup_sandbox_path" ] ||
     [ "$cleanup_actual_parent" != "$cleanup_expected_parent" ] ||
     [ ! -d "$cleanup_sandbox_path" ] ||
     [ -L "$cleanup_sandbox_path" ]; then
    printf 'refusing to remove unexpected sandbox path: %s\n' "$cleanup_sandbox_path" >&2
    return 1
  fi

  for cleanup_container in ntfy beszel beszel_agent beszel_socket_proxy; do
    docker rm -f "$cleanup_container" >/dev/null 2>&1 || true
  done

  cleanup_image=docker.io/library/python:3.13-alpine@sha256:399babc8b49529dabfd9c922f2b5eea81d611e4512e3ed250d75bd2e7683f4b0
  docker run --rm -v "$cleanup_sandbox_path:/sandbox" "$cleanup_image" \
    sh -c 'find /sandbox -depth -mindepth 1 -delete' >/dev/null || return 1
  rmdir "$cleanup_sandbox_path"
}
