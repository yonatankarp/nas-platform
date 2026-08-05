#!/bin/sh
set -eu

mac_script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$mac_script_dir/lib.sh"

case ${1-} in
  seed|recreate|persistence) mac_run_hooks "fixtures-$1" ;;
  *) mac_die 'usage: fixtures.sh seed|recreate|persistence' ;;
esac
