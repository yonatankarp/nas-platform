#!/bin/sh
set -eu
set +x
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"
expected_failure=$(mktemp "$PLATFORM_REPORT_ROOT/immich-verify-drift.XXXXXX")
trap 'unlink "$expected_failure" >/dev/null 2>&1 || true' EXIT HUP INT TERM

"$mac_script_dir/run-immich-contract.sh" drift
"$mac_script_dir/run-immich-contract.sh" drift-verify
if mac_ansible_playbook -i "$mac_repo_dir/inventory/mac.yml" "$mac_repo_dir/verify.yml" \
    --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE" \
    -e @"$PLATFORM_MAC_VAULT_FILE" \
    -e @"$PLATFORM_MAC_FIXTURE_VARS_FILE" \
    -e "platform_vault_file=$PLATFORM_MAC_VAULT_FILE" \
    --tags platform_verify_immich >"$expected_failure" 2>&1; then
  printf '%s\n' 'verification-only run accepted Immich drift' >&2
  exit 1
fi
"$mac_repo_dir/tests/assert-no-vault-secrets.rb" \
  "$PLATFORM_MAC_VAULT_FILE" "$PLATFORM_MAC_VAULT_PASSWORD_FILE" "$expected_failure"
# The failing task's own fail_msg, never its task name: ansible prints
# "TASK [<name>]" whenever a task merely runs, so a task-name anchor is satisfied
# by this guard executing and *passing*. That was not hypothetical here (#428).
# The drift fixture installs a system-configuration drift alongside the
# preference drift, and "Require the managed Immich settings" runs after this
# guard, so a preferences guard that stopped refusing still failed the run one
# task later and the old anchor still matched.
#
# "Verify exact Immich managed user preferences" carries no_log: true, which is
# why this hook looked like it had no diagnostic to anchor on. Redaction censors
# the result dict -- the item line reads "censored" -- but ansible-core 2.21.3
# still prints the message on its own "[ERROR]: Task failed: Action failed:
# <fail_msg>" line, and that is what this reads. The prefix is the same anchor
# tests/http_fixture_support.rb uses, pinned to the ansible-core version in
# controller-requirements.txt; HttpFixtureSupport::TASK_REFUSAL_PREFIX is where a
# core release that rephrases it gets fixed, and it explains why the wording is
# read literally rather than loosened. tests/mac/immich-drift-hook-test.sh holds
# both captures.
grep -qF "Task failed: Action failed: An Immich managed user's declared preference leaves differ from its effective profile." \
  "$expected_failure" || {
  printf '%s\n' 'Immich verification refused drift without its fixed diagnostic' >&2
  exit 1
}
