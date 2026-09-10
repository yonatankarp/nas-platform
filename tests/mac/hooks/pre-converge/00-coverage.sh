#!/bin/sh
# Coverage accounting for the pre-converge group, and nothing else.
#
# This group is not a coverage group in the sense drift is. Drift asks every
# service to prove a hand edit is reverted, so a service missing from it is a
# service whose central claim is untested. Pre-converge asks a much narrower
# question, and the answer is "no" for almost everything:
#
#   a service belongs here when its *converge* reads fixture state off disk,
#   so the fixture has to exist before run_site rather than after it.
#
# Audiobookshelf is the only one. roles/audiobookshelf/tasks/initial_scan.yml
# requests a library scan during the converge and then waits on the items that
# scan finds, so an empty media root at converge time is a converge that proves
# nothing. Every other service seeds after deploy, in fixtures-seed, which is
# the ordering tests/mac/integration-context-test.sh pins.
#
# What mac_run_hooks already caught, and what it did not. For a group of exactly
# one hook, `mac_hook_count -gt 0` does refuse a deletion, and the rename is
# refused by tests/contracts/audiobookshelf-audio-test.sh, which addresses
# 30-audiobookshelf.sh by name. The two gaps this file closes are the other
# direction and the future one: a hook *added* outside the roster runs before
# every Mac converge with nothing to say so, and a newly promoted service can be
# added to the platform without anyone being asked whether its converge needs a
# fixture on disk first. The exemption list below is where that question gets
# answered, which is why it is fifteen lines of "no" rather than a shorter file.
#
# The roster is exact in both directions: a hook deleted and a hook added both
# fail here. The exemption list is exact too, and not append-only — a service
# that later gains a pre-converge hook must have its exemption line removed, or
# mac_assert_service_coverage refuses it as stale.
#
# This hook runs no fixture of its own and needs no environment, which is what
# lets tests/mac/hook-coverage-test.sh run it against a stub tree.
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
ntfy=its users, ACLs and tokens are declared in the vault and pushed by the converge; there is no fixture to place first
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
adguard=its converge writes AdGuardHome.yaml from the vault and restarts the daemon onto it, reading nothing off disk that it did not put there itself; there is no fixture to place first' \
  "$mac_pre_converge_hooks" ''
