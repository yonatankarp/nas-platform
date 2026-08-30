#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
. "$script_dir/integration_lock.sh"

temporary_parent=${TMPDIR:-/tmp}
temporary_parent=${temporary_parent%/}
temporary_parent=$(CDPATH= cd -P "$temporary_parent" && pwd -P)
test_lock_parent=$(mktemp -d "$temporary_parent/nas-platform-lock-test.XXXXXX")
lock_alias="$test_lock_parent.alias"
lock_dir="$test_lock_parent/nas-platform-integration.lock"
cleanup_lock_test() {
  [ ! -L "$lock_alias" ] || unlink "$lock_alias"
  rm -f "$lock_dir/owner"
  [ ! -d "$lock_dir.reclaim" ] || rmdir "$lock_dir.reclaim"
  [ ! -d "$lock_dir" ] || rmdir "$lock_dir"
  [ ! -d "$test_lock_parent" ] || rmdir "$test_lock_parent"
}
trap cleanup_lock_test EXIT

lock_fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

acquire_integration_lock "$test_lock_parent"
if (
  . "$script_dir/integration_lock.sh"
  acquire_integration_lock "$test_lock_parent"
) >/dev/null 2>&1; then
  printf 'integration lock allowed a concurrent owner\n' >&2
  exit 1
fi
[ -d "$test_lock_parent/nas-platform-integration.lock" ]

# The holder has to be identifiable, or a lock left behind by a SIGKILL is
# indistinguishable from one a live run is using and stays forever.
grep -qx "pid=$$" "$lock_dir/owner" ||
  lock_fail 'integration lock did not record its holder pid'
grep -qx "uid=$(id -u)" "$lock_dir/owner" ||
  lock_fail 'integration lock did not record its holder uid'
grep -qx "host=$(uname -n)" "$lock_dir/owner" ||
  lock_fail 'integration lock did not record its holder host'
[ ! -e "$lock_dir.reclaim" ] ||
  lock_fail 'an uncontended acquisition left a recovery guard behind'

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

# A PID nothing owns any more. Read from a child that has already exited, and
# confirmed dead before use so a recycled number cannot make the recovery cases
# below pass or fail for the wrong reason.
dead_pid=
dead_pid_attempt=0
while [ "$dead_pid_attempt" -lt 20 ]; do
  dead_pid_attempt=$((dead_pid_attempt + 1))
  dead_pid_candidate=$(sh -c 'printf %s "$$"')
  if ! kill -0 "$dead_pid_candidate" 2>/dev/null; then
    dead_pid=$dead_pid_candidate
    break
  fi
done
[ -n "$dead_pid" ] || lock_fail 'could not obtain a pid that is certainly gone'

plant_lock_owner() {
  mkdir "$lock_dir"
  printf 'pid=%s\nuid=%s\nhost=%s\n' "$1" "$2" "$3" > "$lock_dir/owner"
}

discard_planted_lock() {
  rm -f "$lock_dir/owner"
  rmdir "$lock_dir"
}

# The property this whole file exists for: release happens only through an EXIT
# trap, so a SIGKILL, an OOM, a cancelled Actions job or a sleeping laptop used to
# leave the lock behind permanently -- and because the same lock gates
# tests/mac/cleanup.sh, the dead run's containers could not be cleaned up either.
plant_lock_owner "$dead_pid" "$(id -u)" "$(uname -n)"
acquire_integration_lock "$test_lock_parent" 2>/dev/null ||
  lock_fail 'integration lock refused to recover from a dead holder'
grep -qx "pid=$$" "$lock_dir/owner" ||
  lock_fail 'a recovered integration lock was not re-owned'
[ ! -e "$lock_dir.reclaim" ] ||
  lock_fail 'recovering the integration lock left its recovery guard behind'
release_integration_lock

# Everything below is the other half of the property: recovery must never be a
# guess. A holder that is alive, that belongs to another user (where kill -0
# answers EPERM, which a shell cannot tell from "no such process"), that ran on
# another machine (where the pid means nothing), or that recorded nothing at all
# must all be refused rather than deleted.
plant_lock_owner "$$" "$(id -u)" "$(uname -n)"
if acquire_integration_lock "$test_lock_parent" >/dev/null 2>&1; then
  lock_fail 'integration lock recovery stole a lock from a live holder'
fi
discard_planted_lock

plant_lock_owner "$dead_pid" 4294967294 "$(uname -n)"
if acquire_integration_lock "$test_lock_parent" >/dev/null 2>&1; then
  lock_fail "integration lock recovery stole another user's lock"
fi
discard_planted_lock

plant_lock_owner "$dead_pid" "$(id -u)" 'nas-platform-lock-test-other-host'
if acquire_integration_lock "$test_lock_parent" >/dev/null 2>&1; then
  lock_fail "integration lock recovery stole another machine's lock"
fi
discard_planted_lock

# No owner file at all is what a run killed in the single syscall between mkdir
# and recording itself leaves behind. It is not recoverable without guessing, so
# the refusal has to name the path instead.
mkdir "$lock_dir"
if acquire_integration_lock "$test_lock_parent" >/dev/null 2>&1; then
  lock_fail 'integration lock recovery removed a lock with no recorded holder'
fi
lock_refusal=$(acquire_integration_lock "$test_lock_parent" 2>&1 >/dev/null || true)
case $lock_refusal in
  *"$lock_dir"*) ;;
  *) lock_fail 'integration lock refusal does not name the lock path' ;;
esac
rmdir "$lock_dir"

# Recovery is serialized by an ordinary mkdir of its own, so two runs cannot both
# decide the same stale lock is theirs to remove. A guard already held means
# another process is inside that section: refuse rather than race it.
plant_lock_owner "$dead_pid" "$(id -u)" "$(uname -n)"
mkdir "$lock_dir.reclaim"
if acquire_integration_lock "$test_lock_parent" >/dev/null 2>&1; then
  lock_fail 'integration lock recovery ran while another recovery held the guard'
fi
rmdir "$lock_dir.reclaim"
acquire_integration_lock "$test_lock_parent" 2>/dev/null ||
  lock_fail 'integration lock recovery stayed blocked after its guard was released'
release_integration_lock

# One recovery, not a loop: a lock reclaimed and immediately reclaimed again by a
# live run must be refused rather than taken a second time.
plant_lock_owner "$dead_pid" "$(id -u)" "$(uname -n)"
acquire_integration_lock "$test_lock_parent" 2>/dev/null ||
  lock_fail 'integration lock refused to recover a second time'
if (
  . "$script_dir/integration_lock.sh"
  acquire_integration_lock "$test_lock_parent"
) >/dev/null 2>&1; then
  lock_fail 'integration lock allowed a concurrent owner after a recovery'
fi
release_integration_lock

printf 'integration lock tests passed\n'
