#!/bin/sh
set -eu
set +x

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
source=$(cat "$repo_dir/tests/mac/cleanup.sh")

fail() {
  printf 'media-acquisition-cleanup-error: %s\n' "$1" >&2
  exit 1
}

for token in \
  'media_acquisition_cleanup_network=$mac_project-media-control' \
  'nas.platform.purpose=media-control' \
  'nas.platform.project=$mac_project' \
  'docker network rm "$media_acquisition_cleanup_network"'; do
  printf '%s\n' "$source" | grep -Fq "$token" || fail "cleanup omits $token"
done
printf '%s\n' "$source" | grep -Eq 'docker (system|network) prune' && fail 'cleanup must not prune'
printf '%s\n' "$source" | grep -Eq 'media_acquisition_cleanup_network=.*media-control$' ||
  fail 'cleanup network must be project-derived'
printf '%s\n' "$source" | grep -Fq '[ -n "$mac_project" ]' || fail 'cleanup must reject an empty project'

printf '%s\n' 'media acquisition cleanup: exact derived network contract holds'
