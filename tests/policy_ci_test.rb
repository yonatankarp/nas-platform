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
    check(failures, tags.include?("ntfy"),
          "service lane #{lane} must converge ntfy: its role reports its deployment there")
  end
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
check(failures,
      validation_commands.count("ruby tests/audiobookshelf_initial_scan_test.rb") == 1,
      "validate-policy.sh must run ruby tests/audiobookshelf_initial_scan_test.rb exactly once")
check(failures,
      validation_commands.count("ruby tests/audiobookshelf_initial_scan_behavior_test.rb") == 1,
      "validate-policy.sh must run ruby tests/audiobookshelf_initial_scan_behavior_test.rb exactly once")
check(failures,
      validation_commands.count("python3 -m unittest -v tests/dozzle_alert_relay_test.py") == 1,
      "validate-policy.sh must run the Dozzle alert relay unit test exactly once")
check(failures,
      validation_commands.count("tests/dozzle_alert_state_symlink_test.sh") == 1,
      "validate-policy.sh must run the Dozzle alert state symlink test exactly once")
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
