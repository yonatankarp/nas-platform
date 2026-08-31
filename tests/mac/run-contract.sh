#!/bin/sh
# One Mac wrapper for every contract suite.
#
# This replaces eight near-identical run-<service>-contract.sh wrappers whose
# shared plumbing had drifted apart: two guarded their environment with the bare
# `:?` form and six with a message, each required a different subset of the same
# variables, two pinned PLATFORM_KIND and six did not, and four carried their own
# copy of the lane-to-container-name case statement.
#
# tests/contracts/registry.yml resolves the service argument to its contract, so
# the service-to-script mapping is not duplicated here. What the registry cannot
# hold is the per-service part of the Mac environment: its entries are
# constrained to exactly a service and a path by both tests/policy_test.rb and
# tests/run_contracts.rb, so the port variable, the runtime context and the
# container identities live in the table at the bottom of this script instead.
# Everything above that table is shared by every service.
set -eu
set +x
# The suites write vault-derived fixtures and diagnostics under
# PLATFORM_REPORT_ROOT, and tests/mac/hooks/drift/20-dozzle.sh asserts mode 600
# on the files created beneath it. Every hook that creates such a file already
# set this mask; it now applies to every service rather than to the ones that
# happened to inherit it.
umask 077

mac_script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

[ "$#" -ge 2 ] || mac_die 'usage: run-contract.sh SERVICE PHASE [ARGUMENT...]'
mac_service=$1
mac_phase=$2
shift 2

# The wrappers this replaces let the phase default (verify for Beszel and Dozzle,
# run for the rest), so a caller that lost its argument still ran a suite, just
# not the one it meant to. A missing or malformed phase is refused instead.
# Which phases a suite accepts stays the suite's own business: every contract
# already refuses an unknown mode, and that refusal is the single authority
# rather than a second list here that would drift away from it.
case $mac_phase in
  *[!abcdefghijklmnopqrstuvwxyz0123456789-]*|-*|*-)
    mac_die "Mac contract phase is invalid: $mac_phase"
    ;;
esac

# An unknown service is refused before any environment is touched. This is the
# guard that matters most in a collapse this size: a typo must stop the lane
# rather than dispatch nothing and report success.
mac_contract_path=$(mac_registry_contract_path "$mac_service")

# tests/mac/run.sh exports all of these for every phase, and
# tests/policy_mac_test.rb pins that it does. The wrappers this replaces each
# required a different subset for no recorded reason, so requiring the union is
# strictly stronger and removes eight lists that had to be kept in step by hand.
: "${PLATFORM_MAC_VAULT_FILE:?PLATFORM_MAC_VAULT_FILE is required}"
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?PLATFORM_MAC_VAULT_PASSWORD_FILE is required}"
: "${PLATFORM_DOCKER_ROOT:?PLATFORM_DOCKER_ROOT is required}"
: "${PLATFORM_MEDIA_ROOT:?PLATFORM_MEDIA_ROOT is required}"
: "${PLATFORM_FIXTURE_ROOT:?PLATFORM_FIXTURE_ROOT is required}"
: "${PLATFORM_REPORT_ROOT:?PLATFORM_REPORT_ROOT is required}"
: "${PLATFORM_PROJECT_NAME:?PLATFORM_PROJECT_NAME is required}"
: "${PLATFORM_NTFY_PORT:?PLATFORM_NTFY_PORT is required}"

# run.sh exports PLATFORM_KIND for the lane it is proving, and the Komga contract
# reads it to tell the integration lane from the Mac one. The two wrappers that
# hard-coded PLATFORM_KIND=mac would have overridden that for themselves;
# defaulting keeps the lane visible while still guaranteeing a value to a
# contract invoked outside run.sh, which the Beszel contract needs because its
# own default is nas and that demands GPU telemetry no Mac has.
: "${PLATFORM_KIND:=mac}"
export PLATFORM_KIND

PLATFORM_CONTRACT_VAULT_FILE=$PLATFORM_MAC_VAULT_FILE
PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=$PLATFORM_MAC_VAULT_PASSWORD_FILE
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE

set -- "$mac_phase" "$@"

# The per-service table. A service the registry knows but this table does not is
# refused rather than run with an incomplete environment, which is the other half
# of the unknown-service guard: adding a contract to the registry without giving
# it a Mac environment fails loudly here.
case $mac_service in
  audiobookshelf)
    : "${PLATFORM_AUDIOBOOKSHELF_PORT:?PLATFORM_AUDIOBOOKSHELF_PORT is required}"
    ;;
  beszel)
    : "${PLATFORM_BESZEL_PORT:?PLATFORM_BESZEL_PORT is required}"
    ;;
  dozzle)
    : "${PLATFORM_DOZZLE_PORT:?PLATFORM_DOZZLE_PORT is required}"
    ;;
  immich)
    : "${PLATFORM_IMMICH_PORT:?PLATFORM_IMMICH_PORT is required}"
    PLATFORM_IMMICH_SERVER_CONTAINER=$(mac_container_name immich-server)
    PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER=$(mac_container_name immich-machine-learning)
    PLATFORM_IMMICH_REDIS_CONTAINER=$(mac_container_name immich-redis)
    PLATFORM_IMMICH_POSTGRES_CONTAINER=$(mac_container_name immich-postgres)
    export PLATFORM_IMMICH_SERVER_CONTAINER PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER
    export PLATFORM_IMMICH_REDIS_CONTAINER PLATFORM_IMMICH_POSTGRES_CONTAINER
    # Immich and Jellyfin are the two contracts that take a platform option, and
    # both Mac lanes prove Mac-shaped deployment: mac_ansible_playbook converges
    # the integration lane with platform_kind=mac as well. The option is passed
    # unconditionally here exactly as those two wrappers passed it.
    set -- --platform mac "$@"
    ;;
  jellyfin)
    : "${PLATFORM_JELLYFIN_PORT:?PLATFORM_JELLYFIN_PORT is required}"
    PLATFORM_JELLYFIN_CONTAINER=$(mac_container_name jellyfin)
    export PLATFORM_JELLYFIN_CONTAINER
    set -- --platform mac "$@"
    ;;
  komga)
    : "${PLATFORM_KOMGA_PORT:?PLATFORM_KOMGA_PORT is required}"
    # Komga is the one suite whose runtime expectations differ by lane: the
    # integration lane runs the base image and the Mac lane the managed one.
    if [ "${PLATFORM_KIND:-}" = integration ]; then
      PLATFORM_KOMGA_RUNTIME_CONTEXT=base
    else
      PLATFORM_KOMGA_RUNTIME_CONTEXT=mac-managed
    fi
    export PLATFORM_KOMGA_RUNTIME_CONTEXT
    ;;
  paperless)
    : "${PLATFORM_PAPERLESS_PORT:?PLATFORM_PAPERLESS_PORT is required}"
    PLATFORM_PAPERLESS_WEBSERVER_CONTAINER=$(mac_container_name paperless-webserver)
    export PLATFORM_PAPERLESS_WEBSERVER_CONTAINER
    ;;
  bindery)
    : "${PLATFORM_BINDERY_PORT:?PLATFORM_BINDERY_PORT is required}"
    ;;
  kapowarr)
    : "${PLATFORM_KAPOWARR_PORT:?PLATFORM_KAPOWARR_PORT is required}"
    ;;
  pinchflat)
    : "${PLATFORM_PINCHFLAT_PORT:?PLATFORM_PINCHFLAT_PORT is required}"
    ;;
  *) mac_die "registered service has no Mac contract environment: $mac_service" ;;
esac

exec "$mac_repo_dir/$mac_contract_path" "$@"
