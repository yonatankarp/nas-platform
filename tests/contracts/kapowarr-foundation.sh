#!/bin/sh
set -eu

project=$(basename -- "$0" -foundation.sh)
case $project in
  arr|downloaders|bindery|kapowarr|pinchflat|trailarr|seerr) ;;
  *) printf '%s\n' 'unknown media acquisition foundation project' >&2; exit 2 ;;
esac
mode=${1:-static}
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)}
[ "$mode" = static ] || { printf '%s\n' "$project foundation contract accepts only static" >&2; exit 2; }
ruby "$repo_dir/tests/media_acquisition_foundation_test.rb" --project "$project"
