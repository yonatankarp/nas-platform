#!/bin/sh
set -eu
set +x
umask 077
dir=${PLATFORM_ADOPTION_SCRIPT_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)}
sandbox=${PLATFORM_MAC_SANDBOX:?}
project=${PLATFORM_PROJECT_NAME:?}
if [ "${PLATFORM_ADOPTION_PROBE_TARGET:-false}" = true ]; then
  webserver_container=$project-paperless-webserver
else
  webserver_container=$project-legacy-paperless-ngx-webserver-1
fi
export PLATFORM_CONTRACT_VAULT_FILE=${PLATFORM_MAC_VAULT_FILE:?}
export PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=${PLATFORM_MAC_VAULT_PASSWORD_FILE:?}
if ! PLATFORM_PAPERLESS_CONSUME_ROOT="$sandbox/legacy/paperless-ngx/consume" \
  PLATFORM_PAPERLESS_EXPORT_ROOT="$sandbox/legacy/paperless-ngx/export" \
  PLATFORM_CONTRACT_REPO_DIR="$dir/../.." \
  PLATFORM_PAPERLESS_WEBSERVER_CONTAINER="$webserver_container" \
  "$dir/../contracts/paperless.sh" assert-persistence >/dev/null 2>&1; then
  printf '%s\n' 'adoption-probe-error: paperless-ngx evidence unavailable' >&2
  exit 1
fi
exec ruby "${PLATFORM_ADOPTION_BASELINE_FILE:-$dir/adoption-baseline.rb}" --emit-probe paperless-ngx
