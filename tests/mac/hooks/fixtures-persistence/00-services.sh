#!/bin/sh
# Persistence reassertion for every registered service. Paperless keeps its own
# hook (a snapshot drill between two assertions), which runs after this file.
set -eu
set +x
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

# Services without a seeded fixture reassert through verify or run, whose state is
# the persisted store; Nextcloud's also covers the /var/www/html tree cron shares.
mac_persisted=
for mac_persistence_entry in beszel:verify dozzle:verify \
    audiobookshelf:assert-persistence komga:assert-persistence \
    jellyfin:assert-persistence \
    immich:assert-persistence pinchflat:run kapowarr:run bindery:run trailarr:run \
    seerr:run nextcloud:run; do
  mac_persistence_service=${mac_persistence_entry%%:*}
  "$mac_script_dir/run-contract.sh" "$mac_persistence_service" "${mac_persistence_entry#*:}"
  mac_persisted="$mac_persisted$mac_persistence_service
"
done

mac_assert_service_coverage fixtures-persistence 00-services.sh "$mac_persisted" \
  'arr=its Phase 1 runtime is default-disabled in the Mac lane and proved by its Docker integration suite
downloaders=its Phase 1 runtime is default-disabled in the Mac lane and proved by its Docker integration suite
vaultwarden=it has no contract suite of its own to reassert persistence with; what must survive a recreate is the SQLite store the converge created, and the verification play run after this phase reads the server that store belongs to
karakeep=it has no contract suite of its own to reassert persistence with; what must survive a recreate is the administrator in db.db on its data root, and the verification play run after this phase signs in as that account'
