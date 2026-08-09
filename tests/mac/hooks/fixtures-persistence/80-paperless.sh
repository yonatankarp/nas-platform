#!/bin/sh
set -eu

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
"$mac_hook_dir/../../run-paperless-contract.sh" assert-persistence

snapshot_dir=$PLATFORM_REPORT_ROOT/paperless-coordinated-snapshot
[ ! -e "$snapshot_dir" ] && [ ! -L "$snapshot_dir" ]
mkdir -m 0700 "$snapshot_dir"
"$mac_hook_dir/../../snapshot-paperless.sh" drill "$snapshot_dir"
"$mac_hook_dir/../../run-paperless-contract.sh" assert-persistence
