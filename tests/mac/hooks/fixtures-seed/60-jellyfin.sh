#!/bin/sh
set -eu

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# Seeds media plus an unrelated library and full-configuration sentinel. The
# later drift/converge/verify phases prove Ansible preserves all three.
"$mac_hook_dir/../../run-jellyfin-contract.sh" seed
