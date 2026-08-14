#!/bin/sh
set -eu

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# The verify contract authenticates and polls persisted system_stats and
# container_stats telemetry; container health alone is not accepted.
"$mac_hook_dir/../../run-beszel-contract.sh" verify
"$mac_hook_dir/../../run-beszel-contract.sh" notify
