#!/bin/sh
# Coverage accounting for pre-converge: a service belongs here only when its
# converge reads fixture state off disk (Audiobookshelf's initial scan). The roster
# and the exemption list are exact both ways, so a new service must answer here.
set -eu
set +x
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

mac_pre_converge_hooks='30-audiobookshelf.sh'

mac_assert_service_coverage pre-converge 00-coverage.sh '' \
  'arr=its Phase 1 runtime is default-disabled in the Mac lane and proved by its Docker integration suite
downloaders=its Phase 1 runtime is default-disabled in the Mac lane and proved by its Docker integration suite
beszel=its converge places the hub keypair from the vault and reads nothing off disk; its state is established by the verify phase
dozzle=its converge renders the users file and the dispatcher record itself and reads nothing off disk; its state is established by the verify phase
komga=its converge creates the managed library but does not wait on a scan of its contents, so its media seeds after deploy in fixtures-seed
jellyfin=its converge creates the managed library and schedules a periodic refresh but does not wait on a scan of its contents, so its media seeds after deploy in fixtures-seed
immich=its converge creates the managed identities but reads no media, so its fixtures seed after deploy in fixtures-seed
paperless=its converge configures consumption but does not wait on a document, so its fixtures seed after deploy in fixtures-seed
pinchflat=its only fixture would be a real YouTube download, which this lane must not make, so its converge has nothing to read
kapowarr=its only fixture would be a real comic download, which needs a ComicVine account this lane cannot hold, so its converge has nothing to read
bindery=its only fixture would be a real Usenet download, which this lane has no transport for, so its converge has nothing to read
trailarr=its only fixture would be a real trailer download from YouTube, which this lane must not make, so its converge has nothing to read
seerr=its fixtures are the two permission identities the converge itself creates, so there is nothing for it to read off disk first
nextcloud=the installer writes config.php on first start and the converge reconciles the trusted domains inside it afterwards, so nothing has to exist on disk before run_site
vaultwarden=its converge reads nothing off disk: the store belongs to the container and the environment it is given is rendered by the converge itself
karakeep=its converge reads nothing off disk first: the administrator is registered through the API by the converge itself, and the environment it starts on is rendered by the converge too' \
  "$mac_pre_converge_hooks" ''
