#!/bin/sh

integration_lock_path=
integration_lock_parent=

# Identity of the process holding the lock, written inside it so a directory left
# behind by a SIGKILL, an OOM, a cancelled Actions job or a laptop that slept can
# be told apart from one a live run is using. Release only ever happens through an
# EXIT trap, so without this a hard termination made the lock permanent -- and the
# same lock gates tests/mac/cleanup.sh, so the run that died left containers
# behind and then blocked the script that would have removed them.
#
# The uid is recorded because `kill -0` against a process owned by another user
# fails with EPERM, which a shell cannot tell from "no such process"; recovering
# on that answer would let one user delete another user's live lock. The hostname
# is recorded because a PID only means anything on the machine that issued it.
integration_lock_owner_identity() {
  printf 'pid=%s\nuid=%s\nhost=%s\n' "$$" "$(id -u)" "$(uname -n)"
}

describe_integration_lock_holder() {
  describe_owner="$1/owner"
  if [ -f "$describe_owner" ] && [ ! -L "$describe_owner" ]; then
    describe_pid=$(sed -n 's/^pid=//p' "$describe_owner")
    describe_uid=$(sed -n 's/^uid=//p' "$describe_owner")
    describe_host=$(sed -n 's/^host=//p' "$describe_owner")
    printf 'holder: pid %s of uid %s on %s' \
      "${describe_pid:-unknown}" "${describe_uid:-unknown}" \
      "${describe_host:-unknown}"
  else
    printf 'holder: unrecorded'
  fi
}

# Removes a lock whose recorded holder no longer exists, answering 0 only when the
# directory was actually removed so the caller can retry its claim.
#
# Two runs can reach this at the same instant, and a bare read-then-rmdir lets the
# slower one delete a lock the faster one has already replaced with its own live
# claim. The recovery therefore runs inside a second, ordinary mkdir lock. That
# makes it safe rather than merely unlikely: a stale lock can be removed only from
# inside this critical section, only one process is ever inside it, and claiming a
# fresh lock requires the old directory to be gone -- so the directory whose owner
# is inspected here is necessarily still the same directory that gets removed, and
# no third process can have claimed a live lock in between.
#
# What remains is a process killed between claiming the recovery lock and dropping
# it. That window contains no waiting and no work beyond a few stats and a kill -0,
# rather than a whole integration run, and a recovery lock left behind only
# restores the previous behaviour: a refusal that names the paths to remove.
reclaim_stale_integration_lock() {
  reclaim_target=$1
  reclaim_guard="$reclaim_target.reclaim"
  mkdir "$reclaim_guard" 2>/dev/null || return 1

  reclaim_status=1
  reclaim_owner="$reclaim_target/owner"
  if [ -f "$reclaim_owner" ] && [ ! -L "$reclaim_owner" ]; then
    reclaim_pid=$(sed -n 's/^pid=//p' "$reclaim_owner")
    reclaim_uid=$(sed -n 's/^uid=//p' "$reclaim_owner")
    reclaim_host=$(sed -n 's/^host=//p' "$reclaim_owner")
    case $reclaim_pid in
      ''|*[!0123456789]*) reclaim_pid= ;;
    esac
    # A holder we cannot answer for is treated as alive. A run killed in the one
    # syscall between claiming the lock and recording itself leaves no owner at
    # all, and inventing a recovery for that case would mean removing locks on a
    # guess.
    if [ -n "$reclaim_pid" ] &&
        [ "$reclaim_uid" = "$(id -u)" ] &&
        [ "$reclaim_host" = "$(uname -n)" ] &&
        ! kill -0 "$reclaim_pid" 2>/dev/null; then
      printf 'reclaiming the integration lock %s from dead pid %s\n' \
        "$reclaim_target" "$reclaim_pid" >&2
      rm -f "$reclaim_owner" &&
        rmdir "$reclaim_target" 2>/dev/null &&
        reclaim_status=0
    fi
  fi
  rmdir "$reclaim_guard" || :
  return "$reclaim_status"
}

acquire_integration_lock() {
  lock_parent=$1
  case $lock_parent in
    /*) ;;
    *) printf 'integration lock parent must be absolute\n' >&2; return 1 ;;
  esac
  case $lock_parent in
    /) ;;
    */|*//*|*/./*|*/../*|*/.|*/..)
      printf 'integration lock parent must be lexically normalized\n' >&2
      return 1
      ;;
  esac
  [ -d "$lock_parent" ] && [ ! -L "$lock_parent" ] || {
    printf 'integration lock parent is unsafe\n' >&2
    return 1
  }
  lock_physical_parent=$(CDPATH= cd -P "$lock_parent" 2>/dev/null && pwd -P) || return 1
  [ "$lock_physical_parent" = "$lock_parent" ] || {
    printf 'integration lock parent must be canonical\n' >&2
    return 1
  }

  lock_candidate="$lock_parent/nas-platform-integration.lock"
  # One claim, then at most one recovery and one more claim. Written as a loop so
  # the claim itself appears exactly once: a second literal mkdir of the same
  # directory would let a mutation disable one of them unnoticed.
  lock_reclaimed=false
  while :; do
    if mkdir "$lock_candidate" 2>/dev/null; then
      break
    fi
    if [ "$lock_reclaimed" = true ] ||
        ! reclaim_stale_integration_lock "$lock_candidate"; then
      printf 'another NAS platform integration run holds the shared Docker lock\n' >&2
      printf '  lock: %s\n' "$lock_candidate" >&2
      printf '  %s\n' "$(describe_integration_lock_holder "$lock_candidate")" >&2
      printf '  if that holder is gone: rm -f %s/owner && rmdir %s\n' \
        "$lock_candidate" "$lock_candidate" >&2
      return 1
    fi
    lock_reclaimed=true
  done
  if ! integration_lock_owner_identity > "$lock_candidate/owner"; then
    # Holding a lock nobody can attribute is what created this bug. Give it back
    # rather than become the next unrecoverable holder.
    rm -f "$lock_candidate/owner"
    rmdir "$lock_candidate" || :
    printf 'could not record the integration lock owner in %s\n' \
      "$lock_candidate" >&2
    return 1
  fi
  integration_lock_parent=$lock_parent
  integration_lock_path=$lock_candidate
}

release_integration_lock() {
  [ -n "$integration_lock_path" ] &&
    [ "$integration_lock_path" = "$integration_lock_parent/nas-platform-integration.lock" ] &&
    [ -d "$integration_lock_path" ] && [ ! -L "$integration_lock_path" ] || {
      printf 'refusing to release an unsafe integration lock\n' >&2
      return 1
    }
  # Only the marker this file wrote is removed, so a lock that has grown anything
  # else still fails the rmdir below rather than being cleared blind.
  rm -f "$integration_lock_path/owner" || return 1
  rmdir "$integration_lock_path" || {
    printf 'could not release the integration lock %s\n' \
      "$integration_lock_path" >&2
    return 1
  }
  integration_lock_path=
  integration_lock_parent=
}
