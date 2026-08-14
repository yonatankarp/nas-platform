#!/bin/sh
set -eu

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# The seed mode also creates the encrypted managed non-admin identities, applies
# their profiles, installs the legitimate unowned storageLabel sentinel, and,
# for a partial profile, seeds a pinned supported preference leaf it does not own.
"$mac_hook_dir/../../run-immich-contract.sh" seed
