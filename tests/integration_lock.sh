#!/bin/sh

integration_lock_path=
integration_lock_parent=

# Holder identity, written inside the lock so a directory left by a SIGKILL can
# be told from a live one (release only happens via an EXIT trap). uid because
# kill -0 on another user's process answers EPERM; hostname because a PID is per-host.
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

# Removes a lock whose recorded holder no longer exists; 0 only when removed.
# Runs inside a second mkdir lock so two runs cannot both reclaim, and a live
# claim cannot slip in between the owner check and the rmdir.
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
    # A holder we cannot answer for (no owner recorded) is treated as alive.
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
  # A loop so the claim's mkdir appears once; a second copy could be mutated unnoticed.
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
  # Only our marker is removed, so a lock holding anything else fails the rmdir.
  rm -f "$integration_lock_path/owner" || return 1
  rmdir "$integration_lock_path" || {
    printf 'could not release the integration lock %s\n' \
      "$integration_lock_path" >&2
    return 1
  }
  integration_lock_path=
  integration_lock_parent=
}
