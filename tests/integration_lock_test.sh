#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
. "$script_dir/integration_lock.sh"

temporary_parent=${TMPDIR:-/tmp}
temporary_parent=${temporary_parent%/}
temporary_parent=$(CDPATH= cd -P "$temporary_parent" && pwd -P)
test_lock_parent=$(mktemp -d "$temporary_parent/nas-platform-lock-test.XXXXXX")
lock_alias="$test_lock_parent.alias"
trap '[ ! -L "$lock_alias" ] || unlink "$lock_alias"; [ ! -d "$test_lock_parent" ] || rmdir "$test_lock_parent"' EXIT

acquire_integration_lock "$test_lock_parent"
if (
  . "$script_dir/integration_lock.sh"
  acquire_integration_lock "$test_lock_parent"
) >/dev/null 2>&1; then
  printf 'integration lock allowed a concurrent owner\n' >&2
  exit 1
fi
[ -d "$test_lock_parent/nas-platform-integration.lock" ]
release_integration_lock
[ ! -e "$test_lock_parent/nas-platform-integration.lock" ]

ln -s "$test_lock_parent" "$lock_alias"
if acquire_integration_lock "$lock_alias" >/dev/null 2>&1; then
  printf 'integration lock accepted a symlink parent\n' >&2
  exit 1
fi
if acquire_integration_lock "$test_lock_parent/" >/dev/null 2>&1; then
  printf 'integration lock accepted a trailing-separator parent\n' >&2
  exit 1
fi
unlink "$lock_alias"

acquire_integration_lock "$test_lock_parent"
: > "$integration_lock_path/unexpected"
if release_integration_lock >/dev/null 2>&1; then
  printf 'integration lock release removed a nonempty lock\n' >&2
  exit 1
fi
[ -f "$integration_lock_path/unexpected" ]
rm "$integration_lock_path/unexpected"
release_integration_lock
