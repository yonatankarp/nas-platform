#!/bin/sh
set -eu

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

verify_dozzle_labels() {
  expected_group=$1
  shift
  while [ "$#" -gt 0 ]; do
    expected_name=$1
    container=$2
    shift 2
    labels=$(docker container inspect --format '{{json .Config.Labels}}' "$container") ||
      mac_die "Dozzle label verification could not inspect $container"
    DOZZLE_RUNTIME_LABELS=$labels ruby -rjson - \
      "$expected_group" "$expected_name" "$container" <<'RUBY'
expected_group, expected_name, container = ARGV
begin
  labels = JSON.parse(ENV.fetch("DOZZLE_RUNTIME_LABELS"))
rescue JSON::ParserError
  abort "#{container} returned invalid Docker labels"
end
abort "#{container} returned non-object Docker labels" unless labels.is_a?(Hash)
abort "#{container} has an incorrect dev.dozzle.name label" unless
  labels["dev.dozzle.name"] == expected_name
if expected_group.empty?
  abort "#{container} has an unexpected dev.dozzle.group label" if
    labels.key?("dev.dozzle.group")
else
  abort "#{container} has an incorrect dev.dozzle.group label" unless
    labels["dev.dozzle.group"] == expected_group
end
abort "#{container} retained the unmanaged Dozzle drift sentinel" if
  labels.key?("dev.dozzle.contract.sentinel")
RUBY
  done
}

# Both disposable lanes deploy the same namespaced Compose identities, so the
# roster is taken from the shared identity helper instead of forking by proof
# platform.
case ${PLATFORM_PROOF_PLATFORM:-mac} in
  integration | mac) ;;
  *) mac_die 'proof platform is invalid' ;;
esac
verify_dozzle_labels '' audiobookshelf "$(mac_container_name audiobookshelf)"
verify_dozzle_labels beszel hub "$(mac_container_name beszel)" \
  agent-portable "$(mac_container_name beszel-agent-portable)" \
  socket-proxy "$(mac_container_name beszel-socket-proxy)"
verify_dozzle_labels dozzle alert-relay "$(mac_container_name dozzle-alert-relay)" \
  dozzle "$(mac_container_name dozzle)" \
  socket-proxy "$(mac_container_name dozzle-socket-proxy)"
verify_dozzle_labels immich immich-server "$(mac_container_name immich-server)" \
  immich-machine-learning "$(mac_container_name immich-machine-learning)" \
  redis "$(mac_container_name immich-redis)" \
  database "$(mac_container_name immich-postgres)"
verify_dozzle_labels '' jellyfin "$(mac_container_name jellyfin)"
verify_dozzle_labels '' komga "$(mac_container_name komga)"
verify_dozzle_labels '' ntfy "$(mac_container_name ntfy)"
verify_dozzle_labels paperless broker "$(mac_container_name paperless-redis)" \
  db "$(mac_container_name paperless-postgres)" \
  webserver "$(mac_container_name paperless-webserver)" \
  gotenberg "$(mac_container_name paperless-gotenberg)" \
  tika "$(mac_container_name paperless-tika)"

"$mac_hook_dir/../../run-dozzle-contract.sh" verify
"$mac_hook_dir/../../run-dozzle-contract.sh" notify
check_mixed_state=$PLATFORM_REPORT_ROOT/dozzle-check-mixed-state.txt
if [ -f "$check_mixed_state" ] && [ ! -L "$check_mixed_state" ]; then
  "$mac_hook_dir/../../run-dozzle-contract.sh" check-mixed-cleanup
fi
