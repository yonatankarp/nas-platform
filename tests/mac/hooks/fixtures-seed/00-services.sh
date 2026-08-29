#!/bin/sh
# Fixture seeding for every registered service, in the order the eight
# NN-service.sh hooks this replaces ran in. Only the phase name differed between
# them, so the phases are the table and the dispatch is shared.
set -eu
set +x
# Seeding writes vault-derived fixtures, which is why the Komga hook this
# replaces set the mask. It now applies to every service rather than to the one
# that happened to have it.
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

# Beszel and Dozzle have nothing to seed: their verify phase is what establishes
# the state the later phases assert against. Audiobookshelf seeds through
# seed-progress because its fixture is a playback position rather than a library.
# Jellyfin seeds media plus an unrelated library and a full-configuration
# sentinel, and Immich additionally creates the encrypted managed non-admin
# identities, applies their profiles, installs the legitimate unowned
# storageLabel sentinel and, for a partial profile, seeds a pinned supported
# preference leaf it does not own. The later drift, converge and verify phases
# prove Ansible preserves all of it.
mac_seeded=
for mac_seed_entry in beszel:verify dozzle:verify audiobookshelf:seed-progress \
    komga:seed jellyfin:seed immich:seed paperless:seed; do
  mac_seed_service=${mac_seed_entry%%:*}
  "$mac_script_dir/run-contract.sh" "$mac_seed_service" "${mac_seed_entry#*:}"
  mac_seeded="$mac_seeded$mac_seed_service
"
done

mac_assert_service_coverage fixtures-seed 00-services.sh "$mac_seeded" \
  'arr=its Phase 1 runtime is default-disabled in the Mac lane and proved by its Docker integration suite
downloaders=its Phase 1 runtime is default-disabled in the Mac lane and proved by its Docker integration suite
ntfy=it has no contract suite of its own; its fixtures are the provisioned topics
pinchflat=its only fixture would be a real YouTube download, which this lane must not make; its persisted state is the database its own run phase asserts'
