#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
. "$script_dir/sandbox_cleanup.sh"

test_case=${1:-all}
sandbox=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-cleanup.XXXXXX")
unsafe_sandbox=${TMPDIR:-/tmp}/nas-platform-cleanup.not-six-$$
other_parent=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-cleanup-parent.XXXXXX")
wrong_parent_sandbox=$other_parent/nas-platform-cleanup.ABCDEF
symlink_target=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-cleanup-target.XXXXXX")
symlink_suffix=$(basename "$symlink_target" | sed 's/^nas-platform-cleanup-target\.//')
symlink_sandbox=${TMPDIR:-/tmp}/nas-platform-cleanup.$symlink_suffix
unsupported_sandbox=
invalid_suffix_sandbox=
failure_sandbox=
swap_sandbox=
swap_victim=
python_sandbox=
python_root_symlink=
python_victim=
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
  [ -z "$unsupported_sandbox" ] || [ ! -d "$unsupported_sandbox" ] || rmdir "$unsupported_sandbox"
  [ -z "$invalid_suffix_sandbox" ] || [ ! -d "$invalid_suffix_sandbox" ] || rmdir "$invalid_suffix_sandbox"
  [ -z "$failure_sandbox" ] || [ ! -d "$failure_sandbox" ] || rmdir "$failure_sandbox"
  [ -z "$swap_sandbox" ] || [ ! -L "$swap_sandbox" ] || unlink "$swap_sandbox"
  [ -z "$swap_sandbox" ] || [ ! -d "$swap_sandbox" ] || rmdir "$swap_sandbox"
  if [ -n "$swap_victim" ] && [ -d "$swap_victim" ]; then
    [ ! -f "$swap_victim/marker" ] || rm "$swap_victim/marker"
    rmdir "$swap_victim"
  fi
  [ -z "$python_root_symlink" ] || [ ! -L "$python_root_symlink" ] || unlink "$python_root_symlink"
  if [ -n "$python_sandbox" ] && [ -d "$python_sandbox" ]; then
    docker run --rm -v "$python_sandbox:/sandbox" "$runner_image" \
      sh -c 'find /sandbox -depth -mindepth 1 -delete' >/dev/null
    rmdir "$python_sandbox"
  fi
  if [ -n "$python_victim" ] && [ -d "$python_victim" ]; then
    [ ! -f "$python_victim/marker" ] || rm "$python_victim/marker"
    rmdir "$python_victim"
  fi
  exit "$exit_status"
}
trap emergency_cleanup EXIT
trap 'exit 130' HUP INT TERM

test_unsupported_stem() {
  unsupported_sandbox=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-unsupported.XXXXXX")
  assert_cleanup_rejected "$unsupported_sandbox"
  [ -d "$unsupported_sandbox" ]
  rmdir "$unsupported_sandbox"
  unsupported_sandbox=
}

test_invalid_suffix_alphabet() {
  invalid_suffix_seed=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-cleanup.XXXXXX")
  invalid_suffix_sandbox=${invalid_suffix_seed%?}-
  mv "$invalid_suffix_seed" "$invalid_suffix_sandbox"
  assert_cleanup_rejected "$invalid_suffix_sandbox"
  [ -d "$invalid_suffix_sandbox" ]
  rmdir "$invalid_suffix_sandbox"
  invalid_suffix_sandbox=
}

test_docker_failure() {
  failure_mode=$1
  failure_sandbox=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-cleanup.XXXXXX")
  if (
    docker() {
      case "$1:$failure_mode" in
        ps:list) return 41 ;;
        ps:rm) printf '%s\n' fake-container-id ;;
        rm:rm) return 42 ;;
      esac
      return 0
    }
    cleanup_sandbox "$failure_sandbox"
  ); then
    printf 'cleanup ignored docker %s failure\n' "$failure_mode" >&2
    exit 1
  fi
  [ -d "$failure_sandbox" ]
  rmdir "$failure_sandbox"
  failure_sandbox=
}

test_symlink_swap() {
  swap_sandbox=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-cleanup.XXXXXX")
  swap_victim=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-cleanup-target.XXXXXX")
  : > "$swap_victim/marker"
  if (
    docker() {
      if [ "$1" = ps ]; then
        return 0
      fi
      if [ "$1" = run ]; then
        rmdir "$swap_sandbox"
        ln -s "$swap_victim" "$swap_sandbox"
        while [ "$#" -gt 0 ]; do
          if [ "$1" = -v ]; then
            mount_source=${2%%:*}
            break
          fi
          shift
        done
        if [ "$mount_source" = "$swap_sandbox" ]; then
          rm "$swap_victim/marker"
          return 0
        fi
        return 43
      fi
      return 0
    }
    cleanup_sandbox "$swap_sandbox"
  ); then
    printf 'cleanup accepted a sandbox swapped for a symlink\n' >&2
    exit 1
  fi
  [ -f "$swap_victim/marker" ]
  unlink "$swap_sandbox"
  swap_sandbox=
  rm "$swap_victim/marker"
  rmdir "$swap_victim"
  swap_victim=
}

test_trap_statuses() {
  trap_status=0
  sh -c '. "$1"; cleanup_sandbox() { return 0; }; sandbox=ignored; trap '\''cleanup_sandbox_on_exit "$sandbox" "$?"'\'' EXIT; exit 23' \
    sh "$script_dir/sandbox_cleanup.sh" || trap_status=$?
  [ "$trap_status" -eq 23 ] || {
    printf 'successful cleanup changed original exit status 23 to %s\n' "$trap_status" >&2
    exit 1
  }

  trap_status=0
  sh -c '. "$1"; cleanup_sandbox() { return 1; }; sandbox=ignored; trap '\''cleanup_sandbox_on_exit "$sandbox" "$?"'\'' EXIT; exit 0' \
    sh "$script_dir/sandbox_cleanup.sh" || trap_status=$?
  [ "$trap_status" -ne 0 ] || {
    printf 'failed cleanup preserved successful exit status\n' >&2
    exit 1
  }
}

test_python_rejects_root_symlink() {
  command -v cleanup_sandbox_contents >/dev/null
  python_victim=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-cleanup-target.XXXXXX")
  : > "$python_victim/marker"
  python_suffix=$(basename "$python_victim" | sed 's/^nas-platform-cleanup-target\.//')
  python_root_symlink=${TMPDIR:-/tmp}/nas-platform-cleanup.$python_suffix
  ln -s "$python_victim" "$python_root_symlink"
  python_parent=$(CDPATH= cd -P "${TMPDIR:-/tmp}" && pwd -P)
  if cleanup_sandbox_contents "$python_parent" "$(basename "$python_root_symlink")" 2>/dev/null; then
    printf 'descriptor-relative cleanup accepted a root symlink\n' >&2
    exit 1
  fi
  [ -f "$python_victim/marker" ]
  unlink "$python_root_symlink"
  python_root_symlink=
  rm "$python_victim/marker"
  rmdir "$python_victim"
  python_victim=
}

test_python_deletes_nested_entries() {
  command -v cleanup_sandbox_contents >/dev/null
  python_sandbox=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-cleanup.XXXXXX")
  python_victim=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-cleanup-target.XXXXXX")
  : > "$python_victim/marker"
  mkdir -p "$python_sandbox/one/two"
  : > "$python_sandbox/one/two/file"
  ln -s "../../../$(basename "$python_victim")" "$python_sandbox/one/two/external"
  python_parent=$(CDPATH= cd -P "${TMPDIR:-/tmp}" && pwd -P)
  cleanup_sandbox_contents "$python_parent" "$(basename "$python_sandbox")"
  [ -f "$python_victim/marker" ]
  [ -z "$(find "$python_sandbox" -mindepth 1 -print)" ]
  rmdir "$python_sandbox"
  python_sandbox=
  rm "$python_victim/marker"
  rmdir "$python_victim"
  python_victim=
}

case "$test_case" in
  unsupported-stem) test_unsupported_stem; exit 0 ;;
  invalid-suffix) test_invalid_suffix_alphabet; exit 0 ;;
  docker-list) test_docker_failure list; exit 0 ;;
  docker-rm) test_docker_failure rm; exit 0 ;;
  symlink-swap) test_symlink_swap; exit 0 ;;
  trap-statuses) test_trap_statuses; exit 0 ;;
  python-root-symlink) test_python_rejects_root_symlink; exit 0 ;;
  python-nested) test_python_deletes_nested_entries; exit 0 ;;
  all) ;;
  *) printf 'unknown test case: %s\n' "$test_case" >&2; exit 2 ;;
esac

test_unsupported_stem
test_invalid_suffix_alphabet
test_docker_failure list
test_docker_failure rm
test_symlink_swap
test_trap_statuses
test_python_rejects_root_symlink
test_python_deletes_nested_entries

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
