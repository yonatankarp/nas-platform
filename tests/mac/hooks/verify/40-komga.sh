#!/bin/sh
set -eu
set +x

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
"$mac_hook_dir/../../run-komga-contract.sh" run
