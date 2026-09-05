#!/bin/sh
# Coverage accounting for the drift group, and nothing else.
#
# The other four service-bearing groups collapsed into one table-driven hook and
# account for themselves against tests/contracts/registry.yml. Drift did not
# collapse, because no two services drift alike, so it kept one file per service
# and with it the assumption that a missing file is visible. It is not:
# mac_run_hooks refuses a group with no files at all, and cannot tell thirteen
# hooks from eight. Five acquisition services were promoted with a drift hook
# each and nothing anywhere named them, which is the state this file ends.
#
# The roster below is the exact set of drift hook files. It is exact in both
# directions: a hook deleted and a hook added both fail here, so promoting a
# service has to touch this file, and retiring one has to touch it too. The
# drift phase is the one that proves a hand edit gets reverted, which is the
# repository's central claim, so a service absent from it is a service whose
# central claim is untested on this lane.
#
# This hook runs no drift of its own and needs no environment, which is what
# lets tests/mac/hook-coverage-test.sh run it against a stub tree.
set -eu
set +x
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

# The media acquisition foundation drifts shared infrastructure rather than a
# registered service, so it is named coverage-neutral rather than credited as
# one, exactly as the verify group names its own copy of that hook.
mac_drift_hooks='10-beszel.sh
15-media-acquisition-foundation.sh
20-dozzle.sh
30-audiobookshelf.sh
40-komga.sh
50-pinchflat.sh
55-kapowarr.sh
56-bindery.sh
57-trailarr.sh
58-seerr.sh
60-jellyfin.sh
70-immich.sh
80-paperless.sh'
mac_drift_coverage_neutral_hooks='15-media-acquisition-foundation.sh'

mac_assert_service_coverage drift 00-coverage.sh '' \
  'arr=its Phase 1 runtime is default-disabled in the Mac lane and proved by its Docker integration suite
downloaders=its Phase 1 runtime is default-disabled in the Mac lane and proved by its Docker integration suite
ntfy=no hand edit to its own provisioning is reproduced here; the ntfy-facing state this lane drifts is the Dozzle dispatcher record, which 20-dozzle.sh drifts and requires verification to refuse' \
  "$mac_drift_hooks" "$mac_drift_coverage_neutral_hooks"
