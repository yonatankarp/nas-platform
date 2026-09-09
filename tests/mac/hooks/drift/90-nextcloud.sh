#!/bin/sh
# Nextcloud's drift is the trusted domain list, and it is the only setting in
# this service that a hand edit can change and a converge can take back.
#
# Why it is the right one. trusted_domains is the one platform-owned setting
# neither mechanism in the image can carry: NEXTCLOUD_TRUSTED_DOMAINS is read
# only by the installer, and the NC_ environment override cannot express an
# array -- it arrives as a scalar and the server then answers HTTP 400 to every
# request. roles/nextcloud/tasks/reconcile_trusted_domains.yml exists for
# exactly that gap, so drifting this setting drifts the one thing that
# reconciliation is for.
#
# WHAT THIS HOOK PROVES IS NOT WHAT THE SIBLINGS PROVE, and the difference is
# deliberate rather than an omission. Every other hook in this group plants an
# edit and proves the platform puts it back. This one cannot: the reconcile
# appends what is missing and removes nothing, because an entry an operator
# added by hand is not drift the role can distinguish from a deliberate
# addition, and removing a trusted domain is how an instance stops answering for
# somebody. So the planted `nextcloud-drift.invalid` survives the converge. What
# is proved here is that the platform-owned entry is RE-ADDED -- the repair is
# additive, and a reader expecting reversion would be reading the wrong claim.
#
# Why the refusal is the readiness one rather than the trusted-domain one. The
# contract does carry a fixed diagnostic naming 127.0.0.1, and the obvious
# expectation is that removing that entry produces it. It usually will not:
# every request the contract makes carries a 127.0.0.1 Host header, so once the
# entry is gone the server answers HTTP 400 to /status.php as well, and
# wait_for_server -- which returns only on 200 -- spends its budget and refuses
# first. Both messages are the same refusal seen from different depths, and
# which one appears depends on whether this image gates /status.php on
# trusted_domains. That was measured as gating, so the readiness diagnostic is
# the expected one; the alternation below accepts either rather than pinning a
# behaviour of upstream's that this lane does not own.
#
# What the alternation does NOT do is exclude a container that never started.
# Refusing a third message would not: message A is exactly what an unstarted
# container produces. The census is what excludes it -- the contract's run mode
# opens by inspecting all four containers and refusing any that is not both
# running and healthy, so neither of these two messages is even reachable unless
# the whole stack was up when this hook ran.
#
# And message A is generic even then. "never served its status endpoint within
# 10s" is the shape of any readiness failure at all: a host port that moved, a
# machine loaded enough that a healthy server misses a ten-second budget, an
# upstream regression in /status.php. It is accepted because it is the measured
# outcome of this drift, not because seeing it proves the drift was the cause.
# Message B is the specific one; A is the one this lane usually gets.
#
# The readiness budget is cut to ten seconds for that reason. This invocation
# must end in a refusal, so the real budget buys nothing but sleep -- the same
# reasoning CLAUDE.md records for the contract suites whose deadline rows were
# costing the static gate minutes apiece.
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
: "${PLATFORM_NEXTCLOUD_PORT:?PLATFORM_NEXTCLOUD_PORT is required}"
: "${PLATFORM_MAC_VAULT_FILE:?PLATFORM_MAC_VAULT_FILE is required}"
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?PLATFORM_MAC_VAULT_PASSWORD_FILE is required}"

expected_failure=$(mktemp "$PLATFORM_REPORT_ROOT/nextcloud-contract-drift.XXXXXX")
trap 'unlink "$expected_failure" >/dev/null 2>&1 || true' EXIT HUP INT TERM

# Resolved through the shared helper rather than by pasting the project prefix,
# which is what every other Mac caller of a container identity now does.
PLATFORM_NEXTCLOUD_CONTAINER=$(mac_container_name nextcloud)
export PLATFORM_NEXTCLOUD_CONTAINER

# The mutation is 90-nextcloud.rb beside this file, resolved from this hook's own
# directory rather than from any tree an argument supplies, with standard input
# held at end-of-file so a sibling program cannot inherit the hook's.
"$mac_hook_dir/90-nextcloud.rb" </dev/null

if PLATFORM_NEXTCLOUD_READY_TIMEOUT_SECONDS=10 \
  "$mac_script_dir/run-contract.sh" nextcloud run >"$expected_failure" 2>&1; then
  printf '%s\n' 'the Nextcloud contract accepted a hand-removed trusted domain' >&2
  exit 1
fi
"$mac_repo_dir/tests/assert-no-vault-secrets.rb" \
  "$PLATFORM_MAC_VAULT_FILE" "$PLATFORM_MAC_VAULT_PASSWORD_FILE" "$expected_failure"
if grep -qF 'Nextcloud never served its status endpoint' "$expected_failure"; then
  :
elif grep -qF 'Nextcloud does not trust 127.0.0.1' "$expected_failure"; then
  :
else
  printf '%s\n' 'the Nextcloud contract refused drift without either fixed diagnostic' >&2
  exit 1
fi

printf '%s\n' 'Nextcloud drift: a hand-removed trusted domain is rejected until the platform reconverges'
