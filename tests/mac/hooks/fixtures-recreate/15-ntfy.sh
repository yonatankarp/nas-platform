#!/bin/sh
set -eu

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
stop_failed_adoption_recreation() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$status" -ne 0 ] && [ "$PLATFORM_PROOF_LANE" = adoption ]; then
    "$mac_hook_dir/../../adoption-stop-targets.sh" >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap stop_failed_adoption_recreation EXIT HUP INT TERM
current=$PLATFORM_DOCKER_ROOT/nas-platform/current/services/ntfy
runtime=$PLATFORM_DOCKER_ROOT/nas-platform/runtime/services/ntfy/.env

set -- docker compose --project-name "$PLATFORM_PROJECT_NAME-ntfy" \
  --env-file "$runtime" -f "$current/compose.yml" -f "$current/compose.mac.yml"
[ "$PLATFORM_PROOF_LANE" != adoption ] || set -- "$@" -f "$current/compose.adoption.yml"
"$@" up -d --force-recreate --wait ntfy
[ "$PLATFORM_PROOF_LANE" != adoption ] || "$mac_hook_dir/../../adoption-container-attest.sh"
