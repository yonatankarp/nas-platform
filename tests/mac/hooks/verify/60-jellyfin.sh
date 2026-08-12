#!/bin/sh
set -eu

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# Includes exact identity, server name, avatar bytes, both owned libraries, and
# survival of the unmanaged library/configuration sentinel.
"$mac_hook_dir/../../run-jellyfin-contract.sh" run
