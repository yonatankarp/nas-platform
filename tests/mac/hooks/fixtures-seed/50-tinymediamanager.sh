#!/bin/sh
set -eu

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
"$mac_hook_dir/../../run-tinymediamanager-contract.sh" seed
