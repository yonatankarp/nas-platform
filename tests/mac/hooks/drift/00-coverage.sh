#!/bin/sh
# Coverage accounting for the drift group: the roster is the exact set of drift
# hook files, in both directions. Runs no drift itself and needs no environment.
set -eu
set +x
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

# The acquisition foundation drifts shared infrastructure, not a registered service.
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
80-paperless.sh
90-nextcloud.sh'
mac_drift_coverage_neutral_hooks='15-media-acquisition-foundation.sh'

mac_assert_service_coverage drift 00-coverage.sh '' \
  'arr=its Phase 1 runtime is default-disabled in the Mac lane and proved by its Docker integration suite
downloaders=its Phase 1 runtime is default-disabled in the Mac lane and proved by its Docker integration suite
vaultwarden=the hand edit worth reproducing is a config.json written by the admin panel this platform never opens, and the converge REFUSES that file rather than repairing it, so a drift hook would be asserting a failed converge rather than a repaired one
karakeep=the one hand edit worth reproducing is opening its signup door, and that lives in the environment the converge renders rather than in state the application writes, so a drift hook would only prove a template renders; the platform_verify_karakeep tasks refuse an open door on every run' \
  "$mac_drift_hooks" "$mac_drift_coverage_neutral_hooks"
