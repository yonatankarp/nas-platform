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
"$mac_hook_dir/../../run-beszel-contract.sh" verify
