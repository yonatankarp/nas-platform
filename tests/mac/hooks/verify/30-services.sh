#!/bin/sh
# Runtime verification for the six services whose verify hook was nothing but a
# dispatch to their contract's run phase, in the order 30-audiobookshelf.sh
# through 80-paperless.sh ran in. Beszel, ntfy and Dozzle keep their own hooks
# because theirs assert more than the contract does: Beszel runs two phases, ntfy
# has no contract suite and verifies its provisioned subscriptions inline, and
# Dozzle inspects every proof container's display labels before its phases. Those
# three sort ahead of this file and so still run first.
set -eu
set +x
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

# Jellyfin's run covers exact identity, acceleration, repositories, active
# plugins, Open Subtitles validation, both owned libraries and unrelated
# sentinels. Immich's covers every effective managed-user preference leaf and any
# seeded supported unowned leaf, in addition to login, assets, settings and
# containment. Pinchflat's covers container health, the three
# basic-authentication outcomes, and its persisted database. Kapowarr's covers
# the same three outcomes against its own login, the comics library root it
# owns, and its persisted database. Bindery's covers its closed first-run setup,
# the ebook and audiobook roots it owns separately, both configured directories
# being writable by the identity the container was given, and its own database.
# Trailarr's covers the same three access outcomes against its API key and its
# published default administrator, and the one thing no other service has: that
# the application's own /config/.env carries the platform's keys and none of the
# ones only a hand edit writes.
#
# Nextcloud's run covers four healthy containers, an installed instance out of
# maintenance mode with no unfinished database upgrade, and then the three
# claims #500 exists to settle: that the database account is the vault's own
# rather than the oc_admin the installer mints when NC_setup_create_db_user is
# unset, that the reconciled trusted domains hold, and that the administrator
# authenticates while a password the vault never authored is refused. It also
# proves the cron sidecar is the thing running the background jobs, which is the
# one claim no other service here has a shape for. It runs last, which is where
# site.yml converges it.
mac_verified=
for mac_verify_service in audiobookshelf komga jellyfin immich paperless pinchflat kapowarr \
    bindery trailarr seerr nextcloud; do
  "$mac_script_dir/run-contract.sh" "$mac_verify_service" run
  mac_verified="$mac_verified$mac_verify_service
"
done

mac_assert_service_coverage verify 30-services.sh "$mac_verified" \
  'arr=its Phase 1 runtime is default-disabled in the Mac lane and proved by its Docker integration suite
downloaders=its Phase 1 runtime is default-disabled in the Mac lane and proved by its Docker integration suite
adguard=#548 landed it with adguard_deployment_enabled false and tests/mac/lib.sh does not ask this lane to turn it on, so the converge takes the project to state: absent and there is no stack here to exercise; it is proved by its Docker integration suite' \
  "$MAC_VERIFY_INFRASTRUCTURE_HOOKS" "$MAC_VERIFY_COVERAGE_NEUTRAL_HOOKS"
