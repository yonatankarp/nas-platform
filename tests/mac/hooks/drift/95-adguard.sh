#!/bin/sh
# AdGuard's drift is protection itself, turned off through the service's own
# control API and left there for the reconcile to take back.
#
# WHY THIS IS THE ORDINARY SHAPE AND NOT NEXTCLOUD'S. The hook beside this one
# proves an additive repair, because a trusted domain an operator added by hand
# is indistinguishable from drift and must not be removed. AdGuard has no such
# ambiguity: roles/adguard renders the whole of AdGuardHome.yaml, so the
# declared document is the only authority and every hand edit inside it is drift
# by construction. So this hook makes the plain claim the group is for -- a hand
# edit is reverted -- and the reconcile that follows is what proves it.
#
# The refusal is one fixed diagnostic rather than an alternation, and that is a
# property of where the drift sits rather than good luck. The contract reaches
# `protection_enabled` immediately after authenticating, before it polls filter
# lists or puts a question on the wire, so nothing slower can time out first and
# produce a different message. Every step ahead of it -- the login page, the
# anonymous 401, the wrong-password 401, the vault-authored 200 -- is unaffected
# by protection being off, which is exactly what makes this drift invisible to a
# status check and worth asserting behaviourally.
#
# The readiness budget is cut to ten seconds for the reason CLAUDE.md records
# for every invocation that must end in a refusal: the real budget buys nothing
# here but sleep. The two other AdGuard budgets are left alone because this
# invocation refuses before it reaches either.
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
: "${PLATFORM_ADGUARD_PORT:?PLATFORM_ADGUARD_PORT is required}"
: "${PLATFORM_ADGUARD_DNS_PORT:?PLATFORM_ADGUARD_DNS_PORT is required}"
: "${PLATFORM_MAC_VAULT_FILE:?PLATFORM_MAC_VAULT_FILE is required}"
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?PLATFORM_MAC_VAULT_PASSWORD_FILE is required}"

expected_failure=$(mktemp "$PLATFORM_REPORT_ROOT/adguard-contract-drift.XXXXXX")
trap 'unlink "$expected_failure" >/dev/null 2>&1 || true' EXIT HUP INT TERM

# The mutation is 95-adguard.rb beside this file, resolved from this hook's own
# directory rather than from any tree an argument supplies, with standard input
# held at end-of-file so a sibling program cannot inherit the hook's.
"$mac_hook_dir/95-adguard.rb" </dev/null

if PLATFORM_ADGUARD_READY_TIMEOUT_SECONDS=10 \
  "$mac_script_dir/run-contract.sh" adguard run >"$expected_failure" 2>&1; then
  printf '%s\n' 'the AdGuard contract accepted a hand-disabled protection setting' >&2
  exit 1
fi
"$mac_repo_dir/tests/assert-no-vault-secrets.rb" \
  "$PLATFORM_MAC_VAULT_FILE" "$PLATFORM_MAC_VAULT_PASSWORD_FILE" "$expected_failure"
grep -qF 'AdGuard reported protection disabled' "$expected_failure" || {
  printf '%s\n' 'the AdGuard contract refused drift without its fixed diagnostic' >&2
  exit 1
}

printf '%s\n' 'AdGuard drift: hand-disabled protection is rejected until the platform reconverges'
