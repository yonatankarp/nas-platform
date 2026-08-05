#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/sandbox_cleanup.sh"

sandbox=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-cleanup.XXXXXX")
unsafe_sandbox=${TMPDIR:-/tmp}/nas-platform-cleanup.not-six-$$
other_parent=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-cleanup-parent.XXXXXX")
wrong_parent_sandbox=$other_parent/nas-platform-cleanup.ABCDEF
symlink_target=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-cleanup-target.XXXXXX")
symlink_sandbox=${TMPDIR:-/tmp}/nas-platform-cleanup-link.ABCDEF
runner_image=docker.io/library/python:3.13-alpine@sha256:399babc8b49529dabfd9c922f2b5eea81d611e4512e3ed250d75bd2e7683f4b0

assert_cleanup_rejected() {
  rejected_path=$1
  if cleanup_sandbox "$rejected_path" 2>/dev/null; then
    printf 'cleanup accepted unsafe path: %s\n' "$rejected_path" >&2
    exit 1
  fi
}

emergency_cleanup() {
  exit_status=$?
  trap - EXIT HUP INT TERM
  if [ -d "$sandbox" ]; then
    docker run --rm -v "$sandbox:/sandbox" "$runner_image" \
      sh -c 'find /sandbox -depth -mindepth 1 -delete' >/dev/null
    rmdir "$sandbox"
  fi
  [ ! -d "$unsafe_sandbox" ] || rmdir "$unsafe_sandbox"
  [ ! -d "$wrong_parent_sandbox" ] || rmdir "$wrong_parent_sandbox"
  [ ! -d "$other_parent" ] || rmdir "$other_parent"
  [ ! -L "$symlink_sandbox" ] || unlink "$symlink_sandbox"
  [ ! -d "$symlink_target" ] || rmdir "$symlink_target"
  exit "$exit_status"
}
trap emergency_cleanup EXIT
trap 'exit 130' HUP INT TERM

docker run --rm -v "$sandbox:/sandbox" "$runner_image" \
  sh -c 'mkdir -p /sandbox/state && touch /sandbox/state/root-owned'

cleanup_sandbox "$sandbox"
[ ! -e "$sandbox" ]

mkdir "$unsafe_sandbox"
assert_cleanup_rejected ""
assert_cleanup_rejected "/"
assert_cleanup_rejected "$script_dir/.."
assert_cleanup_rejected "$unsafe_sandbox"
[ -d "$unsafe_sandbox" ]

mkdir "$wrong_parent_sandbox"
assert_cleanup_rejected "$wrong_parent_sandbox"
[ -d "$wrong_parent_sandbox" ]

ln -s "$symlink_target" "$symlink_sandbox"
assert_cleanup_rejected "$symlink_sandbox"
[ -L "$symlink_sandbox" ]
[ -d "$symlink_target" ]

rmdir "$unsafe_sandbox"
rmdir "$wrong_parent_sandbox"
rmdir "$other_parent"
unlink "$symlink_sandbox"
rmdir "$symlink_target"

trap - EXIT HUP INT TERM
