#!/bin/sh

mac_die() {
  printf '%s\n' "$1" >&2
  return 1
}

mac_validate_lexical_path() {
  mac_path=$1
  mac_label=$2
  case $mac_path in
    /*) ;;
    *) mac_die "$mac_label must be absolute" ;;
  esac
  case $mac_path in
    /) ;;
    */|*//*|*/./*|*/../*|*/.|*/..) mac_die "$mac_label must be lexically normalized" ;;
  esac
}

mac_owner_id() {
  if [ "$(uname -s)" = Darwin ]; then
    stat -f '%u' "$1"
  else
    stat -c '%u' "$1"
  fi
}

mac_file_mode() {
  if [ "$(uname -s)" = Darwin ]; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

mac_canonical_directory() {
  mac_validate_lexical_path "$1" "$2" || return 1
  [ -d "$1" ] && [ ! -L "$1" ] || mac_die "$2 is unavailable or unsafe"
  CDPATH= cd -- "$1" 2>/dev/null && pwd -P
}

mac_temporary_parent() {
  mac_parent_input=${PLATFORM_MAC_TMPDIR:-${TMPDIR:-/tmp}}
  mac_parent_input=${mac_parent_input%/}
  [ -n "$mac_parent_input" ] || mac_parent_input=/
  mac_canonical_directory "$mac_parent_input" 'Mac temporary parent'
}

mac_validate_sandbox() {
  mac_requested=${1-}
  [ -n "$mac_requested" ] || mac_die 'refusing to remove unowned Mac sandbox: empty path'
  mac_validate_lexical_path "$mac_requested" 'Mac sandbox' || return 1
  [ "$mac_requested" != / ] || mac_die 'refusing to remove unowned Mac sandbox: /'
  [ -d "$mac_requested" ] && [ ! -L "$mac_requested" ] ||
    mac_die "refusing to remove unowned Mac sandbox: $mac_requested"

  mac_parent=$(mac_temporary_parent) || return 1
  mac_physical=$(CDPATH= cd -- "$mac_requested" 2>/dev/null && pwd -P) ||
    mac_die "refusing to remove unowned Mac sandbox: $mac_requested"
  [ "$mac_physical" = "$mac_requested" ] ||
    mac_die "refusing to remove unowned Mac sandbox: $mac_requested"
  [ "$(dirname -- "$mac_physical")" = "$mac_parent" ] ||
    mac_die "refusing to remove unowned Mac sandbox: $mac_requested"
  case $(basename -- "$mac_physical") in
    nas-platform-mac.??????) ;;
    *) mac_die "refusing to remove unowned Mac sandbox: $mac_requested" ;;
  esac
  mac_suffix=${mac_physical##*.}
  case $mac_suffix in
    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789]*)
      mac_die "refusing to remove unowned Mac sandbox: $mac_requested"
      ;;
  esac
  [ "$(mac_owner_id "$mac_physical")" = "$(id -u)" ] &&
    [ "$(mac_file_mode "$mac_physical")" = 700 ] ||
    mac_die "refusing to remove unowned Mac sandbox: $mac_requested"

  mac_marker=$mac_physical/.nas-platform-mac-owned
  [ -f "$mac_marker" ] && [ ! -L "$mac_marker" ] &&
    [ "$(mac_owner_id "$mac_marker")" = "$(id -u)" ] &&
    [ "$(mac_file_mode "$mac_marker")" = 600 ] ||
    mac_die "refusing to remove unowned Mac sandbox: $mac_requested"
  grep -qx 'schema=1' "$mac_marker" ||
    mac_die "refusing to remove unowned Mac sandbox: $mac_requested"
  mac_project=$(sed -n 's/^project=//p' "$mac_marker")
  case $mac_project in
    nas-platform-mac-[ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789]*) ;;
    *) mac_die "refusing to remove unowned Mac sandbox: $mac_requested" ;;
  esac
  [ "$mac_project" = "nas-platform-mac-$mac_suffix" ] ||
    mac_die "refusing to remove unowned Mac sandbox: $mac_requested"
  printf '%s\n' "$mac_physical"
}

mac_shell_quote() {
  case $1 in
    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./-]*)
      printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
      ;;
    *) printf '%s' "$1" ;;
  esac
}

mac_run_hooks() {
  mac_hook_group=$1
  shift
  mac_hook_root=$mac_script_dir/hooks/$mac_hook_group
  [ -d "$mac_hook_root" ] || mac_die "No Mac hooks registered for $mac_hook_group"
  mac_hook_count=0
  for mac_hook in "$mac_hook_root"/*.sh; do
    [ -f "$mac_hook" ] || continue
    [ ! -L "$mac_hook" ] && [ -x "$mac_hook" ] ||
      mac_die "unsafe or non-executable Mac hook: $mac_hook"
    mac_hook_count=$((mac_hook_count + 1))
    "$mac_hook" "$@" || return 1
  done
  [ "$mac_hook_count" -gt 0 ] || mac_die "No Mac hooks registered for $mac_hook_group"
}
