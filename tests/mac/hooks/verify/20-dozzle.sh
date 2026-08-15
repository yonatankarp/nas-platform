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

case ${PLATFORM_PROOF_PLATFORM:-mac} in
  integration)
    verify_dozzle_labels '' audiobookshelf audiobookshelf
    verify_dozzle_labels beszel hub beszel agent-portable beszel_agent_portable \
      socket-proxy beszel_socket_proxy
    verify_dozzle_labels dozzle alert-relay dozzle_alert_relay \
      dozzle dozzle socket-proxy dozzle_socket_proxy
    verify_dozzle_labels immich immich-server immich_server \
      immich-machine-learning immich_machine_learning redis immich_redis \
      database immich_postgres
    verify_dozzle_labels '' jellyfin jellyfin
    verify_dozzle_labels '' komga komga
    verify_dozzle_labels '' ntfy ntfy
    verify_dozzle_labels paperless broker paperless_redis db paperless_postgres \
      webserver paperless_webserver gotenberg paperless_gotenberg tika paperless_tika
    verify_dozzle_labels '' tinymediamanager tinymediamanager
    ;;
  mac)
    verify_dozzle_labels '' audiobookshelf "$PLATFORM_PROJECT_NAME-audiobookshelf"
    verify_dozzle_labels beszel hub "$PLATFORM_PROJECT_NAME-beszel" \
      agent-portable "$PLATFORM_PROJECT_NAME-beszel-agent-portable" \
      socket-proxy "$PLATFORM_PROJECT_NAME-beszel-socket-proxy"
    verify_dozzle_labels dozzle alert-relay "$PLATFORM_PROJECT_NAME-dozzle-alert-relay" \
      dozzle "$PLATFORM_PROJECT_NAME-dozzle" \
      socket-proxy "$PLATFORM_PROJECT_NAME-dozzle-socket-proxy"
    verify_dozzle_labels immich immich-server "$PLATFORM_PROJECT_NAME-immich-server" \
      immich-machine-learning "$PLATFORM_PROJECT_NAME-immich-machine-learning" \
      redis "$PLATFORM_PROJECT_NAME-immich-redis" database "$PLATFORM_PROJECT_NAME-immich-postgres"
    verify_dozzle_labels '' jellyfin "$PLATFORM_PROJECT_NAME-jellyfin"
    verify_dozzle_labels '' komga "$PLATFORM_PROJECT_NAME-komga"
    verify_dozzle_labels '' ntfy "$PLATFORM_PROJECT_NAME-ntfy"
    verify_dozzle_labels paperless broker "$PLATFORM_PROJECT_NAME-paperless-redis" \
      db "$PLATFORM_PROJECT_NAME-paperless-postgres" \
      webserver "$PLATFORM_PROJECT_NAME-paperless-webserver" \
      gotenberg "$PLATFORM_PROJECT_NAME-paperless-gotenberg" \
      tika "$PLATFORM_PROJECT_NAME-paperless-tika"
    verify_dozzle_labels '' tinymediamanager "$PLATFORM_PROJECT_NAME-tinymediamanager"
    ;;
  *) mac_die 'proof platform is invalid' ;;
esac

"$mac_hook_dir/../../run-dozzle-contract.sh" verify
"$mac_hook_dir/../../run-dozzle-contract.sh" notify
check_mixed_state=$PLATFORM_REPORT_ROOT/dozzle-check-mixed-state.txt
if [ -f "$check_mixed_state" ] && [ ! -L "$check_mixed_state" ]; then
  "$mac_hook_dir/../../run-dozzle-contract.sh" check-mixed-cleanup
fi
