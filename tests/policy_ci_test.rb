#!/usr/bin/env ruby
# CI and policy-runner policy.
#
# Two tables decide which roles a service suite converges, the integration runner's
# and the CI classifier's, and they must agree. The runner itself is pinned here:
# every policy script must be registered in validate-policy.sh, which is what stops
# a check from being written and then never run. Collections pin like images do.

require "open3"
require "rbconfig"
require "set"
require "yaml"
require_relative "policy_support"

include PolicySupport

ROOT = File.expand_path("..", __dir__)
failures = []

def check(failures, condition, message)
  failures << message unless condition
end

# Two tables decide which roles a service suite converges: the integration
# runner's own and the CI classifier's. They must agree, and both must name the
# alerting sink, because a suite that leaves ntfy out now fails at the service's
# deployment report rather than at anything the suite is about.
integration_path = File.join(ROOT, "tests", "integration.sh")
classifier_path = File.join(ROOT, "tests", "ci", "classify_changes.rb")
if File.file?(integration_path) && File.file?(classifier_path)
  planned_acquisition_lanes = %w[bindery kapowarr pinchflat trailarr seerr]
  suite_tags = File.read(integration_path)
                   .scan(/^\s*([a-z][a-z0-9-]*)\)\s+fixed_tags=([a-z0-9_,-]*)\s*;;/)
                   .to_h { |suite, tags| [suite, tags.split(",")] }
  classifier_tags = File.read(classifier_path)[/SERVICE_TAGS = \{(.*?)\}\.freeze/m].to_s
                        .scan(/"([a-z0-9_-]+)"\s*=>\s*%w\[([^\]]*)\]/)
                        .to_h { |lane, tags| [lane, tags.split] }
  check(failures, !classifier_tags.empty?,
        "tests/ci/classify_changes.rb: SERVICE_TAGS could not be read")
  classifier_tags.each do |lane, tags|
    check(failures, suite_tags[lane] == tags,
          "integration suite #{lane} converges #{suite_tags[lane].inspect}, " \
          "CI selects #{tags.inspect}")
    unless planned_acquisition_lanes.include?(lane)
      check(failures, tags.include?("ntfy"),
            "service lane #{lane} must converge ntfy: its role reports its deployment there")
    end
  end

  planned_acquisition_lanes.each do |lane|
    check(failures,
          suite_tags[lane] == %w[host_prep deployment_bundle media_acquisition_foundation],
          "acquisition foundation suite #{lane} must converge only shared inert foundation tags")
    contract = File.join(ROOT, "tests", "contracts", "#{lane}-foundation.sh")
    check(failures, File.file?(contract),
          "acquisition foundation suite #{lane} has no matching static contract")
  end
  check(failures,
        File.read(integration_path).include?(
          '/repo/tests/contracts/"\$INTEGRATION_SUITE"-foundation.sh static'
        ),
        "acquisition foundation suites must execute their matching static contract")
end

# Collections are pinned like every image.
requirements = YAML.safe_load_file(File.join(ROOT, "requirements.yml"))
requirements.fetch("collections").each do |collection|
  check(failures, collection["version"].to_s.match?(/\A\d+\.\d+\.\d+\z/),
        "collection #{collection['name']} must be version-pinned")
end

config = File.read(File.join(ROOT, "ansible.cfg"))
check(failures, config.match?(/^inject_facts_as_vars\s*=\s*False/i),
      "ansible.cfg must disable fact injection, removed in ansible-core 2.24")

ci = YAML.safe_load_file(File.join(ROOT, ".github", "workflows", "ci.yml"))
ci_commands = ci.fetch("jobs", {}).values.flat_map do |job|
  Array(job["steps"]).filter_map { |step| step["run"] if step.is_a?(Hash) }
end.flat_map { |run| run.to_s.lines.map(&:strip) }
check(failures, ci_commands.include?("tests/validate-policy.sh"),
      "CI must run tests/validate-policy.sh")
check(
  failures,
  ci_commands.include?(
    "ansible-playbook -i inventory/local.yml install-production-auto-deploy.yml --syntax-check"
  ),
  "CI must syntax-check install-production-auto-deploy.yml"
)

# Every service image is digest-pinned in services/*/compose.yml, so the suites job
# is the only thing in CI that reads a registry. Anonymous ghcr.io pulls are metered
# per runner IP against a bucket shared with unrelated jobs, which is how a converge
# that changed nothing gets "toomanyrequests" mid-play. The login is asserted here as
# well as in tests/ci/workflow_test.rb because this is the suite that runs on a
# mutated copy of the tree: removing the step has to fail as a policy violation, not
# merely as a workflow contract edit.
suites_job = ci.fetch("jobs", {}).fetch("suites", {})
suites_steps = Array(suites_job["steps"]).select { |step| step.is_a?(Hash) }
registry_login = suites_steps.find { |step| step["uses"].to_s.start_with?("docker/login-action@") }
check(failures, !registry_login.nil?,
      "CI must authenticate to the container registry before pulling service images")
check(failures, registry_login&.dig("with", "registry") == "ghcr.io",
      "the CI registry login must target ghcr.io")
check(failures, registry_login&.dig("with", "password") == "${{ secrets.GITHUB_TOKEN }}",
      "the CI registry login must use the job's own GITHUB_TOKEN")
check(failures, suites_job.fetch("permissions", {}) == { "contents" => "read", "packages" => "read" },
      "the CI suites job must scope its token to contents and packages reads only")

# Authentication lowers the odds of a refusal; it does not make a registry
# reliable, and it does nothing at all for Docker Hub or lscr.io, which the repo
# has no credentials for. So the harness pulls the images itself, ahead of the
# converge and under a bounded retry, keyed by the site.yml tag that converges
# each service. That map is a third table alongside the two reconciled above, so
# it is held to the manifest here: a service the map forgets would be pulled
# without a retry inside community.docker.docker_compose_v2, which is exactly the
# failure mode the retry exists for.
integration_body = File.file?(integration_path) ? File.read(integration_path) : ""
image_source_block = integration_body[/^service_image_sources='\n(.*?)'$/m].to_s
service_image_sources = image_source_block.scan(/^([a-z0-9_-]+) ([a-z0-9-]+)$/)
check(failures, !service_image_sources.empty?,
      "tests/integration.sh: service_image_sources could not be read")
check(failures, integration_body.include?('pull_image "$runner_image"'),
      "tests/integration.sh must retry the controller image pull: Docker Hub is anonymous here")
check(failures, integration_body.include?("prepull_images\n"),
      "tests/integration.sh must pre-pull the suite's images before the converge")

enabled_idempotence_contracts = {
  "arr" => ["run_enabled_idempotence arr", "run_play --tags arr --check --diff"],
  "downloaders" => [
    "run_enabled_idempotence arr,downloaders",
    "run_play --tags arr,downloaders --check --diff"
  ]
}
enabled_idempotence_contracts.each do |suite, (idempotence_call, check_call)|
  suite_body = integration_body[
    /if \[ "\\\$INTEGRATION_SUITE" = #{Regexp.escape(suite)} \]; then(.*?)^    fi$/m,
    1
  ].to_s
  check(failures, suite_body.include?(idempotence_call),
        "the #{suite} suite must run a second normal enabled convergence")
  check(failures,
        suite_body.include?(check_call) &&
          suite_body.index(idempotence_call).to_i < suite_body.index(check_call).to_i,
        "the #{suite} suite must run enabled idempotence before check mode")
end
check(failures,
      integration_body.scan(/^    enabled_idempotence_recap_is_clean\(\) \{/).length == 1,
      "tests/integration.sh must define one enabled idempotence recap parser")

# The manifest's own shape is policed elsewhere, which reports a malformed
# document or a non-string service name by name. Read it tolerantly here and skip
# the cross-check when it is unusable rather than raising a second time on the same
# input: a stack trace out of this suite would bury that diagnosis.
manifest = begin
  YAML.safe_load_file(File.join(ROOT, "services", "manifest.yml"))
rescue Psych::Exception
  nil
end
implemented_services = Array(manifest.is_a?(Hash) ? manifest["services"] : nil)
                       .select { |service| service.is_a?(Hash) && service["status"] == "implemented" }
                       .map { |service| service["name"] }
if !implemented_services.empty? && implemented_services.all?(String)
  mapped_directories = service_image_sources.map(&:last)
  check(failures, mapped_directories.sort == implemented_services.sort,
        "tests/integration.sh service_image_sources must cover every implemented service exactly " \
        "once: maps #{mapped_directories.sort.inspect}, " \
        "manifest has #{implemented_services.sort.inspect}")
end

site_play = begin
  Array(YAML.safe_load_file(File.join(ROOT, "site.yml"))).first
rescue Psych::Exception
  nil
end
site_tags = Array(site_play.is_a?(Hash) ? site_play["roles"] : nil)
            .select { |role| role.is_a?(Hash) }
            .flat_map { |role| Array(role["tags"]) }.uniq
service_image_sources.each do |service_tag, service_directory|
  # site.yml's own shape is policed elsewhere, so cross-check only against a roster
  # that read, for the same reason the manifest read above is tolerant.
  unless site_tags.empty?
    check(failures, site_tags.include?(service_tag),
          "tests/integration.sh maps image source #{service_directory} to #{service_tag}, " \
          "which is not a site.yml role tag")
  end
  check(failures, File.file?(File.join(ROOT, "services", service_directory, "compose.yml")),
        "tests/integration.sh maps #{service_tag} to services/#{service_directory}, " \
        "which has no compose.yml")
end

acquisition_image_tags = %w[bindery kapowarr pinchflat trailarr seerr]
check(failures, (service_image_sources.map(&:first) & acquisition_image_tags).empty?,
      "planned acquisition foundation suites must have zero service image sources")


validation_script_path = File.join(ROOT, "tests", "validate-policy.sh")
validation_commands = if owned_file?(validation_script_path, File.join(ROOT, "tests"))
                        File.readlines(validation_script_path).map(&:strip)
                      else
                        []
                      end
%w[
  ruby\ tests/policy_test.rb
  ruby\ tests/policy_platform_test.rb
  ruby\ tests/policy_ci_test.rb
  ruby\ tests/policy_beszel_test.rb
  ruby\ tests/policy_integration_test.rb
  ruby\ tests/policy_deployment_test.rb
  ruby\ tests/policy_mac_test.rb
  ruby\ tests/policy_vault_test.rb
  ruby\ tests/host_prep_integration_writer_test.rb
  ruby\ tests/media_acquisition_foundation_verifier_test.rb
  tests/mac/media-acquisition-foundation-hook-test.sh
  ruby\ tests/mac/media-acquisition-foundation-report-test.rb
  tests/mac/media-acquisition-foundation-cleanup-test.sh
  ruby\ tests/renovate_policy_test.rb
  ruby\ tests/policy_manifest_test.rb
  ruby\ tests/run_contracts_test.rb
  ruby\ tests/run_contracts.rb\ --validate-only
  ruby\ tests/database_managed_users_test.rb
  ruby\ tests/database_managed_users_test.rb\ --self-test
  ruby\ tests/immich_configured_password_test.rb
  ruby\ tests/immich_user_onboarding_test.rb
  ruby\ tests/immich_selective_helper_integrity_test.rb
  ruby\ tests/komga_library_reconciliation_test.rb
  ruby\ tests/audiobookshelf_initial_scan_test.rb
  ruby\ tests/audiobookshelf_initial_scan_behavior_test.rb
  ruby\ tests/paperless_mail_reconciliation_test.rb
  PYTHONDONTWRITEBYTECODE=1\ "$ansible_python"\ -m\ unittest\ -v\ tests.production_auto_deploy_test
  ruby\ tests/production_auto_deploy_role_test.rb
  python3\ -m\ unittest\ -v\ tests/dozzle_alert_relay_test.py
  tests/dozzle_alert_state_symlink_test.sh
  tests/integration_lock_test.sh
  tests/integration_suite_test.sh
  tests/sandbox_cleanup_acquisition_ownership_test.sh
  tests/mac/manual-validation-runner-test.sh
  tests/mac/audiobookshelf-drift-hook-test.sh
  tests/contracts/audiobookshelf-audio-test.sh
  ruby\ tests/mac/report.rb\ --self-test
  tests/mac/cleanup.sh\ --self-test
  ruby\ tests/mac/sanitize-logs.rb\ --self-test
].each do |command|
  check(failures, validation_commands.include?(command),
        "validate-policy.sh must run #{command}")
end
{
  'PYTHONDONTWRITEBYTECODE=1 "$ansible_python" -m unittest -v tests.production_auto_deploy_test' =>
    "the production auto-deploy poller suite",
  "ruby tests/production_auto_deploy_role_test.rb" =>
    "the production auto-deploy installer suite"
}.each do |command, description|
  check(failures, validation_commands.count(command) == 1,
        "validate-policy.sh must run #{description} exactly once")
end
check(failures,
      validation_commands.count("ruby tests/immich_configured_password_test.rb") == 1,
      "validate-policy.sh must run ruby tests/immich_configured_password_test.rb exactly once")
# The relationship filters are only fast because Ansible's templated proxies are
# converted to plain containers on the way in. That conversion is invisible in a
# unit test and worth 580s of one converge, so the check that pins it, and the
# self-test proving that check bites, both belong to the gate.
acquisition_conversion_check =
  'PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_filter_native_arguments_test.py'
check(failures,
      validation_commands.count(acquisition_conversion_check) == 1,
      "validate-policy.sh must run #{acquisition_conversion_check} exactly once")
check(failures,
      validation_commands.count("#{acquisition_conversion_check} --self-test") == 1,
      "validate-policy.sh must run #{acquisition_conversion_check} --self-test exactly once")
# The fixture now exercises one Configarr field per behavioural class rather
# than all hundred and five, which is only honest while something else proves
# every field still reaches the projection. These two are that something else,
# so the gate has to keep running them.
check(failures,
      validation_commands.count("ruby tests/acquisition_configarr_field_coverage_test.rb") == 1,
      "validate-policy.sh must run ruby tests/acquisition_configarr_field_coverage_test.rb exactly once")
check(failures,
      validation_commands.count(
        "ruby tests/acquisition_configarr_field_coverage_test.rb --self-test"
      ) == 1,
      "validate-policy.sh must run ruby tests/acquisition_configarr_field_coverage_test.rb " \
      "--self-test exactly once")
acquisition_owned_field_check =
  'PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_owned_field_coverage_test.py'
check(failures,
      validation_commands.count(acquisition_owned_field_check) == 1,
      "validate-policy.sh must run #{acquisition_owned_field_check} exactly once")
check(failures,
      validation_commands.count("ruby tests/audiobookshelf_initial_scan_test.rb") == 1,
      "validate-policy.sh must run ruby tests/audiobookshelf_initial_scan_test.rb exactly once")
check(failures,
      validation_commands.count("ruby tests/audiobookshelf_initial_scan_behavior_test.rb") == 1,
      "validate-policy.sh must run ruby tests/audiobookshelf_initial_scan_behavior_test.rb exactly once")
# The reconciliation contract runs in its own workflow job, not in the policy
# gate: inside the gate it competed with every other check for the same four
# cores and made that job the longest in the workflow. tests/ci/workflow_test.rb
# owns the requirement that the job runs all three files.
check(failures,
      %w[core bazarr configarr].none? do |part|
        validation_commands.any? do |command|
          command.include?("media_acquisition_reconciliation_#{part}_test.rb")
        end
      end,
      "the media acquisition reconciliation checks belong to their own CI job, " \
      "not to validate-policy.sh")
check(failures,
      validation_commands.count("python3 -m unittest -v tests/dozzle_alert_relay_test.py") == 1,
      "validate-policy.sh must run the Dozzle alert relay unit test exactly once")
check(failures,
      validation_commands.count("tests/dozzle_alert_state_symlink_test.sh") == 1,
      "validate-policy.sh must run the Dozzle alert state symlink test exactly once")
check(failures,
      validation_commands.count("tests/sandbox_cleanup_acquisition_ownership_test.sh") == 1,
      "validate-policy.sh must run the acquisition cleanup ownership test exactly once")
check(failures,
      validation_commands.count(
        "python3 -m unittest -v tests/immich_restore_classifier_test.py"
      ) == 1,
      "validate-policy.sh must run the Immich restore classifier test exactly once")
check(failures,
      validation_commands.count("ruby tests/immich_restore_quality_test.rb") == 1,
      "validate-policy.sh must run the Immich restore quality test exactly once")
check(failures,
      validation_commands.count("ruby tests/immich_restore_lifecycle_test.rb") == 1,
      "validate-policy.sh must run the Immich restore lifecycle test exactly once")
check(failures,
      validation_commands.count("ruby tests/immich_release_helper_test.rb") == 1,
      "validate-policy.sh must run the Immich release helper test exactly once")
check(failures,
      validation_commands.count("ruby tests/immich_selective_helper_integrity_test.rb") == 1,
      "validate-policy.sh must run the Immich selective helper integrity test exactly once")
check(failures,
      owned_file?(File.join(ROOT, "tests", "immich_release_helper_test.rb"),
                  File.join(ROOT, "tests")),
      "Immich release helper test must be a regular non-symlink file")
check(failures,
      owned_file?(File.join(ROOT, "tests", "immich_selective_helper_integrity_test.rb"),
                  File.join(ROOT, "tests")),
      "Immich selective helper integrity test must be a regular non-symlink file")


if failures.empty?
  puts "ci policy: all properties hold"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} ci policy violation(s)"
end
