#!/usr/bin/env ruby
# The policy gate's own check list, declared.
#
# tests/validate-policy.sh dispatches one bare command per line of its own
# heredoc, and until now nothing said what that list should contain. Individual
# lines were required one at a time -- tests/policy_ci_test.rb names about
# ninety, tests/policy_mac_test.rb eleven, tests/policy_test.rb and
# tests/policy_deployment_test.rb a handful each -- which pins the lines somebody
# thought to pin and says nothing at all about the rest. On the order of forty
# lines were required by nothing, so deleting any of them left every check
# green and the gate faster than before. #315 found six of those by auditing the
# manifest against the policy scripts by hand, #334 found a seventh that was in
# no manifest at all, and a hand audit is not a guard.
#
# This is the guard: the manifest and the list below must be the same set, and
# the diagnostic names the lines that differ.
#
# State what that buys precisely, because it is easy to claim more. Removing a
# check from the gate now takes an edit in two places instead of one, so an
# omission that used to be invisible is a two-place diff a reviewer can see. It
# does NOT make each line exercised: delete a command from the manifest and from
# the list below and this check still passes, by construction. The improvement
# is over ~40 lines having been freely prunable with every gate green, and that
# is the whole of it.
#
# WHY A SEPARATE FILE, rather than completing the `%w[]` list in
# tests/policy_ci_test.rb and adding the reverse assertion there. That was the
# obvious alternative and it is the wrong one for a measured reason, not an
# aesthetic one. tests/policy_manifest_test.rb mutates this manifest at eight
# call sites, and it declares per site which policy scripts detect the planted
# defect: one declares `%i[deployment]`, one declares `%i[mac]` and covers the
# six #315 Mac checks, and the rest already name `ci`. An equality assertion
# living inside tests/policy_ci_test.rb would fire on every one of those
# mutations, so those two sites -- seven mutations -- would gain `ci`, their
# declared sets would be wrong, and `ruby tests/policy_manifest_test.rb --audit`
# would fail on the drift. The declaration therefore has to sit outside the
# eight scripts in POLICY_SCRIPTS, which is what this file is, and it must not
# be moved into one of them later.
#
# DO NOT TIDY THIS AWAY. A second copy of a list looks like duplication, and
# deleting it is exactly the silent prune it exists to prevent -- the gate would
# still pass, faster, with nothing to say a check had gone. The copy is the
# mechanism, not an accident of it.
#
# It is also the precondition for sharding the gate (#469), and the reason this
# file is worth keeping rather than replacing. A partition is a set of literal
# lists whose union must equal the manifest -- itself a second copy, for the same
# reason -- and a line dropped from a partition disappears exactly the way a line
# dropped from the manifest does today. There is no honest union guard until the
# manifest is declared somewhere. When the gate is sharded this list becomes the
# union of the shard lists and this check becomes the union guard; it evolves
# into that rather than being thrown away.
#
# Deliberately not here: whether each command's target file exists. The gate
# runs these commands, so a path that does not exist fails there, loudly, with
# the command named -- and asserting it twice would only add a way for this
# check to be wrong.

require "open3"
require_relative "policy_support"

include TestScaffold

failures = []

# The manifest, restated. Copy the heredoc across when a check is added or
# removed: the two blocks are deliberately the same shape so the edit is a
# paste and the diff is readable.
GATE_CHECKS = <<~'CHECKS'.lines(chomp: true).freeze
  ruby tests/policy_test.rb
  ruby tests/policy_platform_test.rb
  ruby tests/policy_ci_test.rb
  ruby tests/policy_beszel_test.rb
  ruby tests/policy_integration_test.rb
  shellcheck --shell=sh tests/integration_controller_lib.sh
  shellcheck --shell=sh -x --exclude=SC2068,SC2070,SC2086 tests/integration_controller.sh
  ruby tests/policy_deployment_test.rb
  ruby tests/policy_mac_test.rb
  ruby tests/policy_vault_test.rb
  ruby tests/gate_manifest_coverage_test.rb
  ruby tests/policy_audit_coverage_test.rb
  "$ansible_python" tests/generate_secrets_jinja_regex_test.py
  tests/target_docker_dependency_preflight_test.sh
  tests/media_control_network_collision_test.sh static
  ruby tests/host_prep_integration_writer_test.rb
  ruby tests/media_acquisition_foundation_test.rb
  ruby tests/media_acquisition_foundation_verifier_test.rb
  ruby tests/media_acquisition_phase1_test.rb
  ruby tests/configarr_job_test.rb
  ruby tests/reader_platform_identity_test.rb
  ruby tests/media_acquisition_adoption_test.rb
  tests/mac/media-acquisition-foundation-hook-test.sh
  ruby tests/mac/media-acquisition-foundation-report-test.rb
  tests/mac/media-acquisition-foundation-cleanup-test.sh
  ruby tests/renovate_policy_test.rb
  tests/policy_runner_test.sh
  ruby tests/paperless_mail_reconciliation_test.rb
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" -m unittest -v tests.production_auto_deploy_test
  ruby tests/production_auto_deploy_role_test.rb
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" -m unittest -v tests.image_prune_test
  ruby tests/image_prune_role_test.rb
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
  ruby tests/docs_links_test.rb
  ruby tests/docs_links_test.rb --self-test
  ruby tests/assert_no_vault_secrets_test.rb
  tests/mac/integration-context-test.sh
  tests/mac/snapshot-paperless-context-test.sh
  tests/mac/snapshot-paperless-recovery-test.sh
  tests/mac/snapshot-paperless-drill-throttle-test.sh
  python3 tests/deployment_target_validator_test.py
  python3 tests/deployment_lock_probe_test.py
  tests/deployment_lock_refusal_test.sh
  python3 tests/deployment_release_compare_test.py
  python3 tests/deployment_controller_input_test.py
  ruby tests/managed_user_capabilities_test.rb --self-test
  ruby tests/managed_users_vault_test.rb
  ruby tests/beszel_password_preservation_test.rb --self-test
  ruby tests/config_managed_users_test.rb --self-test
  ruby tests/media_managed_users_test.rb
  ruby tests/media_managed_users_test.rb --self-test
  ruby tests/komga_library_reconciliation_test.rb
  ruby tests/komga_library_reconciliation_test.rb --self-test
  ruby tests/komga_contract_test.rb
  ruby tests/komga_contract_test.rb --self-test
  ruby tests/audiobookshelf_initial_scan_test.rb
  ruby tests/audiobookshelf_initial_scan_behavior_test.rb
  ruby tests/audiobookshelf_contract_test.rb
  ruby tests/audiobookshelf_contract_test.rb --self-test
  ruby tests/immich_user_onboarding_test.rb
  ruby tests/immich_configured_password_test.rb
  ruby tests/immich_smart_search_retry_test.rb
  ruby tests/database_managed_users_test.rb
  ruby tests/database_managed_users_test.rb --self-test
  ruby tests/ntfy_verify_execution_test.rb
  ruby tests/deployment_summary_test.rb
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/managed_user_state_filter_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_identity_rules_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_filter_native_arguments_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_filter_native_arguments_test.py --self-test
  ruby tests/acquisition_configarr_field_coverage_test.rb
  ruby tests/acquisition_configarr_field_coverage_test.rb --self-test
  ruby tests/bazarr_provider_schema_test.rb
  ruby tests/bazarr_provider_schema_test.rb --self-test
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_owned_field_coverage_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_servarr_filter_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_bazarr_filter_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_configarr_filter_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/vault_managed_user_schema_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/vault_credential_schema_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/media_usenet_provider_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/immich_preference_schema_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/immich_response_schema_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/managed_user_identity_filter_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/container_cpu_filter_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/deployment_summary_filter_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/jellyfin_plugin_repositories_filter_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/jellyfin_encoding_schema_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/filter_input_argument_spec_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/safe_slurp_test.py
  ansible-playbook -i localhost, -c local tests/compose_metadata_filter_test.yml
  ruby tests/run_contracts_test.rb
  ruby tests/run_contracts.rb --validate-only
  ruby tests/dozzle_quality_test.rb
  ruby tests/dozzle_contract_test.rb
  ruby tests/dozzle_contract_test.rb --self-test
  ruby tests/jellyfin_transcode_contract_test.rb
  ruby tests/jellyfin_contract_test.rb
  ruby tests/jellyfin_contract_test.rb --self-test
  ruby tests/pinchflat_contract_test.rb
  ruby tests/pinchflat_contract_test.rb --self-test
  ruby tests/immich_contract_test.rb
  ruby tests/immich_contract_test.rb --self-test
  ruby tests/paperless_contract_test.rb
  ruby tests/paperless_contract_test.rb --self-test
  ruby tests/seafile_contract_test.rb
  ruby tests/seafile_contract_test.rb --self-test
  ruby tests/arr_contract_test.rb
  ruby tests/arr_contract_test.rb --self-test
  ruby tests/downloaders_contract_test.rb
  ruby tests/downloaders_contract_test.rb --self-test
  ruby tests/seerr_contract_test.rb
  ruby tests/seerr_contract_test.rb --self-test
  ruby tests/trailarr_contract_test.rb
  ruby tests/trailarr_contract_test.rb --self-test
  ruby tests/bindery_contract_test.rb
  ruby tests/bindery_contract_test.rb --self-test
  ruby tests/kapowarr_contract_test.rb
  ruby tests/kapowarr_contract_test.rb --self-test
  ruby tests/beszel_contract_test.rb
  ruby tests/beszel_contract_test.rb --self-test
  ruby tests/contract_structure_mutation_test.rb
  tests/integration_lock_test.sh
  tests/integration_suite_test.sh
  tests/integration_controller_execution_test.sh
  tests/sandbox_cleanup_acquisition_ownership_test.sh
  tests/mac/config-isolation.sh
  tests/mac/run-phase-status-test.sh
  tests/mac/manual-validation-runner-test.sh
  tests/mac/dozzle-drift-hook-test.sh
  tests/mac/audiobookshelf-drift-hook-test.sh
  tests/mac/immich-drift-hook-test.sh
  tests/mac/hook-coverage-test.sh
  tests/contracts/audiobookshelf-audio-test.sh
  ruby tests/mac/report.rb --self-test
  tests/mac/cleanup.sh --self-test
  tests/mac/snapshot-immich.sh --self-test
  tests/mac/snapshot-paperless.sh --self-test
  ruby tests/mac/sanitize-logs.rb --self-test
  ruby tests/mac/pin-protected-input-test.rb
  ruby tests/mac/pin-protected-input-test.rb --self-test
  ruby tests/mac/read-integration-ports-test.rb
  ruby tests/mac/read-integration-ports-test.rb --self-test
CHECKS

MANIFEST_PATH = File.join(ROOT, "tests", "validate-policy.sh")
# The runner opens its list with `cat <<'POLICY_CHECKS'` indented inside
# policy_checks(), and closes it on a bare terminator. Both are matched whole
# rather than searched for, so a line that merely mentions the terminator does
# not move either boundary.
HEREDOC_OPEN = "  cat <<'POLICY_CHECKS'"
HEREDOC_CLOSE = "POLICY_CHECKS"
# A parse that quietly matches nothing satisfies every emptiness test and
# proves nothing, so the floor is a number. It is far enough below the current
# count to survive a real prune and far enough above zero to fail a broken
# read.
MANIFEST_FLOOR = 120

manifest_source = File.file?(MANIFEST_PATH) ? File.readlines(MANIFEST_PATH, chomp: true) : []
open_index = manifest_source.index(HEREDOC_OPEN)
close_index = manifest_source.index(HEREDOC_CLOSE)
check(failures, !open_index.nil?,
      "tests/validate-policy.sh no longer opens its check list with #{HEREDOC_OPEN.inspect}: " \
      "the manifest cannot be read, so nothing below has been checked")
check(failures, !close_index.nil? && !open_index.nil? && close_index > open_index,
      "tests/validate-policy.sh no longer closes its check list on a bare " \
      "#{HEREDOC_CLOSE.inspect} after the opening line: the manifest cannot be read")
manifest = if open_index && close_index && close_index > open_index
             manifest_source[(open_index + 1)...close_index]
           else
             []
           end

# The same list read by a different program. The point is not redundancy but
# that it fails differently: this one knows nothing about Ruby's Array#index,
# matches its boundaries as patterns rather than as whole lines, and streams
# the file, so a boundary the reading above locates on the wrong line does not
# move here in the same direction.
AWK_PROGRAM = [
  '/^  cat <</ && /POLICY_CHECKS/ { inside = 1; next }',
  '/^POLICY_CHECKS$/ { inside = 0 }',
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
      "the two readings of tests/validate-policy.sh disagree: the line reading found " \
      "#{manifest.length} checks and the streamed reading found #{awk_lines.length}, " \
      "differing at #{(awk_lines - manifest).first(3).inspect} / " \
      "#{(manifest - awk_lines).first(3).inspect}")

check(failures, manifest.length >= MANIFEST_FLOOR,
      "read only #{manifest.length} checks out of tests/validate-policy.sh, under the floor " \
      "of #{MANIFEST_FLOOR}: the reading has broken rather than the gate shrunk, and a set " \
      "comparison against a list that short would be an accident")

# One line per check, in both lists. The gate dispatches a line at a time, so a
# command written twice is a check run twice and, once the gate is sharded, a
# command that cannot land in exactly one shard.
repeated_in_manifest = manifest.tally.select { |_, count| count > 1 }.keys
check(failures, repeated_in_manifest.empty?,
      "tests/validate-policy.sh runs #{repeated_in_manifest.inspect} more than once; " \
      "each check belongs on exactly one line")
repeated_in_declaration = GATE_CHECKS.tally.select { |_, count| count > 1 }.keys
check(failures, repeated_in_declaration.empty?,
      "this file declares #{repeated_in_declaration.inspect} more than once")

# The lines themselves, because a count says nothing about which check left. The
# names are capped and the remainder is counted rather than dropped: a real
# divergence is one or two lines, and the case that produces a hundred and fifty
# is a manifest that could not be read at all, which the floor above already
# names -- printing every line there buries that sentence instead of adding to
# it.
NAMED_LIMIT = 12
def named(commands)
  shown = commands.first(NAMED_LIMIT).inspect
  return shown if commands.length <= NAMED_LIMIT

  "#{shown} and #{commands.length - NAMED_LIMIT} more"
end

undeclared = manifest - GATE_CHECKS
check(failures, undeclared.empty?,
      "tests/validate-policy.sh runs checks this file does not declare: " \
      "#{named(undeclared)}. Add them to GATE_CHECKS -- a check the gate runs and nothing " \
      "requires is a check the next prune of the manifest deletes with every gate still green")
unrun = GATE_CHECKS - manifest
check(failures, unrun.empty?,
      "this file declares checks tests/validate-policy.sh does not run: #{named(unrun)}. " \
      "Either the gate stopped running them, which is the failure this check exists for, or " \
      "they were deliberately removed and GATE_CHECKS has not been told")

report(failures, "gate manifest: #{manifest.length} declared checks, all of them run",
       "gate manifest violation(s)")
