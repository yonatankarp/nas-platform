#!/bin/sh
# Drift the trusted domain list, the one setting reconcile_trusted_domains.yml exists for.
# Unlike siblings the repair is additive: the planted entry survives and 127.0.0.1 is
# re-added. Either diagnostic is accepted: a 127.0.0.1 Host then gets HTTP 400 from
# /status.php, so readiness usually refuses first. The run-mode census excludes a
# container that never started; the 10s budget only saves sleep on a certain refusal.
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

PLATFORM_NEXTCLOUD_CONTAINER=$(mac_container_name nextcloud)
export PLATFORM_NEXTCLOUD_CONTAINER

# stdin at EOF so the program does not inherit the hook's.
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
