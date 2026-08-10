#!/bin/sh
set -eu
set +x
umask 077
dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
exec ruby "$dir/adoption-baseline.rb" --emit-probe ntfy
