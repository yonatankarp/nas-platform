#!/bin/sh
# Fixture seeding for every registered service.
set -eu
set +x
# Seeding writes vault-derived fixtures.
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

# Beszel and Dozzle establish their state in verify; later phases prove Ansible
# preserves every seeded fixture.
mac_seeded=
for mac_seed_entry in beszel:verify dozzle:verify audiobookshelf:seed-progress \
    komga:seed jellyfin:seed immich:seed paperless:seed; do
  mac_seed_service=${mac_seed_entry%%:*}
  "$mac_script_dir/run-contract.sh" "$mac_seed_service" "${mac_seed_entry#*:}"
  mac_seeded="$mac_seeded$mac_seed_service
"
done

# Nextcloud's restore-rehearsal pair needs a forced-backup converge between halves,
# which this lane has no phase for; the converge creates everything later asserted.
mac_assert_service_coverage fixtures-seed 00-services.sh "$mac_seeded" \
  'arr=its Phase 1 runtime is default-disabled in the Mac lane and proved by its Docker integration suite
downloaders=its Phase 1 runtime is default-disabled in the Mac lane and proved by its Docker integration suite
pinchflat=its only fixture would be a real YouTube download, which this lane must not make; its persisted state is the database its own run phase asserts
kapowarr=its only fixture would be a real comic download, which needs a ComicVine account this lane cannot hold; its persisted state is the database its own run phase asserts
bindery=its only fixture would be a real Usenet download, which this lane has no transport for; its persisted state is the database its own run phase asserts
trailarr=its only fixture would be a real trailer download from YouTube, which this lane must not make; its persisted state is the database and the application environment its own run phase asserts
seerr=its fixtures are the two permission identities the converge itself creates, and a request fixture would ask Radarr and Sonarr for a real download this lane has no transport for; its persisted state is the database its own run phase asserts
nextcloud=its contract declares only static and run, so there is no seed phase to dispatch; every state its later phases assert is state the converge itself created -- the administrator the installer fixes on first start, the cluster behind it, and the trusted domains the role reconciles
vaultwarden=there is nothing this platform could seed: master passwords are user-owned and the server never learns them, so the only fixture would be a real account, and every state its verification asserts -- the door, the published origin, the absent config.json -- is state the converge itself established
karakeep=it has no contract suite of its own to dispatch a seed phase to, and every state its verification asserts -- the administrator, the closed signup door, the search index and browser connections -- is state the converge itself established; a bookmark fixture would make chrome fetch a real page'
