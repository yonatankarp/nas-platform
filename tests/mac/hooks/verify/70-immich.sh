#!/bin/sh
set -eu

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# Runtime verification covers every effective managed-user preference leaf and
# any seeded supported unowned leaf, in addition to login, assets, settings,
# and containment.
"$mac_hook_dir/../../run-immich-contract.sh" run
