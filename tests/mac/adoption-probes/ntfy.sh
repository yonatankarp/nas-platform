#!/bin/sh
set -eu
set +x
umask 077
dir=${PLATFORM_ADOPTION_SCRIPT_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)}
project=${PLATFORM_PROJECT_NAME:?}
if [ "${PLATFORM_ADOPTION_PROBE_TARGET:-false}" = true ]; then
  export PLATFORM_ADOPTION_NTFY_CONTAINER=$project-ntfy
  export PLATFORM_ADOPTION_NTFY_ENV_FILE=${PLATFORM_DOCKER_ROOT:?}/nas-platform/runtime/services/ntfy/.env
fi
exec ruby "${PLATFORM_ADOPTION_BASELINE_FILE:-$dir/adoption-baseline.rb}" --emit-probe ntfy
