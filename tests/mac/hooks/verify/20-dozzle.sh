#!/bin/sh
set -eu

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
"$mac_hook_dir/../../run-dozzle-contract.sh" verify
"$mac_hook_dir/../../run-dozzle-contract.sh" notify
check_mixed_state=$PLATFORM_REPORT_ROOT/dozzle-check-mixed-state.txt
if [ -f "$check_mixed_state" ] && [ ! -L "$check_mixed_state" ]; then
  "$mac_hook_dir/../../run-dozzle-contract.sh" check-mixed-cleanup
fi
