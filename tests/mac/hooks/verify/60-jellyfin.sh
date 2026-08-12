#!/bin/sh
set -eu

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# Includes exact identity, acceleration, repositories, active plugins,
# Open Subtitles validation, both owned libraries, and unrelated sentinels.
"$mac_hook_dir/../../run-jellyfin-contract.sh" run
