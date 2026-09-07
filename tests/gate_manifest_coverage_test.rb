#!/usr/bin/env ruby
# The policy gate's own check list, declared, and its partition into CI shards.
#
# tests/validate-policy.sh dispatches one bare command per line of its own
# heredocs, and until #469 nothing said what that list should contain. Individual
# lines were required one at a time -- tests/policy_ci_test.rb names about
# ninety, tests/policy_mac_test.rb eleven, tests/policy_test.rb and
# tests/policy_deployment_test.rb a handful each -- which pins the lines somebody
# thought to pin and says nothing at all about the rest. On the order of forty
# lines were required by nothing, so deleting any of them left every check
# green and the gate faster than before. #315 found six of those by auditing the
# manifest against the policy scripts by hand, #334 found a seventh that was in
# no manifest at all, and a hand audit is not a guard.
#
# This is the guard: the three shard lists below and the three heredocs in
# tests/validate-policy.sh must be the same lists, their union must be the whole
# manifest, no line may appear in two shards, and no shard may collapse. The
# diagnostic names the lines that differ.
#
# State what that buys precisely, because it is easy to claim more. Removing a
# check from the gate now takes an edit in two places instead of one, so an
# omission that used to be invisible is a two-place diff a reviewer can see. It
# does NOT make each line exercised: delete a command from a shard heredoc and
# from the matching list below and this check still passes, by construction. The
# improvement is over ~40 lines having been freely prunable with every gate
# green, and that is the whole of it.
#
# WHY THIS MATTERS MORE ONCE THE GATE IS SHARDED, which is what #469 did. An
# unsharded gate that loses a line loses a check. A sharded gate has a second and
# much more efficient way to produce the same defect: drop a line from the
# partition and it runs nowhere, the run goes green, and it goes green *faster*
# than before. There is nothing in a passing CI run to notice that. The union
# assertion below is the only thing that does, which is why it was written before
# the partition existed and why the partition is a literal list rather than
# anything computed: an index-modulo split balances count rather than time, and a
# time-weighted split needs a cost table that drifts silently. A literal list
# costs manual rebalancing, and the gate's own slowest-checks report is what
# makes that an informed act rather than a guess.
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
# Deliberately not here: whether each command's target file exists. The gate
# runs these commands, so a path that does not exist fails there, loudly, with
# the command named -- and asserting it twice would only add a way for this
# check to be wrong.

require "open3"
require_relative "policy_support"

include TestScaffold

failures = []

# The manifest, restated one shard at a time. Copy the heredoc across when a
# check is added or removed: the blocks are deliberately the same shape as the
# ones in tests/validate-policy.sh so the edit is a paste and the diff is
# readable.
#
# WHICH SHARD A CHECK GOES IN is a balance decision, not an arbitrary one, and
# the balance was struck against the post-merge `main` run of bab1dc0
# (2026-09-07): 2342s of check time across 155 checks, with the ten slowest at
# 247, 160, 152, 125, 114, 111, 103, 102, 95 and 75 seconds. Those ten are placed
# by hand so that no two of the top three share a shard -- a shard cannot finish
# faster than its own slowest check, so pairing them wastes a runner -- and the
# rest are round robin through the manifest, which balances count because count
# is all a partition without a cost table can balance.
#
# SPREAD THE WAITS, and this outranks the rule above. A check that spends its
# time waiting still holds one of the four worker slots while consuming none of
# the CPU the other three compete for, so two long waits in one shard cut its
# effective pool from four workers to two. #484 put `beszel_contract_test.rb`
# (86s of wait) and its `--self-test` (85s) in the same shard and that shard's
# other checks inflated by 298s; the move was reverted. Keep them apart.
#
# REBALANCING IS EXPECTED as checks are added, removed and made faster. It is a
# manual act and it is meant to be: the gate prints its ten slowest checks on
# every run, pass or fail, so the figures above can be replaced with a current
# measurement rather than re-derived. What that report cannot support is
# arithmetic: a check's seconds are its wall time at that shard's load, not work
# that can be carried to another shard, and #484 predicted 1170s for the shard
# that measured 1453s by treating them as though it could. #484 also carries the
# isolated per-check table -- elapsed and CPU measured separately, one check at a
# time -- which is the load-invariant version, and the argument that a perfect
# three-way split is worth only about 90s because the gate cannot finish faster
# than its own longest check. Move lines between the shard blocks here and in
# tests/validate-policy.sh together; every assertion below exists to fail when
# only one of the two moves.

SHARD_1 = <<~'CHECKS'.lines(chomp: true).freeze
  ruby tests/policy_test.rb
  ruby tests/policy_beszel_test.rb
  shellcheck --shell=sh -x --exclude=SC2068,SC2070,SC2086 tests/integration_controller.sh
  ruby tests/policy_vault_test.rb
  "$ansible_python" tests/generate_secrets_jinja_regex_test.py
  ruby tests/host_prep_integration_writer_test.rb
  ruby tests/media_acquisition_phase1_test.rb
  ruby tests/media_acquisition_adoption_test.rb
  tests/mac/media-acquisition-foundation-cleanup-test.sh
  ruby tests/paperless_mail_reconciliation_test.rb
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" -m unittest -v tests.image_prune_test
  ruby tests/beszel_telemetry_timeout_test.rb
  python3 -m unittest -v tests/dozzle_alert_relay_test.py
  ruby tests/immich_restore_lifecycle_test.rb
  tests/mac/beszel-telemetry-hook-test.sh
  ruby tests/ci/workflow_test.rb
  ruby tests/docs_links_test.rb --self-test
  tests/mac/snapshot-paperless-context-test.sh
  python3 tests/deployment_target_validator_test.py
  python3 tests/deployment_release_compare_test.py
  ruby tests/managed_users_vault_test.rb
  ruby tests/config_managed_users_test.rb --self-test
  ruby tests/komga_library_reconciliation_test.rb --self-test
  ruby tests/audiobookshelf_initial_scan_test.rb
  ruby tests/immich_user_onboarding_test.rb
  ruby tests/database_managed_users_test.rb
  ruby tests/deployment_summary_test.rb
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
  ruby tests/seafile_contract_test.rb
  ruby tests/arr_contract_test.rb
  ruby tests/downloaders_contract_test.rb --self-test
  ruby tests/trailarr_contract_test.rb
  ruby tests/bindery_contract_test.rb --self-test
  ruby tests/beszel_contract_test.rb --self-test
  ruby tests/contract_structure_mutation_test.rb
  tests/integration_lock_test.sh
  tests/mac/config-isolation.sh
  tests/mac/dozzle-drift-hook-test.sh
  tests/mac/hook-coverage-test.sh
  tests/mac/cleanup.sh --self-test
  ruby tests/mac/sanitize-logs.rb --self-test
  ruby tests/mac/read-integration-ports-test.rb
CHECKS

SHARD_2 = <<~'CHECKS'.lines(chomp: true).freeze
  ruby tests/policy_platform_test.rb
  ruby tests/policy_integration_test.rb
  ruby tests/policy_deployment_test.rb
  ruby tests/gate_manifest_coverage_test.rb
  tests/target_docker_dependency_preflight_test.sh
  ruby tests/media_acquisition_foundation_test.rb
  ruby tests/configarr_job_test.rb
  tests/mac/media-acquisition-foundation-hook-test.sh
  ruby tests/renovate_policy_test.rb
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" -m unittest -v tests.production_auto_deploy_test
  ruby tests/image_prune_role_test.rb
  ruby tests/beszel_telemetry_ansible_test.rb
  python3 -m unittest -v tests/immich_restore_classifier_test.py
  ruby tests/immich_release_helper_test.rb
  ruby tests/immich_selective_helper_integrity_test.rb
  ruby tests/ci/classify_changes_test.rb
  ruby tests/secrets_docs_test.rb
  ruby tests/assert_no_vault_secrets_test.rb
  tests/mac/snapshot-paperless-recovery-test.sh
  python3 tests/deployment_lock_probe_test.py
  python3 tests/deployment_controller_input_test.py
  ruby tests/beszel_password_preservation_test.rb --self-test
  ruby tests/media_managed_users_test.rb
  ruby tests/komga_contract_test.rb
  ruby tests/audiobookshelf_initial_scan_behavior_test.rb
  ruby tests/audiobookshelf_contract_test.rb
  ruby tests/immich_configured_password_test.rb
  ruby tests/database_managed_users_test.rb --self-test
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/managed_user_state_filter_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_filter_native_arguments_test.py --self-test
  ruby tests/bazarr_provider_schema_test.rb
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_servarr_filter_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/vault_managed_user_schema_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/immich_preference_schema_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/container_cpu_filter_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/jellyfin_encoding_schema_test.py
  ansible-playbook -i localhost, -c local tests/compose_metadata_filter_test.yml
  ruby tests/dozzle_quality_test.rb
  ruby tests/jellyfin_contract_test.rb
  ruby tests/pinchflat_contract_test.rb --self-test
  ruby tests/paperless_contract_test.rb
  ruby tests/arr_contract_test.rb --self-test
  ruby tests/seerr_contract_test.rb
  ruby tests/trailarr_contract_test.rb --self-test
  ruby tests/kapowarr_contract_test.rb
  tests/integration_suite_test.sh
  tests/sandbox_cleanup_acquisition_ownership_test.sh
  tests/mac/run-phase-status-test.sh
  tests/mac/audiobookshelf-drift-hook-test.sh
  tests/contracts/audiobookshelf-audio-test.sh
  tests/mac/snapshot-immich.sh --self-test
  ruby tests/mac/pin-protected-input-test.rb
  ruby tests/mac/read-integration-ports-test.rb --self-test
CHECKS

SHARD_3 = <<~'CHECKS'.lines(chomp: true).freeze
  ruby tests/policy_ci_test.rb
  shellcheck --shell=sh tests/integration_controller_lib.sh
  ruby tests/policy_mac_test.rb
  ruby tests/policy_audit_coverage_test.rb
  tests/media_control_network_collision_test.sh static
  ruby tests/media_acquisition_foundation_verifier_test.rb
  ruby tests/reader_platform_identity_test.rb
  ruby tests/capture_helper_identity_test.rb
  ruby tests/mac/media-acquisition-foundation-report-test.rb
  tests/policy_runner_test.sh
  ruby tests/production_auto_deploy_role_test.rb
  ruby tests/beszel_telemetry_probe_test.rb
  python3 tests/beszel_telemetry_module_test.py
  ruby tests/immich_restore_quality_test.rb
  tests/dozzle_alert_state_symlink_test.sh
  ruby tests/ci/validate_results_test.rb
  ruby tests/docs_links_test.rb
  tests/mac/integration-context-test.sh
  tests/mac/snapshot-paperless-drill-throttle-test.sh
  tests/deployment_lock_refusal_test.sh
  ruby tests/managed_user_capabilities_test.rb --self-test
  ruby tests/media_managed_users_test.rb --self-test
  ruby tests/komga_library_reconciliation_test.rb
  ruby tests/komga_contract_test.rb --self-test
  ruby tests/audiobookshelf_contract_test.rb --self-test
  ruby tests/immich_smart_search_retry_test.rb
  ruby tests/ntfy_verify_execution_test.rb
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_identity_rules_test.py
  ruby tests/acquisition_configarr_field_coverage_test.rb
  ruby tests/bazarr_provider_schema_test.rb --self-test
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_bazarr_filter_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/vault_credential_schema_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/immich_response_schema_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/deployment_summary_filter_test.py
  PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/filter_input_argument_spec_test.py
  ruby tests/run_contracts_test.rb
  ruby tests/dozzle_contract_test.rb
  ruby tests/dozzle_contract_test.rb --self-test
  ruby tests/jellyfin_contract_test.rb --self-test
  ruby tests/immich_contract_test.rb
  ruby tests/paperless_contract_test.rb --self-test
  ruby tests/seafile_contract_test.rb --self-test
  ruby tests/downloaders_contract_test.rb
  ruby tests/seerr_contract_test.rb --self-test
  ruby tests/bindery_contract_test.rb
  ruby tests/kapowarr_contract_test.rb --self-test
  ruby tests/beszel_contract_test.rb
  tests/integration_controller_execution_test.sh
  tests/mac/manual-validation-runner-test.sh
  tests/mac/immich-drift-hook-test.sh
  ruby tests/mac/report.rb --self-test
  tests/mac/snapshot-paperless.sh --self-test
  ruby tests/mac/pin-protected-input-test.rb --self-test
CHECKS

SHARDS = { "1" => SHARD_1, "2" => SHARD_2, "3" => SHARD_3 }.freeze
GATE_CHECKS = SHARDS.values.flatten.freeze

MANIFEST_PATH = File.join(ROOT, "tests", "validate-policy.sh")
# A parse that quietly matches nothing satisfies every emptiness test and
# proves nothing, so the floors are numbers. Each is far enough below the
# current count to survive a real prune and far enough above zero to fail a
# broken read.
MANIFEST_FLOOR = 120
# Per shard, and the reason this is not `!empty?`: the shard that should hold
# fifty checks and holds one is the failure that actually happens, and it passes
# every non-emptiness test there is while removing a third of the gate.
SHARD_FLOOR = 30

manifest_shards = PolicySupport.gate_shards(MANIFEST_PATH)
check(failures, !manifest_shards.empty?,
      "tests/validate-policy.sh no longer opens its check lists with " \
      "\"  cat <<'POLICY_CHECKS_<id>'\" and closes each on a bare terminator of the same " \
      "name: the manifest cannot be read, so nothing below has been checked")
manifest = manifest_shards.values.flatten

# The shards the runner actually dispatches, which is a separate statement from
# the shards whose lists exist. A heredoc nothing cats is a third of the gate
# that never runs, and the run stays green because the checks it holds are still
# declared here.
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

# The same list read by a different program. The point is not redundancy but
# that it fails differently: this one knows nothing about PolicySupport.gate_shards,
# matches its boundaries as patterns rather than as whole lines, streams the
# file, and reads straight through the shard boundaries -- so what it produces is
# the union, arrived at without the per-shard bookkeeping above. A boundary the
# reading above locates on the wrong line does not move here in the same
# direction.
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

# One line per check, across the whole partition. The gate dispatches a line at a
# time, so a command written twice is a check run twice -- and a command written
# into two shards is a check that costs two runners while proving what one
# proved.
repeated_in_manifest = manifest.tally.select { |_, count| count > 1 }.keys
check(failures, repeated_in_manifest.empty?,
      "tests/validate-policy.sh runs #{repeated_in_manifest.inspect} more than once; " \
      "each check belongs to exactly one line of exactly one shard")
repeated_in_declaration = GATE_CHECKS.tally.select { |_, count| count > 1 }.keys
check(failures, repeated_in_declaration.empty?,
      "this file declares #{repeated_in_declaration.inspect} in more than one shard; the " \
      "partition must claim each check exactly once")

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
      "tests/validate-policy.sh runs checks no shard of this file declares: " \
      "#{named(undeclared)}. Add them to the matching SHARD_n -- a check the gate runs and " \
      "nothing requires is a check the next prune of the manifest deletes with every gate " \
      "still green")
unrun = GATE_CHECKS - manifest
check(failures, unrun.empty?,
      "this file declares checks tests/validate-policy.sh does not run: #{named(unrun)}. " \
      "Either the gate stopped running them, which is the failure this check exists for, or " \
      "they were deliberately removed and the shard lists have not been told")

# Shard by shard, not only in union. The union assertion above is what keeps a
# check from being lost; this is what keeps it from being *moved* on one side
# only, which is how a shard silently grows past the runner it was sized for
# while the other two idle.
SHARDS.each do |id, declared|
  found = manifest_shards.fetch(id, nil)
  next if found.nil?

  check(failures, found == declared,
        "shard #{id} of tests/validate-policy.sh runs #{found.length} checks and this file " \
        "declares #{declared.length}, differing at #{(found - declared).first(3).inspect} / " \
        "#{(declared - found).first(3).inspect}. The two lists are edited together or the " \
        "partition is a guess")
end

# The floor, per shard and on both readings. A shard emptied on either side is
# the whole defect sharding introduces: the gate reports success having run two
# thirds of its checks, in less time than before, and every other assertion here
# still holds because the union of two shards and an empty one is still a subset
# in one direction.
SHARDS.each do |id, declared|
  check_floor(failures, declared.length, SHARD_FLOOR, "shard #{id} as this file declares it")
end
manifest_shards.each do |id, found|
  check_floor(failures, found.length, SHARD_FLOOR,
              "shard #{id} as tests/validate-policy.sh runs it")
end

# The CI matrix, against the partition it is supposed to dispatch. This is not
# this file's natural business -- tests/ci/workflow_test.rb owns the workflow's
# shape -- and it is here anyway for a reason worth stating, because the reason
# is the same failure mode one level up.
#
# tests/ci/workflow_test.rb is itself one line of one shard. Drop *that* shard
# from the matrix and the guard asserting the matrix is complete is the very
# check that stops running: a third of the gate goes, the run reports success,
# and it reports it faster. The assertion has to live in more than one shard for
# that to be caught, so it lives in the three files that sit in three different
# shards -- this one, tests/policy_ci_test.rb and tests/ci/workflow_test.rb.
# Whichever single shard is dropped, two of the three still run.
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

# ...and the three shards those three guards must sit in, asserted rather than
# asked for in a comment. Three copies of that assertion protect each other only
# while no shard holds two of them and none holds all three; a rebalance that
# collects them costs nothing visible and quietly returns the guard to being one
# line of one shard, which is what this makes a check rather than a hope.
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
