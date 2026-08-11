#!/bin/sh
set -eu

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

verify_dozzle_group() {
  expected_group=$1
  shift
  for container in "$@"; do
    labels=$(docker container inspect --format '{{json .Config.Labels}}' "$container") ||
      mac_die "Dozzle group verification could not inspect $container"
    DOZZLE_RUNTIME_LABELS=$labels ruby -rjson - "$expected_group" "$container" <<'RUBY'
expected_group, container = ARGV
labels = JSON.parse(ENV.fetch("DOZZLE_RUNTIME_LABELS"))
abort "#{container} has an incorrect dev.dozzle.group label" unless
  labels["dev.dozzle.group"] == expected_group
abort "#{container} retained the unmanaged Dozzle drift sentinel" if
  labels.key?("dev.dozzle.contract.sentinel")
RUBY
  done
}

case ${PLATFORM_PROOF_PLATFORM:-mac} in
  integration)
    verify_dozzle_group beszel beszel beszel_agent_portable beszel_socket_proxy
    verify_dozzle_group dozzle dozzle dozzle_socket_proxy
    verify_dozzle_group immich immich_server immich_machine_learning immich_redis immich_postgres
    verify_dozzle_group paperless paperless_redis paperless_postgres paperless_webserver \
      paperless_gotenberg paperless_tika
    ;;
  mac)
    verify_dozzle_group beszel "$PLATFORM_PROJECT_NAME-beszel" \
      "$PLATFORM_PROJECT_NAME-beszel-agent-portable" \
      "$PLATFORM_PROJECT_NAME-beszel-socket-proxy"
    verify_dozzle_group dozzle "$PLATFORM_PROJECT_NAME-dozzle" \
      "$PLATFORM_PROJECT_NAME-dozzle-socket-proxy"
    verify_dozzle_group immich "$PLATFORM_PROJECT_NAME-immich-server" \
      "$PLATFORM_PROJECT_NAME-immich-machine-learning" \
      "$PLATFORM_PROJECT_NAME-immich-redis" "$PLATFORM_PROJECT_NAME-immich-postgres"
    verify_dozzle_group paperless "$PLATFORM_PROJECT_NAME-paperless-redis" \
      "$PLATFORM_PROJECT_NAME-paperless-postgres" "$PLATFORM_PROJECT_NAME-paperless-webserver" \
      "$PLATFORM_PROJECT_NAME-paperless-gotenberg" "$PLATFORM_PROJECT_NAME-paperless-tika"
    ;;
  *) mac_die 'proof platform is invalid' ;;
esac

"$mac_hook_dir/../../run-dozzle-contract.sh" verify
"$mac_hook_dir/../../run-dozzle-contract.sh" notify
check_mixed_state=$PLATFORM_REPORT_ROOT/dozzle-check-mixed-state.txt
if [ -f "$check_mixed_state" ] && [ ! -L "$check_mixed_state" ]; then
  "$mac_hook_dir/../../run-dozzle-contract.sh" check-mixed-cleanup
fi
