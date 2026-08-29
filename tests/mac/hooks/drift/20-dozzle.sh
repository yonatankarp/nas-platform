#!/bin/sh
set -eu
set +x
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"
expected_failure=
check_output=
label_override=
fixture_owned=false
label_fixture_owned=false
current=$PLATFORM_DOCKER_ROOT/nas-platform/current/services/dozzle
runtime=$PLATFORM_DOCKER_ROOT/nas-platform/runtime/services/dozzle/.env

cleanup_owned_file() {
  cleanup_path=$1
  [ -n "$cleanup_path" ] || return 0
  [ ! -e "$cleanup_path" ] && [ ! -L "$cleanup_path" ] && return 0
  case $cleanup_path in
    "$PLATFORM_REPORT_ROOT"/dozzle-verify-drift.??????|\
    "$PLATFORM_REPORT_ROOT"/dozzle-check-mixed.??????|\
    "$PLATFORM_REPORT_ROOT"/dozzle-label-drift.??????) ;;
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

cleanup_outputs() {
  cleanup_status=0
  cleanup_owned_file "$expected_failure" || cleanup_status=1
  cleanup_owned_file "$check_output" || cleanup_status=1
  cleanup_owned_file "$label_override" || cleanup_status=1
  return "$cleanup_status"
}

recreate_socket_proxy() {
  override=${1-}
  set -- docker compose --project-name "$PLATFORM_PROJECT_NAME-dozzle" --env-file "$runtime"
  compose_arguments=$(mac_compose_files "$current")
  while IFS= read -r compose_argument; do set -- "$@" "$compose_argument"; done <<EOF
$compose_arguments
EOF
  [ -z "$override" ] || set -- "$@" -f "$override"
  "$@" up -d --force-recreate --wait socket-proxy
}

dozzle_socket_proxy_name() {
  mac_container_name dozzle-socket-proxy
}

recover_label_fixture() {
  [ "$label_fixture_owned" = true ] || return 0
  recreate_socket_proxy || return 1
  label_fixture_owned=false
}

recover_fixture() {
  recovery_status=0
  if [ "$fixture_owned" = true ]; then
    if "$mac_script_dir/run-dozzle-contract.sh" check-mixed-recover; then
      fixture_owned=false
    else
      recovery_status=1
    fi
  fi
  recover_label_fixture || recovery_status=1
  return "$recovery_status"
}

finish_hook() {
  hook_status=$?
  trap - EXIT HUP INT TERM
  if [ "$hook_status" -ne 0 ] && ! recover_fixture; then
    hook_status=1
  fi
  if ! cleanup_outputs; then
    hook_status=1
  fi
  exit "$hook_status"
}

finish_signal() {
  signal_status=$1
  trap - EXIT HUP INT TERM
  recover_fixture || true
  cleanup_outputs || true
  exit "$signal_status"
}

trap finish_hook EXIT
trap 'finish_signal 129' HUP
trap 'finish_signal 130' INT
trap 'finish_signal 143' TERM
expected_failure=$(mktemp "$PLATFORM_REPORT_ROOT/dozzle-verify-drift.XXXXXX")
check_output=$(mktemp "$PLATFORM_REPORT_ROOT/dozzle-check-mixed.XXXXXX")
label_override=$(mktemp "$PLATFORM_REPORT_ROOT/dozzle-label-drift.XXXXXX")

cat > "$label_override" <<'YAML'
services:
  socket-proxy:
    labels:
      dev.dozzle.group: dozzle-contract-drift
      dev.dozzle.name: dozzle-contract-drift
      dev.dozzle.contract.sentinel: unrelated-label-must-not-survive-reconciliation
YAML

# Compose owns the complete service label set. The unmanaged sentinel proves the
# drift fixture exercised that boundary; normal reconciliation is expected to
# remove it while restoring the managed Dozzle group and friendly name.
label_fixture_owned=true
recreate_socket_proxy "$label_override"
socket_proxy=$(dozzle_socket_proxy_name)
drifted_labels=$(docker container inspect --format '{{json .Config.Labels}}' "$socket_proxy")
DOZZLE_DRIFTED_LABELS=$drifted_labels ruby -rjson -e '
  labels = JSON.parse(ENV.fetch("DOZZLE_DRIFTED_LABELS"))
  abort unless labels["dev.dozzle.group"] == "dozzle-contract-drift" &&
               labels["dev.dozzle.name"] == "dozzle-contract-drift" &&
               labels["dev.dozzle.contract.sentinel"] ==
                 "unrelated-label-must-not-survive-reconciliation"
'

fixture_owned=true
"$mac_script_dir/run-dozzle-contract.sh" check-mixed-create
if ! mac_ansible_playbook -i "$mac_repo_dir/inventory/mac.yml" "$mac_repo_dir/site.yml" \
    --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE" \
    -e @"$PLATFORM_MAC_VAULT_FILE" \
    -e "platform_vault_file=$PLATFORM_MAC_VAULT_FILE" \
    --tags dozzle --check --diff >"$check_output" 2>&1; then
  "$mac_repo_dir/tests/assert-no-vault-secrets.rb" \
    "$PLATFORM_MAC_VAULT_FILE" "$PLATFORM_MAC_VAULT_PASSWORD_FILE" "$check_output"
  exit 1
fi
"$mac_repo_dir/tests/assert-no-vault-secrets.rb" \
  "$PLATFORM_MAC_VAULT_FILE" "$PLATFORM_MAC_VAULT_PASSWORD_FILE" "$check_output"
grep -qE 'changed=[1-9][0-9]* .*failed=0 ' "$check_output"
"$mac_script_dir/run-dozzle-contract.sh" assert-check-mixed-output "$check_output"
"$mac_script_dir/run-dozzle-contract.sh" check-mixed-unchanged
if mac_ansible_playbook -i "$mac_repo_dir/inventory/mac.yml" "$mac_repo_dir/verify.yml" \
    --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE" \
    -e @"$PLATFORM_MAC_VAULT_FILE" \
    -e "platform_vault_file=$PLATFORM_MAC_VAULT_FILE" \
    --tags platform_verify_dozzle >"$expected_failure" 2>&1; then
  printf '%s\n' 'verification-only run accepted Dozzle drift' >&2
  exit 1
fi
"$mac_repo_dir/tests/assert-no-vault-secrets.rb" \
  "$PLATFORM_MAC_VAULT_FILE" "$PLATFORM_MAC_VAULT_PASSWORD_FILE" "$expected_failure"
grep -qF 'Dozzle ntfy dispatcher is absent or drifted.' "$expected_failure" || {
  printf '%s\n' 'Dozzle verification refused drift without its fixed diagnostic' >&2
  exit 1
}
