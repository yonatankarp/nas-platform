#!/bin/sh
# Runtime verification for the services whose verify hook is just their contract's
# run phase. Beszel and Dozzle keep their own hooks, which sort ahead of this file.
set -eu
set +x
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

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
vaultwarden=it has no contract suite of its own, because it reads no vault credential to sign in with; the Mac lane verifies it through the platform_verify_vaultwarden tasks tests/mac/verify.sh runs, which knock on its registration door and compare the running version against the pin
karakeep=it has no contract suite of its own; the Mac lane verifies it through the platform_verify_karakeep tasks tests/mac/verify.sh runs, which sign in as the vault administrator and require the search index and browser connected and the signup door closed' \
  "$MAC_VERIFY_INFRASTRUCTURE_HOOKS" "$MAC_VERIFY_COVERAGE_NEUTRAL_HOOKS"
