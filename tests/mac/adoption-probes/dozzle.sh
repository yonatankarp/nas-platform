#!/bin/sh
set -eu
set +x
umask 077
dir=${PLATFORM_ADOPTION_SCRIPT_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)}
if ! "$dir/run-dozzle-contract.sh" verify >/dev/null 2>&1; then
  printf '%s\n' 'adoption-probe-error: dozzle evidence unavailable' >&2
  exit 1
fi
exec ruby "$dir/adoption-baseline.rb" --emit-probe dozzle
