#!/bin/sh
set -eu

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

# The per-container label assertions are 20-dozzle-labels.rb beside this file.
# They arrived here as a `<<'RUBY'` heredoc until #315, where sh -n, ruby -c and
# a reader could reach none of them, and the `-rjson` preload is now a require
# inside the program. tests/contracts/dozzle-alerts.rb reads that file for the
# two label names, so the contract now asserts on the assertions rather than on
# the wrapper they left. Resolve it from this hook's own checkout rather than
# from any tree an argument or the environment supplies, and hold standard input
# at end-of-file: a heredoc exhausted it by construction.
verify_dozzle_labels() {
  expected_group=$1
  shift
  while [ "$#" -gt 0 ]; do
    expected_name=$1
    container=$2
    shift 2
    labels=$(docker container inspect --format '{{json .Config.Labels}}' "$container") ||
      mac_die "Dozzle label verification could not inspect $container"
    DOZZLE_RUNTIME_LABELS=$labels \
      "$mac_repo_dir/tests/mac/hooks/verify/20-dozzle-labels.rb" \
      "$expected_group" "$expected_name" "$container" </dev/null
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
