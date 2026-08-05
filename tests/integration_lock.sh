#!/bin/sh

integration_lock_path=
integration_lock_parent=

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
  if ! mkdir "$lock_candidate" 2>/dev/null; then
    printf 'another NAS platform integration run holds the shared Docker lock\n' >&2
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
  rmdir "$integration_lock_path" || return 1
  integration_lock_path=
  integration_lock_parent=
}
