#!/usr/bin/env ruby
# The policy gate's check list, declared, and its partition into CI shards (#469).
# The three lists below must equal the three heredocs in tests/validate-policy.sh,
# union to the whole manifest, never repeat a line, and never collapse a shard.
# Removing a check therefore costs a visible two-place edit; it does not prove a
# line runs. Kept outside the eight POLICY_SCRIPTS so policy_manifest_test.rb's
# declared detector sets stay right. DO NOT TIDY THIS COPY AWAY: it is the mechanism.

require "open3"
require_relative "policy_support"

include TestScaffold

failures = []

# The manifest, restated one shard at a time (same shape as validate-policy.sh,
# so an edit is a paste). Counts are printed by this check, never written here (#652).
# Balance cost, not count; re-measure from the gate's slowest-checks report
# (evidence: docs/ci-performance-history.md, #517). Three constraints:
# - No two of the gate's three slowest checks share a shard (a shard's floor is its slowest check).
# - Spread the waits: a waiting check holds a worker slot without using CPU.
# - Heaviest checks first in each block: the gate dispatches top to bottom (#843).

SHARD_1 = <<~'CHECKS'.lines(chomp: true).freeze
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
CHECKS

SHARD_2 = <<~'CHECKS'.lines(chomp: true).freeze
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
CHECKS

SHARD_3 = <<~'CHECKS'.lines(chomp: true).freeze
  tests/sandbox_cleanup_acquisition_ownership_test.sh
  ruby tests/media_managed_users_test.rb
  ruby tests/dozzle_contract_test.rb --self-test
  ruby tests/komga_library_reconciliation_test.rb
  ruby tests/paperless_mail_reconciliation_test.rb
  ruby tests/docs_links_test.rb
  ruby tests/beszel_pushover_validation_test.rb
  ruby tests/dozzle_serve_test.rb
  ruby tests/dozzle_dispatcher_rename_test.rb
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
CHECKS

SHARDS = { "1" => SHARD_1, "2" => SHARD_2, "3" => SHARD_3 }.freeze
GATE_CHECKS = SHARDS.values.flatten.freeze

MANIFEST_PATH = File.join(ROOT, "tests", "validate-policy.sh")
# A parse that matches nothing passes every emptiness test, so the floors are numbers.
MANIFEST_FLOOR = 120
# Per shard: one shard holding one check instead of fifty passes `!empty?`.
SHARD_FLOOR = 30

manifest_shards = PolicySupport.gate_shards(MANIFEST_PATH)
check(failures, !manifest_shards.empty?,
      "tests/validate-policy.sh no longer opens its check lists with " \
      "\"  cat <<'POLICY_CHECKS_<id>'\" and closes each on a bare terminator of the same " \
      "name: the manifest cannot be read, so nothing below has been checked")
manifest = manifest_shards.values.flatten

# Dispatched, not merely declared: a heredoc nothing cats never runs.
dispatched = PolicySupport.gate_shard_ids(MANIFEST_PATH)
check(failures, dispatched == manifest_shards.keys,
      "tests/validate-policy.sh dispatches shards #{dispatched.inspect} but declares heredocs " \
      "for #{manifest_shards.keys.inspect}: a shard whose list exists and which nothing runs " \
      "is a third of the gate gone with every check still green")
check(failures, manifest_shards.keys == SHARDS.keys,
      "tests/validate-policy.sh partitions its manifest into shards " \
      "#{manifest_shards.keys.inspect}, and this file declares #{SHARDS.keys.inspect}. " \
      "Adding or removing a shard means editing both, and the CI matrix in " \
      ".github/workflows/ci.yml with them")

# The same list read by a different program (awk), so a misread boundary does
# not move both readings in the same direction.
AWK_PROGRAM = [
  '/^  cat <</ && /POLICY_CHECKS_/ { inside = 1; next }',
  '/^POLICY_CHECKS_[0-9]+$/ { inside = 0 }',
  'inside { print }'
].join("\n")
awk_lines = []
if File.file?(MANIFEST_PATH)
  awk_output, awk_error, awk_status = Open3.capture3("awk", AWK_PROGRAM, MANIFEST_PATH)
  check(failures, awk_status.success?,
        "the second manifest reading failed: #{failure_tail(awk_error)}")
  awk_lines = awk_output.lines(chomp: true)
end
check(failures, awk_lines == manifest,
      "the two readings of tests/validate-policy.sh disagree: the shard reading found " \
      "#{manifest.length} checks and the streamed reading found #{awk_lines.length}, " \
      "differing at #{(awk_lines - manifest).first(3).inspect} / " \
      "#{(manifest - awk_lines).first(3).inspect}")

check(failures, manifest.length >= MANIFEST_FLOOR,
      "read only #{manifest.length} checks out of tests/validate-policy.sh, under the floor " \
      "of #{MANIFEST_FLOOR}: the reading has broken rather than the gate shrunk, and a set " \
      "comparison against a list that short would be an accident")

repeated_in_manifest = manifest.tally.select { |_, count| count > 1 }.keys
check(failures, repeated_in_manifest.empty?,
      "tests/validate-policy.sh runs #{repeated_in_manifest.inspect} more than once; " \
      "each check belongs to exactly one line of exactly one shard")
repeated_in_declaration = GATE_CHECKS.tally.select { |_, count| count > 1 }.keys
check(failures, repeated_in_declaration.empty?,
      "this file declares #{repeated_in_declaration.inspect} in more than one shard; the " \
      "partition must claim each check exactly once")

# Names are capped: a hundred-line divergence means the manifest was unreadable,
# which the floor already reports.
NAMED_LIMIT = 12
def named(commands)
  shown = commands.first(NAMED_LIMIT).inspect
  return shown if commands.length <= NAMED_LIMIT

  "#{shown} and #{commands.length - NAMED_LIMIT} more"
end

undeclared = manifest - GATE_CHECKS
check(failures, undeclared.empty?,
      "tests/validate-policy.sh runs checks no shard of this file declares: " \
      "#{named(undeclared)}. Add them to the matching SHARD_n -- a check the gate runs and " \
      "nothing requires is a check the next prune of the manifest deletes with every gate " \
      "still green")
unrun = GATE_CHECKS - manifest
check(failures, unrun.empty?,
      "this file declares checks tests/validate-policy.sh does not run: #{named(unrun)}. " \
      "Either the gate stopped running them, which is the failure this check exists for, or " \
      "they were deliberately removed and the shard lists have not been told")

# Per shard as well: a line moved on one side only unbalances the runners.
SHARDS.each do |id, declared|
  found = manifest_shards.fetch(id, nil)
  next if found.nil?

  check(failures, found == declared,
        "shard #{id} of tests/validate-policy.sh runs #{found.length} checks and this file " \
        "declares #{declared.length}, differing at #{(found - declared).first(3).inspect} / " \
        "#{(declared - found).first(3).inspect}. The two lists are edited together or the " \
        "partition is a guess")
end

SHARDS.each do |id, declared|
  check_floor(failures, declared.length, SHARD_FLOOR, "shard #{id} as this file declares it")
end
manifest_shards.each do |id, found|
  check_floor(failures, found.length, SHARD_FLOOR,
              "shard #{id} as tests/validate-policy.sh runs it")
end

# The CI matrix against the partition. Here as well as in policy_ci_test.rb and
# tests/ci/workflow_test.rb so that dropping any one shard leaves two guards running.
WORKFLOW_PATH = File.join(ROOT, ".github", "workflows", "ci.yml")
workflow_shards = if File.file?(WORKFLOW_PATH)
                    YAML.safe_load_file(WORKFLOW_PATH, aliases: false)
                        .dig("jobs", "static", "strategy", "matrix", "shard")
                  end
check(failures, workflow_shards == manifest_shards.keys,
      ".github/workflows/ci.yml dispatches static shards #{workflow_shards.inspect} and " \
      "tests/validate-policy.sh partitions its manifest into #{manifest_shards.keys.inspect}: " \
      "a shard missing from the matrix runs on no runner, and every check it holds is still " \
      "declared, still inside a heredoc and still claimed by exactly one shard")

# ...and those three guards must sit in three different shards.
MATRIX_GUARDS = [
  "tests/ci/workflow_test.rb",
  "tests/gate_manifest_coverage_test.rb",
  "tests/policy_ci_test.rb"
].freeze
guard_shards = MATRIX_GUARDS.to_h do |guard|
  [guard, manifest_shards.select { |_, cmds| cmds.any? { |cmd| cmd.include?(guard) } }.keys]
end
check(failures, guard_shards.values.all? { |claiming| claiming.length == 1 },
      "each guard on the CI matrix must be one check in one shard, found " \
      "#{guard_shards.inspect}")
check(failures, guard_shards.values.flatten.uniq.length == MATRIX_GUARDS.length,
      "the guards on the CI matrix must sit in #{MATRIX_GUARDS.length} different shards, " \
      "found #{guard_shards.inspect}. Two in one shard means dropping that shard from the " \
      "matrix leaves one guard, and all three in one means dropping it leaves none -- which " \
      "is the hole these three copies exist to close")

report(failures,
       "gate manifest: #{manifest.length} declared checks across #{manifest_shards.length} " \
       "shards (#{manifest_shards.map { |id, lines| "#{id}: #{lines.length}" }.join(', ')}), " \
       "all of them run exactly once",
       "gate manifest violation(s)")
