#!/bin/sh
# Policy validation entry point. Run from the repository root.
#
# The check list is data, not straight-line shell: this script reads its own
# manifest and runs the checks concurrently. Run one after another they took
# 15m28s, which made `static` the second-longest job in CI and made a full local
# run impractical enough to skip.
#
# Each check stays one bare command per line. tests/policy_ci_test.rb asserts that
# every check appears exactly once as a stripped line of this file, and
# tests/policy_manifest_test.rb proves that deleting a line is caught. Wrapping
# these lines in a helper, or prefixing them, silently disables those guards
# while leaving this script working, so keep the shape.
#
# POLICY_JOBS sets concurrency and defaults to the CPU count. POLICY_JOBS=1
# restores the original one-at-a-time order, which is what to use when bisecting
# a failure that only shows up under load.
#
# Unlike the sequential version this does not stop at the first failure: every
# check runs and every failure is reported, so one broken check no longer hides
# the state of the other fifty-six.
set -eu

policy_checks() {
  cat <<'POLICY_CHECKS'
ruby tests/policy_test.rb
ruby tests/policy_platform_test.rb
ruby tests/policy_ci_test.rb
ruby tests/policy_beszel_test.rb
ruby tests/policy_integration_test.rb
ruby tests/policy_deployment_test.rb
ruby tests/policy_mac_test.rb
ruby tests/policy_vault_test.rb
"$ansible_python" tests/generate_secrets_jinja_regex_test.py
tests/target_docker_dependency_preflight_test.sh
tests/media_control_network_collision_test.sh static
ruby tests/media_acquisition_foundation_test.rb
ruby tests/media_acquisition_foundation_verifier_test.rb
tests/mac/media-acquisition-foundation-hook-test.sh
ruby tests/mac/media-acquisition-foundation-report-test.rb
tests/mac/media-acquisition-foundation-cleanup-test.sh
ruby tests/renovate_policy_test.rb
tests/policy_runner_test.sh
ruby tests/paperless_mail_reconciliation_test.rb
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" -m unittest -v tests.production_auto_deploy_test
ruby tests/production_auto_deploy_role_test.rb
ruby tests/beszel_telemetry_probe_test.rb
ruby tests/beszel_telemetry_timeout_test.rb
ruby tests/beszel_telemetry_ansible_test.rb
python3 tests/beszel_telemetry_module_test.py
python3 -m unittest -v tests/dozzle_alert_relay_test.py
python3 -m unittest -v tests/immich_restore_classifier_test.py
ruby tests/immich_restore_quality_test.rb
ruby tests/immich_restore_lifecycle_test.rb
ruby tests/immich_release_helper_test.rb
ruby tests/immich_selective_helper_integrity_test.rb
tests/dozzle_alert_state_symlink_test.sh
tests/mac/beszel-telemetry-hook-test.sh
ruby tests/ci/classify_changes_test.rb
ruby tests/ci/validate_results_test.rb
ruby tests/ci/workflow_test.rb
ruby tests/secrets_docs_test.rb
ruby tests/assert_no_vault_secrets_test.rb
tests/mac/integration-context-test.sh
tests/mac/snapshot-paperless-context-test.sh
tests/mac/snapshot-paperless-recovery-test.sh
tests/mac/snapshot-paperless-drill-throttle-test.sh
ruby tests/policy_manifest_test.rb
python3 tests/deployment_target_validator_test.py
python3 tests/deployment_release_compare_test.py
python3 tests/deployment_controller_input_test.py
ruby tests/managed_user_capabilities_test.rb --self-test
ruby tests/managed_users_vault_test.rb
ruby tests/beszel_password_preservation_test.rb --self-test
ruby tests/config_managed_users_test.rb --self-test
ruby tests/media_managed_users_test.rb
ruby tests/media_managed_users_test.rb --self-test
ruby tests/komga_library_reconciliation_test.rb
ruby tests/audiobookshelf_initial_scan_test.rb
ruby tests/audiobookshelf_initial_scan_behavior_test.rb
ruby tests/immich_user_onboarding_test.rb
ruby tests/immich_configured_password_test.rb
ruby tests/immich_smart_search_retry_test.rb
ruby tests/database_managed_users_test.rb
ruby tests/database_managed_users_test.rb --self-test
ruby tests/ntfy_verify_execution_test.rb
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/managed_user_state_filter_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/vault_managed_user_schema_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/vault_credential_schema_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/immich_preference_schema_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/container_cpu_filter_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/jellyfin_plugin_repositories_filter_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/safe_slurp_test.py
ansible-playbook -i localhost, -c local tests/compose_metadata_filter_test.yml
ruby tests/run_contracts_test.rb
ruby tests/run_contracts.rb --validate-only
ruby tests/dozzle_quality_test.rb
ruby tests/jellyfin_transcode_contract_test.rb
ruby tests/contract_structure_mutation_test.rb
tests/integration_lock_test.sh
tests/integration_suite_test.sh
tests/mac/config-isolation.sh
tests/mac/run-phase-status-test.sh
tests/mac/manual-validation-runner-test.sh
tests/mac/dozzle-drift-hook-test.sh
tests/mac/audiobookshelf-drift-hook-test.sh
tests/mac/hook-coverage-test.sh
tests/contracts/audiobookshelf-audio-test.sh
ruby tests/mac/report.rb --self-test
tests/mac/cleanup.sh --self-test
tests/mac/snapshot-immich.sh --self-test
ruby tests/mac/sanitize-logs.rb --self-test
POLICY_CHECKS
}

# Resolved before the checks run because two of them invoke this interpreter
# directly, and exported because each check is executed in its own shell.
ansible_playbook=$(command -v ansible-playbook) || {
  printf '%s\n' 'ansible-playbook is required for managed-user behavior tests' >&2
  exit 1
}
ansible_python=$(
  "$ansible_playbook" --version |
    sed -n 's/^  python version = .* (\(\/[^()]*\))$/\1/p'
)
[ -x "$ansible_python" ] || {
  printf '%s\n' 'the ansible-playbook Python interpreter is unavailable' >&2
  exit 1
}
export ansible_python

jobs=${POLICY_JOBS:-}
if [ -z "$jobs" ]; then
  jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
fi
case $jobs in
  '' | *[!0-9]*) jobs=4 ;;
esac
[ "$jobs" -ge 1 ] || jobs=1

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

# One file per check rather than a delimited record, so a command containing any
# character at all still round-trips to its runner intact.
policy_checks >"$work/manifest"
total=$(awk 'END { print NR }' "$work/manifest")
index=0
while [ "$index" -lt "$total" ]; do
  index=$((index + 1))
  awk -v n="$index" 'NR == n { print; exit }' "$work/manifest" >"$work/cmd.$index"
  printf '%s\n' "$work/cmd.$index" >>"$work/queue"
done

# Always exits 0: the parent decides pass or fail from the recorded status, so a
# failing check neither aborts the pool nor leaves the remaining checks unrun.
cat >"$work/run-check" <<'RUNNER'
spec=$1
dir=$(dirname "$spec")
index=${spec##*/cmd.}
sh -c "$(cat "$spec")" >"$dir/out.$index" 2>&1
printf '%s\n' "$?" >"$dir/status.$index"
exit 0
RUNNER

# A child killed by a signal makes xargs abandon the pool, so its status is
# recorded rather than allowed to abort the script: the accounting below is what
# names the checks that never reported, and it has to run for that to be said.
dispatch=0
tr '\n' '\0' <"$work/queue" |
  xargs -0 -n 1 -P "$jobs" sh "$work/run-check" || dispatch=$?

ran=0
failed=0
index=0
while [ "$index" -lt "$total" ]; do
  index=$((index + 1))
  check=$(cat "$work/cmd.$index")
  if [ ! -f "$work/status.$index" ]; then
    printf 'POLICY CHECK NEVER RAN: %s\n' "$check" >&2
    failed=$((failed + 1))
    continue
  fi
  ran=$((ran + 1))
  status=$(cat "$work/status.$index")
  if [ "$status" -eq 0 ]; then
    cat "$work/out.$index"
  else
    printf '\n=== FAILED (exit %s): %s ===\n' "$status" "$check" >&2
    cat "$work/out.$index" >&2
  fi
  [ "$status" -eq 0 ] || failed=$((failed + 1))
done

if [ "$ran" -ne "$total" ] || [ "$failed" -ne 0 ] || [ "$dispatch" -ne 0 ]; then
  printf '\npolicy validation failed: %s of %s checks ran, %s failed' \
    "$ran" "$total" "$failed" >&2
  [ "$dispatch" -eq 0 ] || printf ', dispatcher exited %s' "$dispatch" >&2
  printf '\n' >&2
  exit 1
fi

printf 'policy validation: all %s checks passed\n' "$total"
