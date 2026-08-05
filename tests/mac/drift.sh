#!/bin/sh
set -eu

mac_script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$mac_script_dir/lib.sh"

[ "$#" -eq 0 ] || mac_die 'usage: drift.sh'
mac_run_hooks drift
