#!/bin/sh
# Persistence reassertion for every registered service, in the order the
# NN-service.sh hooks this replaces ran in. Paperless keeps its own hook because
# it does more than reassert: it drives a coordinated snapshot drill between two
# assertions. It runs after this file, exactly as 80-paperless.sh ran after 70.
set -eu
set +x
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

# Beszel and Dozzle reassert through verify: their persisted state is the
# telemetry and the alert-relay state the verify phase already polls.
mac_persisted=
for mac_persistence_entry in beszel:verify dozzle:verify \
    audiobookshelf:assert-persistence komga:assert-persistence \
    jellyfin:assert-persistence \
    immich:assert-persistence; do
  mac_persistence_service=${mac_persistence_entry%%:*}
  "$mac_script_dir/run-contract.sh" "$mac_persistence_service" "${mac_persistence_entry#*:}"
  mac_persisted="$mac_persisted$mac_persistence_service
"
done

mac_assert_service_coverage fixtures-persistence 00-services.sh "$mac_persisted" \
  'arr=its Phase 1 runtime is default-disabled in the Mac lane and proved by its Docker integration suite
downloaders=its Phase 1 runtime is default-disabled in the Mac lane and proved by its Docker integration suite
ntfy=it has no contract suite of its own to reassert persistence with'
