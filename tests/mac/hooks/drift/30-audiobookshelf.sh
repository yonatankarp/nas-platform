#!/bin/sh
set -eu
set +x
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"
expected_failure=
fixture_owned=false

cleanup_owned_file() {
  cleanup_path=$1
  [ -n "$cleanup_path" ] || return 0
  [ ! -e "$cleanup_path" ] && [ ! -L "$cleanup_path" ] && return 0
  case $cleanup_path in
    "$PLATFORM_REPORT_ROOT"/audiobookshelf-verify-drift.??????) ;;
    *) return 1 ;;
  esac
  [ -f "$cleanup_path" ] && [ ! -L "$cleanup_path" ] || return 1
  if [ "$(uname -s)" = Darwin ]; then
    [ "$(stat -f '%u' "$cleanup_path")" = "$(id -u)" ] &&
      [ "$(stat -f '%Lp' "$cleanup_path")" = 600 ] || return 1
  else
    [ "$(stat -c '%u' "$cleanup_path")" = "$(id -u)" ] &&
      [ "$(stat -c '%a' "$cleanup_path")" = 600 ] || return 1
  fi
  unlink "$cleanup_path"
}

recover_fixture() {
  [ "$fixture_owned" = true ] || return 0
  "$mac_script_dir/run-audiobookshelf-contract.sh" drift-recover || return 1
  fixture_owned=false
}

finish_hook() {
  hook_status=$?
  trap - EXIT HUP INT TERM
  if [ "$hook_status" -ne 0 ] && ! recover_fixture; then
    hook_status=1
  fi
  if ! cleanup_owned_file "$expected_failure"; then
    hook_status=1
  fi
  exit "$hook_status"
}

finish_signal() {
  signal_status=$1
  trap - EXIT HUP INT TERM
  recover_fixture || signal_status=1
  cleanup_owned_file "$expected_failure" || signal_status=1
  exit "$signal_status"
}

trap finish_hook EXIT
trap 'finish_signal 129' HUP
trap 'finish_signal 130' INT
trap 'finish_signal 143' TERM
expected_failure=$(mktemp "$PLATFORM_REPORT_ROOT/audiobookshelf-verify-drift.XXXXXX")

fixture_owned=true
"$mac_script_dir/run-audiobookshelf-contract.sh" drift
"$mac_script_dir/run-audiobookshelf-contract.sh" drift-verify
if mac_ansible_playbook -i "$mac_repo_dir/inventory/mac.yml" "$mac_repo_dir/verify.yml" \
    --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE" \
    -e @"$PLATFORM_MAC_VAULT_FILE" \
    -e "platform_vault_file=$PLATFORM_MAC_VAULT_FILE" \
    --tags platform_verify_audiobookshelf >"$expected_failure" 2>&1; then
  printf '%s\n' 'verification-only run accepted Audiobookshelf drift' >&2
  exit 1
fi
"$mac_repo_dir/tests/assert-no-vault-secrets.rb" \
  "$PLATFORM_MAC_VAULT_FILE" "$PLATFORM_MAC_VAULT_PASSWORD_FILE" "$expected_failure"
grep -qF 'The managed Audiobookshelf library is absent, duplicated, surplus, or drifted.' \
  "$expected_failure" || {
  printf '%s\n' 'Audiobookshelf verification refused drift without its fixed diagnostic' >&2
  exit 1
}
"$mac_script_dir/run-audiobookshelf-contract.sh" drift-commit
fixture_owned=false
