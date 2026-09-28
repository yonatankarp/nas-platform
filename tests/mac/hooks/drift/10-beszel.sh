#!/bin/sh
set -eu
# The capture holds un-no_logged guard output: trace off, private mktemp.
set +x
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
expected_failure=$(mktemp "$PLATFORM_REPORT_ROOT/beszel-verify-drift.XXXXXX")
trap 'unlink "$expected_failure" >/dev/null 2>&1 || true' EXIT HUP INT TERM

# The hub's stats collections are read-only and editing PocketBase is unsupported,
# so exercise the telemetry evaluator against fixtures instead.
ruby "$mac_script_dir/../beszel_telemetry_probe_test.rb"

"$mac_script_dir/run-beszel-contract.sh" drift
# Read the fixture back first: one that silently failed to apply looks exactly
# like one correctly refused. After a converge the sentinels are gone by design.
"$mac_script_dir/run-beszel-contract.sh" drift-verify
if "$mac_script_dir/verify.sh" >"$expected_failure" 2>&1; then
  printf '%s\n' 'verification-only run accepted Beszel drift' >&2
  exit 1
fi
# verify.sh covers every service, so this capture is broad; a leak the scanner
# reports from any role is a true positive.
"$mac_repo_dir/tests/assert-no-vault-secrets.rb" \
  "$PLATFORM_MAC_VAULT_FILE" "$PLATFORM_MAC_VAULT_PASSWORD_FILE" "$expected_failure"
# Anchor on Beszel's own fail_msg, not the task banner or a bare non-zero exit:
# verify.sh runs every service, and the banner prints even when the task passes (#440, #428).
# Only the role facet is always reached; ansible stops at the first refusal.
grep -qF \
  "Task failed: Action failed: Managed application user is absent or differs from the verified admin contract." \
  "$expected_failure" || {
  printf '%s\n' 'Beszel verification refused drift without its fixed diagnostic' >&2
  exit 1
}
