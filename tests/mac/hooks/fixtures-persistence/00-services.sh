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
# telemetry and the alert-relay state the verify phase already polls. Pinchflat
# reasserts through run for the same reason: it seeds no fixture, and its
# persisted state is the database that phase already reads. Kapowarr, Bindery
# and Trailarr are the same shape, and so is Seafile: it seeds no fixture here,
# and what has to survive the recreate is the three databases its run phase
# authenticates against and the event configuration that phase reads back off the
# bind mount. Nextcloud is that shape too, with one difference worth naming: what
# must survive is the PostgreSQL cluster its run phase authenticates against and
# the installation tree under /var/www/html that the application and its cron
# sidecar share, because a cron container that came back onto an empty volume
# would run cron.php against an installation that is not there.
mac_persisted=
for mac_persistence_entry in beszel:verify dozzle:verify \
    audiobookshelf:assert-persistence komga:assert-persistence \
    jellyfin:assert-persistence \
    immich:assert-persistence pinchflat:run kapowarr:run bindery:run trailarr:run \
    seerr:run seafile:run nextcloud:run; do
  mac_persistence_service=${mac_persistence_entry%%:*}
  "$mac_script_dir/run-contract.sh" "$mac_persistence_service" "${mac_persistence_entry#*:}"
  mac_persisted="$mac_persisted$mac_persistence_service
"
done

mac_assert_service_coverage fixtures-persistence 00-services.sh "$mac_persisted" \
  'arr=its Phase 1 runtime is default-disabled in the Mac lane and proved by its Docker integration suite
downloaders=its Phase 1 runtime is default-disabled in the Mac lane and proved by its Docker integration suite
ntfy=it has no contract suite of its own to reassert persistence with'
