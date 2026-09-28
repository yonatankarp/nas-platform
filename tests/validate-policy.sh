#!/bin/sh
# Policy validation entry point. Run from the repository root.
#
# Runs its own manifest concurrently. Keep one bare command per line: wrapping or
# prefixing lines silently disables the guards in tests/gate_manifest_coverage_test.rb,
# tests/policy_ci_test.rb and tests/policy_manifest_test.rb. Adding a check means
# one shard here and the matching shard in gate_manifest_coverage_test.rb.
# POLICY_JOBS sets concurrency (default: CPU count); POLICY_JOBS=1 runs serially.
# Every check runs and every failure is reported; the slowest checks are printed.
set -eu

if [ "$#" -gt 1 ]; then
  printf 'usage: %s [SHARD]\n' "$0" >&2
  exit 2
fi
policy_shard=${1:-}

# Three shards, one heredoc each; no argument runs all three, `2` runs shard 2.
# The partition balances cost, not counts (see gate_manifest_coverage_test.rb):
# - no two of the slowest checks share a shard;
# - spread the waits: a waiting check holds a worker slot, so two in one shard
#   halve its pool;
# - order within a shard is dispatch order, so list the heaviest checks first.
# A comment between heredoc markers would be dispatched as a check.

policy_shard_1() {
  cat <<'POLICY_CHECKS_1'
ruby tests/contract_structure_mutation_test.rb
ruby tests/deployment_summary_test.rb
ruby tests/database_managed_users_test.rb
tests/mac/media-acquisition-foundation-cleanup-test.sh
ruby tests/vaultwarden_serve_test.rb
python3 -m unittest -v tests/dozzle_alert_relay_test.py
ruby tests/managed_users_vault_test.rb
ruby tests/vaultwarden_serve_test.rb --self-test
ruby tests/komga_library_reconciliation_test.rb --self-test
tests/mac/beszel-telemetry-hook-test.sh
ruby tests/policy_test.rb
ruby tests/policy_beszel_test.rb
shellcheck --shell=sh -x tests/integration_controller.sh
ruby tests/policy_vault_test.rb
"$ansible_python" tests/generate_secrets_jinja_regex_test.py
ruby tests/host_prep_integration_writer_test.rb
ruby tests/media_acquisition_phase1_test.rb
ruby tests/media_acquisition_adoption_test.rb
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" -m unittest -v tests.image_prune_test
ruby tests/beszel_telemetry_timeout_test.rb
python3 -m unittest -v tests/downloaders_clamav_gate_test.py
ruby tests/immich_restore_lifecycle_test.rb
ruby tests/ci/workflow_test.rb
ruby tests/docs_links_test.rb --self-test
tests/mac/snapshot-paperless-context-test.sh
python3 tests/deployment_target_validator_test.py
python3 tests/deployment_release_compare_test.py
ruby tests/config_managed_users_test.rb --self-test
ruby tests/audiobookshelf_initial_scan_test.rb
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_filter_native_arguments_test.py
ruby tests/acquisition_configarr_field_coverage_test.rb --self-test
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_owned_field_coverage_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_configarr_filter_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/media_usenet_provider_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/managed_user_identity_filter_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/jellyfin_plugin_repositories_filter_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/safe_slurp_test.py
ruby tests/run_contracts.rb --validate-only
ruby tests/jellyfin_transcode_contract_test.rb
ruby tests/pinchflat_contract_test.rb
ruby tests/immich_contract_test.rb --self-test
ruby tests/nextcloud_contract_test.rb
ruby tests/arr_contract_test.rb
ruby tests/downloaders_contract_test.rb --self-test
ruby tests/trailarr_contract_test.rb
ruby tests/bindery_contract_test.rb --self-test
ruby tests/beszel_contract_test.rb --self-test
ruby tests/container_health_wiring_test.rb
ruby tests/container_health_wiring_test.rb --self-test
tests/integration_lock_test.sh
tests/mac/config-isolation.sh
tests/mac/dozzle-drift-hook-test.sh
tests/mac/hook-coverage-test.sh
tests/mac/cleanup.sh --self-test
ruby tests/mac/sanitize-logs.rb --self-test
ruby tests/mac/read-integration-ports-test.rb
ruby tests/role_forward_reference_test.rb
ruby tests/release_path_read_test.rb
tests/integration_cleanup_test.sh
POLICY_CHECKS_1
}

policy_shard_2() {
  cat <<'POLICY_CHECKS_2'
ruby tests/immich_release_helper_test.rb
ansible-playbook -i localhost, -c local tests/pre_upgrade_backup_test.yml
ruby tests/dozzle_quality_test.rb
ruby tests/immich_configured_password_test.rb
ruby tests/audiobookshelf_initial_scan_behavior_test.rb
ansible-playbook -i localhost, -c local tests/image_downgrade_guard_test.yml
ruby tests/database_managed_users_test.rb --self-test
ruby tests/seerr_contract_test.rb
ansible-playbook -i localhost, -c local tests/host_prep_mdraid_verify_test.yml
ruby tests/beszel_password_preservation_test.rb --self-test
tests/integration_suite_test.sh
ruby tests/policy_platform_test.rb
ruby tests/policy_integration_test.rb
ruby tests/policy_deployment_test.rb
ruby tests/verify_deployment_manifest.rb --self-test
ruby tests/gate_manifest_coverage_test.rb
ruby tests/deployment_gate_coverage_test.rb
tests/target_docker_dependency_preflight_test.sh
ruby tests/media_acquisition_foundation_test.rb
ruby tests/configarr_job_test.rb
tests/mac/media-acquisition-foundation-hook-test.sh
ruby tests/renovate_policy_test.rb
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" -m unittest -v tests.production_auto_deploy_test
ruby tests/image_prune_role_test.rb
ruby tests/beszel_telemetry_ansible_test.rb
python3 -m unittest -v tests/immich_restore_classifier_test.py
ruby tests/immich_selective_helper_integrity_test.rb
ruby tests/ci/classify_changes_test.rb
ruby tests/secrets_docs_test.rb
ruby tests/assert_no_vault_secrets_test.rb
tests/mac/snapshot-paperless-recovery-test.sh
python3 tests/deployment_lock_probe_test.py
python3 tests/deployment_controller_input_test.py
ruby tests/komga_contract_test.rb
ruby tests/rendered_file_ownership_test.rb
ruby tests/rendered_file_ownership_test.rb --self-test
ruby tests/audiobookshelf_contract_test.rb
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/managed_user_state_filter_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_filter_native_arguments_test.py --self-test
ruby tests/bazarr_provider_schema_test.rb
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_servarr_filter_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/vault_managed_user_schema_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/immich_preference_schema_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/container_cpu_filter_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/jellyfin_encoding_schema_test.py
ansible-playbook -i localhost, -c local tests/compose_metadata_filter_test.yml
ruby tests/jellyfin_contract_test.rb
ruby tests/pinchflat_contract_test.rb --self-test
ruby tests/paperless_contract_test.rb
ruby tests/arr_contract_test.rb --self-test
ruby tests/trailarr_contract_test.rb --self-test
ruby tests/kapowarr_contract_test.rb
tests/mac/run-phase-status-test.sh
tests/mac/reserved-environment-test.sh
tests/mac/reserved-environment-test.sh --self-test
tests/mac/audiobookshelf-drift-hook-test.sh
tests/contracts/audiobookshelf-audio-test.sh
tests/mac/snapshot-immich.sh --self-test
ruby tests/mac/pin-protected-input-test.rb
ruby tests/mac/read-integration-ports-test.rb --self-test
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/immich_probe_status_test.py
POLICY_CHECKS_2
}

policy_shard_3() {
  cat <<'POLICY_CHECKS_3'
tests/sandbox_cleanup_acquisition_ownership_test.sh
ruby tests/media_managed_users_test.rb
ruby tests/dozzle_contract_test.rb --self-test
ruby tests/komga_library_reconciliation_test.rb
ruby tests/paperless_mail_reconciliation_test.rb
ruby tests/docs_links_test.rb
ruby tests/beszel_pushover_validation_test.rb
ruby tests/dozzle_serve_test.rb
ruby tests/paperless_contract_test.rb --self-test
ruby tests/dozzle_contract_test.rb
ruby tests/production_auto_deploy_role_test.rb
tests/mac/manual-validation-runner-test.sh
tests/integration_controller_execution_test.sh
ruby tests/policy_ci_test.rb
ruby tests/idempotence_shard_partition_test.rb
ruby tests/idempotence_shard_partition_test.rb --self-test
shellcheck --shell=sh tests/integration_controller_lib.sh
ruby tests/policy_mac_test.rb
ruby tests/policy_audit_coverage_test.rb
tests/media_control_network_collision_test.sh static
ruby tests/media_acquisition_foundation_verifier_test.rb
ruby tests/reader_platform_identity_test.rb
ruby tests/capture_helper_identity_test.rb
ruby tests/dozzle_exit_code_exclusion_identity_test.rb
ruby tests/dozzle_exit_code_exclusion_identity_test.rb --self-test
ruby tests/mac/media-acquisition-foundation-report-test.rb
tests/policy_runner_test.sh
ruby tests/beszel_telemetry_probe_test.rb
python3 tests/beszel_telemetry_module_test.py
ruby tests/immich_restore_quality_test.rb
tests/dozzle_alert_state_symlink_test.sh
ruby tests/ci/validate_results_test.rb
tests/mac/integration-context-test.sh
tests/mac/snapshot-paperless-drill-throttle-test.sh
tests/deployment_lock_refusal_test.sh
ruby tests/managed_user_capabilities_test.rb --self-test
ruby tests/media_managed_users_test.rb --self-test
ruby tests/komga_contract_test.rb --self-test
ruby tests/audiobookshelf_contract_test.rb --self-test
ruby tests/immich_smart_search_retry_test.rb
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_identity_rules_test.py
ruby tests/acquisition_configarr_field_coverage_test.rb
ruby tests/bazarr_provider_schema_test.rb --self-test
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_bazarr_filter_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/vault_credential_schema_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/vault_artifact_identity_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/immich_response_schema_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/deployment_summary_filter_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/filter_input_argument_spec_test.py
ruby tests/run_contracts_test.rb
ruby tests/jellyfin_contract_test.rb --self-test
ruby tests/immich_contract_test.rb
ruby tests/nextcloud_contract_test.rb --self-test
ruby tests/downloaders_contract_test.rb
ruby tests/seerr_contract_test.rb --self-test
ruby tests/bindery_contract_test.rb
ruby tests/kapowarr_contract_test.rb --self-test
ruby tests/beszel_contract_test.rb
tests/integration_lifecycle_test.sh
ruby tests/contract_upgrade_seed_test.rb
tests/mac/immich-drift-hook-test.sh
ruby tests/mac/report.rb --self-test
tests/mac/snapshot-paperless.sh --self-test
ruby tests/mac/pin-protected-input-test.rb --self-test
ruby tests/case_pool_locals_test.rb --self-test
ruby tests/case_pool_behavior_test.rb --self-test
ruby tests/immich_user_onboarding_test.rb
ruby tests/immich_system_config_test.rb
ruby tests/immich_placement_wait_test.rb
tests/generate-secrets-redaction-test.sh
POLICY_CHECKS_3
}

POLICY_SHARD_IDS='1 2 3'

# An unknown shard is refused rather than run as nothing.
policy_checks() {
  wanted=${1:-}
  emitted=0
  for shard in $POLICY_SHARD_IDS; do
    if [ -z "$wanted" ] || [ "$wanted" = "$shard" ]; then
      "policy_shard_$shard"
      emitted=$((emitted + 1))
    fi
  done
  if [ "$emitted" -eq 0 ]; then
    printf 'unknown policy shard: %s\n' "$wanted" >&2
    printf 'the manifest declares shards: %s\n' "$POLICY_SHARD_IDS" >&2
    exit 2
  fi
}

# Resolved once and exported: two checks invoke this interpreter directly.
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

# One file per check, so any command round-trips intact.
policy_checks "$policy_shard" >"$work/manifest"
total=$(awk 'END { print NR }' "$work/manifest")
# An empty shard must not report "all 0 checks passed".
if [ "$total" -eq 0 ]; then
  printf 'policy validation found no checks to run\n' >&2
  exit 1
fi
if [ -n "$policy_shard" ]; then
  printf 'policy gate shard %s (of %s): %s checks\n' \
    "$policy_shard" "$POLICY_SHARD_IDS" "$total"
fi
index=0
while [ "$index" -lt "$total" ]; do
  index=$((index + 1))
  awk -v n="$index" 'NR == n { print; exit }' "$work/manifest" >"$work/cmd.$index"
  printf '%s\n' "$work/cmd.$index" >>"$work/queue"
done

# Always exits 0: the parent decides pass/fail from the recorded status.
cat >"$work/run-check" <<'RUNNER'
spec=$1
dir=$(dirname "$spec")
index=${spec##*/cmd.}
started=$(date +%s)
command=$(cat "$spec")
# The checks read this repository's own files, and CLAUDE.md and most documents
# under docs/ are not pure ASCII. Ruby takes its default external encoding from the locale,
# so on a machine whose locale is not UTF-8 -- an unset LANG, or one naming a
# locale the image never generated -- File.read hands back US-ASCII and the
# first regex over it raises `invalid byte sequence in US-ASCII`. Measured
# before this line: 24 of the 79 ruby checks in this manifest died that way,
# policy_test.rb and policy_ci_test.rb among them, naming a regex instead of a
# violation. CI is UTF-8 and never saw it, which is exactly why it needed
# stating here rather than being left to the environment.
#
# RUBYOPT rather than LC_ALL=C.UTF-8, which was the first fix and was wrong on
# the one platform that would have needed it most: C.UTF-8 is not a locale
# macOS has, so setting it there leaves default_external at US-ASCII and the
# checks keep dying, silently and in the same way. RUBYOPT sets the encoding
# Ruby actually reads, on every platform.
#
# It is set per check rather than exported once at the top of this script, and
# that is the whole of why this is here and not there. tests/mac/run.sh refuses
# to start when RUBYOPT -- or RUBYLIB, GEM_HOME, BUNDLE_GEMFILE and the rest --
# is set in its environment at all, because it decrypts a vault and those
# variables are arbitrary-code-loading vectors. Exported once at the top, this
# variable reached that guard and was refused with `reserved language startup
# environment must be unset`. Measured rather than assumed: of this manifest's
# seventeen tests/mac/*.sh lines, four mention run.sh and exactly one --
# manual-validation-runner-test.sh -- executes it far enough to meet the guard,
# so one check went red and shards 1 and 2 stayed green. One is enough. Setting
# the variable per check is what keeps that guard whole; loosening the guard to
# admit one value was the alternative, and trading a vault-decrypting script's
# refusal of code-loading environment for an encoding default is not a trade
# worth making.
case $command in
  ruby\ *) RUBYOPT="${RUBYOPT:+$RUBYOPT }-EUTF-8"; export RUBYOPT ;;
esac
sh -c "$command" >"$dir/out.$index" 2>&1
status=$?
printf '%s\n' "$(($(date +%s) - started))" >"$dir/seconds.$index"
printf '%s\n' "$status" >"$dir/status.$index"
exit 0
RUNNER

# A signal-killed child makes xargs abandon the pool, so record its status
# instead of aborting; the accounting below names checks that never reported.
dispatch=0
gate_started=$(date +%s)
tr '\n' '\0' <"$work/queue" |
  xargs -0 -n 1 -P "$jobs" sh "$work/run-check" || dispatch=$?
gate_seconds=$(($(date +%s) - gate_started))

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
  printf '%s\t%s\n' "$(cat "$work/seconds.$index")" "$check" >>"$work/durations"
done

# Report wall time and the ten slowest checks, on success too: the longest
# single item is the gate's floor.
if [ -f "$work/durations" ]; then
  busiest=$(sort -rn "$work/durations" | head -10)
  work_seconds=$(awk -F'\t' '{ total += $1 } END { print total + 0 }' "$work/durations")
  printf '\npolicy gate: %ss wall, %ss of check time across %s checks on %s workers\n' \
    "$gate_seconds" "$work_seconds" "$ran" "$jobs"
  printf 'slowest checks:\n'
  printf '%s\n' "$busiest" | awk -F'\t' '{ printf "  %5ds  %s\n", $1, $2 }'
fi

if [ "$ran" -ne "$total" ] || [ "$failed" -ne 0 ] || [ "$dispatch" -ne 0 ]; then
  printf '\npolicy validation failed: %s of %s checks ran, %s failed' \
    "$ran" "$total" "$failed" >&2
  [ "$dispatch" -eq 0 ] || printf ', dispatcher exited %s' "$dispatch" >&2
  printf '\n' >&2
  exit 1
fi

printf 'policy validation: all %s checks passed\n' "$total"
