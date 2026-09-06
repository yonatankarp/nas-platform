#!/bin/sh
set -eu

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
expected_failure=$(mktemp "$PLATFORM_REPORT_ROOT/beszel-verify-drift.XXXXXX")
trap 'unlink "$expected_failure" >/dev/null 2>&1 || true' EXIT HUP INT TERM

# Beszel 0.18.7 exposes system_stats and container_stats as authenticated,
# read-only collections (no supported create/update/delete rule). Editing the
# PocketBase database is explicitly unsupported, and stopping real metrics
# would destructively weaken the live proof. Exercise telemetry-fixtures through
# the same category evaluator instead of faking a live telemetry repair.
ruby "$mac_script_dir/../beszel_telemetry_probe_test.rb"

"$mac_script_dir/run-beszel-contract.sh" drift
if "$mac_script_dir/verify.sh" >"$expected_failure" 2>&1; then
  printf '%s\n' 'verification-only run accepted Beszel drift' >&2
  exit 1
fi
# The failing guard's own fail_msg, and only Beszel's. tests/mac/verify.sh runs
# every service's verification in one playbook, so until #440 -- when this hook
# asserted nothing beyond that command exiting non-zero -- an unrelated service
# failing satisfied it, and the hook reported a successful drift detection while
# the drift it planted went unnoticed and something else broke.
#
# One diagnostic, not five. tests/contracts/beszel-runtime.rb's drift mode
# installs five facets and ansible stops at the first task that refuses, so a
# conjunction over all five would be red on every real run. The role facet is the
# one that is always reached: under --tags platform_verify_beszel the reconciling
# PATCH in roles/beszel/tasks/application_user.yml is untagged and does not run,
# and "Verify the managed application user contract" is the role's first tagged
# refusal -- the token, settings, alert and decoy facets all belong to
# configure.yml, which runs after it.
#
# The fail_msg rather than the "TASK [...]" banner: ansible prints the banner
# whenever a task merely runs, so a task-name anchor is satisfied by this guard
# executing and *passing* while the run failed at a later Beszel guard (#428).
# The message is read off the "[ERROR]: Task failed: Action failed: <fail_msg>"
# line ansible-core 2.21.3 prints, pinned to the version in
# controller-requirements.txt; HttpFixtureSupport::TASK_REFUSAL_PREFIX is where a
# core release that rephrases that prefix gets fixed, and it is why the wording is
# read literally rather than loosened. The guard carries no no_log, so the message
# is not censored here. tests/mac/beszel-telemetry-hook-test.sh holds the captures
# and the two cases that discriminate this anchor from the one it replaced.
grep -qF \
  "Task failed: Action failed: Managed application user is absent or differs from the verified admin contract." \
  "$expected_failure" || {
  printf '%s\n' 'Beszel verification refused drift without its fixed diagnostic' >&2
  exit 1
}
