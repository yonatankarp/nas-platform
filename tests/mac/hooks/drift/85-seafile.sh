#!/bin/sh
# Seafile's drift is `[INDEX FILES] enabled` in the event configuration the
# server writes into its own bind mount, and it is the only setting in this
# service that a hand edit can change and a converge can take back.
#
# Why it is the right one. Seafile Pro's own generator writes that key as true
# and puts es_host = elasticsearch beside it. This platform deploys no
# Elasticsearch, so left alone the index updater resolves an unresolvable
# hostname every ten minutes for as long as the server runs.
# roles/seafile/tasks/reconcile_seafevents.yml repairs the key in place and
# restarts the application container onto the repaired file, and that repair is
# the whole reason the reconciliation exists.
#
# Why the refusal comes from the contract and not from verify.yml, which is what
# every other hook in this group uses. roles/seafile's verification proves the
# thing worth proving about Seafile -- POST /api2/auth-token/, a real ccnet_db
# and seahub_db round trip rather than a port probe -- and it proves nothing
# about the event configuration. Nor could a hand edit to it be repaired by the
# other things verify.yml can see: the two failures it names, a broken database
# link and a rotated administrator password, are respectively not drift and, by
# the image's own design, not repairable by converging at all. So this hook asks
# the party that does read the file. The Seafile contract's run phase asserts
# that the container and host copies are one file and that the key says false,
# and it is the same phase 30-services.sh runs after the reconcile -- so the
# refusal here and the proof of repair there are the same assertion, made twice
# either side of a converge.
#
# The drift is deliberately left in place: the reconcile phase converges, and the
# verify that follows it is what proves the platform took it back.
set -eu
set +x
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

: "${PLATFORM_DOCKER_ROOT:?PLATFORM_DOCKER_ROOT is required}"
: "${PLATFORM_REPORT_ROOT:?PLATFORM_REPORT_ROOT is required}"
: "${PLATFORM_SEAFILE_PORT:?PLATFORM_SEAFILE_PORT is required}"
: "${PLATFORM_MAC_VAULT_FILE:?PLATFORM_MAC_VAULT_FILE is required}"
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?PLATFORM_MAC_VAULT_PASSWORD_FILE is required}"

expected_failure=$(mktemp "$PLATFORM_REPORT_ROOT/seafile-contract-drift.XXXXXX")
trap 'unlink "$expected_failure" >/dev/null 2>&1 || true' EXIT HUP INT TERM

# Resolved through the shared helper rather than by pasting the project prefix,
# which is what every other Mac caller of a container identity now does.
PLATFORM_SEAFILE_CONTAINER=$(mac_container_name seafile)
export PLATFORM_SEAFILE_CONTAINER

# The mutation is 85-seafile.rb beside this file, resolved from this hook's own
# directory rather than from any tree an argument supplies, with standard input
# held at end-of-file so a sibling program cannot inherit the hook's.
"$mac_hook_dir/85-seafile.rb" </dev/null

if "$mac_script_dir/run-contract.sh" seafile run >"$expected_failure" 2>&1; then
  printf '%s\n' 'the Seafile contract accepted hand-enabled file indexing' >&2
  exit 1
fi
"$mac_repo_dir/tests/assert-no-vault-secrets.rb" \
  "$PLATFORM_MAC_VAULT_FILE" "$PLATFORM_MAC_VAULT_PASSWORD_FILE" "$expected_failure"
grep -qF 'Seafile file indexing is true in the deployed seafevents.conf' \
  "$expected_failure" || {
  printf '%s\n' 'the Seafile contract refused drift without its fixed diagnostic' >&2
  exit 1
}

printf '%s\n' 'Seafile drift: hand-enabled file indexing is rejected until the platform reconverges'
