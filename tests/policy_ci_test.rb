#!/usr/bin/env ruby
# CI and policy-runner policy: tests/ci/suites.conf content, gate registration of
# every policy script, and collection pins.

require "open3"
require "rbconfig"
require "set"
require "yaml"
require_relative "ci/classify_changes"
require_relative "policy_support"

include PolicySupport
include TestScaffold

failures = []

# tests/ci/suites.conf is the single table integration.sh and the CI classifier read.
integration_path = File.join(ROOT, "tests", "integration.sh")
suite_table_path = File.join(ROOT, "tests", "ci", "suites.conf")
integration_body = File.file?(integration_path) ? File.read(integration_path) : ""
controller_path = File.join(ROOT, "tests", "integration_controller.sh")
controller_body = File.file?(controller_path) ? File.read(controller_path) : ""

suite_rows = []
malformed_rows = []
if File.file?(suite_table_path)
  File.readlines(suite_table_path, chomp: true).each do |line|
    fields = line.sub(/#.*/, "").split
    next if fields.empty?

    if fields.length == 3
      suite, kind, tags = fields
      suite_rows << [suite, kind, tags == "-" ? [] : tags.split(",")]
    else
      malformed_rows << line
    end
  end
  check(failures, malformed_rows.empty?,
        "tests/ci/suites.conf: malformed row(s) #{malformed_rows.inspect}")
  check(failures, !suite_rows.empty?,
        "tests/ci/suites.conf: the suite table could not be read")
end
# Keyed by the suite name the table writes, which is also the manifest's service
# name -- the classifier's underscored lane key is its own concern.
suite_tags = suite_rows.to_h { |suite, _kind, tags| [suite, tags] }

# Inert vs real acquisition lanes derive from the catalog plus manifest status.
acquisition_catalog = begin
  YAML.safe_load_file(File.join(ROOT, "config", "media-acquisition.yml"))
rescue Errno::ENOENT, Psych::Exception
  nil
end
acquisition_projects = acquisition_catalog.is_a?(Hash) && acquisition_catalog["projects"].is_a?(Hash) ?
                         acquisition_catalog.fetch("projects").keys : []
check(failures, !acquisition_projects.empty?,
      "config/media-acquisition.yml: the acquisition project roster could not be read")
planned_acquisition_lanes = acquisition_projects & PolicySupport.planned_services(ROOT)
implemented_acquisition_lanes = acquisition_projects & PolicySupport.implemented_services(ROOT)

# planned_acquisition_lanes is [] today, so the guards using it are dormant, not holes:
# #639 found every failure mode caught here or in the classifier/foundation tests.
# Re-measure on current main before adding a floor back.

unless suite_rows.empty?
  suite_rows.each do |suite, kind, tags|
    next unless %w[acquisition service].include?(kind)
    next if planned_acquisition_lanes.include?(suite)

    check(failures, (%w[host_prep deployment_bundle] - tags).empty?,
          "service lane #{suite} must converge host_prep and deployment_bundle, the shared prerequisites every service role needs")
  end

  # Dormant (see above): a planned project converges only the inert foundation tags.
  planned_acquisition_lanes.each do |lane|
    row = suite_rows.find { |suite, _kind, _tags| suite == lane }
    check(failures,
          row && row.last == %w[host_prep deployment_bundle media_acquisition_foundation],
          "acquisition foundation suite #{lane} must converge only shared inert foundation tags")
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

# Assert the [defaults] marker too: an empty or unreadable ansible.cfg also lacks the key.
check(failures, config.match?(/^\[defaults\]$/),
      "ansible.cfg must carry a [defaults] section for its keys to be read")
check(failures, !config.match?(/^\s*inventory\s*=/),
      "ansible.cfg must name no default inventory, so a forgotten -i cannot " \
      "silently target a host")

# ansible-galaxy fills .ansible/ in the repo root; git hides it only while empty.
gitignore = File.read(File.join(ROOT, ".gitignore"))
check(failures, gitignore.match?(/^\.ansible\/$/),
      "gitignore must exclude the local ANSIBLE_HOME that ansible-galaxy " \
      "fills in the repository root")

ci = YAML.safe_load_file(File.join(ROOT, ".github", "workflows", "ci.yml"))
ci_commands = ci.fetch("jobs", {}).values.flat_map do |job|
  Array(job["steps"]).filter_map { |step| step["run"] if step.is_a?(Hash) }
end.flat_map { |run| run.to_s.lines.map(&:strip) }
# Diagnostic text is load-bearing: tests/policy_manifest_test.rb plants this defect
# and requires this exact sentence back.
gate_invocations = ci_commands.select { |command| command.start_with?("tests/validate-policy.sh") }
check(failures, !gate_invocations.empty?,
      "CI must run tests/validate-policy.sh")
check(failures, gate_invocations.length == 1,
      "CI must invoke the policy gate from exactly one step, found " \
      "#{gate_invocations.inspect}: the gate is sharded across the legs of one matrix, and a " \
      "second invocation is a leg running a third of the manifest that is not its own")
check(
  failures,
  ci_commands.include?(
    "ansible-playbook -i inventory/local.yml install-production-auto-deploy.yml --syntax-check"
  ),
  "CI must syntax-check install-production-auto-deploy.yml"
)

# Anonymous ghcr.io pulls share a per-IP bucket (toomanyrequests). Asserted here too
# because this suite runs on the mutated tree.
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

# Pre-pull with retry, keyed by site.yml tag: a service missing from the map pulls
# inside docker_compose_v2 with no retry.
image_source_block = integration_body[/^service_image_sources='\n(.*?)'$/m].to_s
service_image_sources = image_source_block.scan(/^([a-z0-9_-]+) ([a-z0-9-]+)$/)
check(failures, !service_image_sources.empty?,
      "tests/integration.sh: service_image_sources could not be read")
check(failures, integration_body.include?('pull_image "$runner_image"'),
      "tests/integration.sh must retry the base image pull it falls back to: " \
      "Docker Hub is anonymous here")
check(failures, integration_body.include?("prepull_images\n"),
      "tests/integration.sh must pre-pull the suite's images before the converge")

# The published controller image keeps Docker Hub pulls off every lane; each line
# below is silently reversible, so it is pinned here as well as in workflow_test.rb.
toolchain_dockerfile_path = File.join(ROOT, "tests", "integration.Dockerfile")
toolchain_dockerfile = File.file?(toolchain_dockerfile_path) ? File.read(toolchain_dockerfile_path) : ""
check(failures, integration_body.include?("toolchain_dockerfile=tests/integration.Dockerfile"),
      "tests/integration.sh must name the Dockerfile its controller image is built from")
# Naming it in the harness puts it in the classifier's harness closure.
check(failures, ClassifyChanges::INTEGRATION_HARNESS_PATHS.include?("tests/integration.Dockerfile"),
      "the controller Dockerfile must route as a harness input, not as a policy-gate test")
resolve_index = integration_body.index("resolve_controller_image || return 1")
service_skip_index = integration_body.index('[ "$pull_candidate" = "$controller_image" ]')
check(failures, !resolve_index.nil? && !service_skip_index.nil? && resolve_index < service_skip_index,
      "the pre-pull must resolve the controller image before it enumerates services, " \
      "and must skip whatever the controller actually runs from")
check(failures, integration_body.include?("cleanup_sandbox_image=$controller_image"),
      "the sandbox teardown must reuse the resolved controller image: every lane " \
      "runs it, so leaving it on the base image restores a Docker Hub pull per lane")
# The collision test uses --pull=never and refuses undigested refs, so it needs an
# image that is both local and digest-pinned.
check(failures, integration_body.include?('MEDIA_CONTROL_COLLISION_IMAGE="$collision_image"'),
      "the collision contract must be handed the resolved fixture image")
check(failures,
      integration_body.include?("resolve_collision_image || return 1") &&
        integration_body.include?("{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}") &&
        integration_body.include?("collision_image=$runner_image"),
      "the collision fixture image must be resolved to a digest-pinned local " \
      "image, falling back to the base image a local build already pulled")
check(failures,
      controller_body.include?('[ "$INTEGRATION_TOOLCHAIN_PREINSTALLED" != true ]') &&
        integration_body.include?('-e INTEGRATION_TOOLCHAIN_PREINSTALLED="$toolchain_preinstalled"'),
      "the in-container install must run only when no built toolchain is in play")
# The fallback and the image must install the same things, or a developer's first
# run and CI converge with different controllers.
%w[docker-cli docker-cli-compose git tar openssl apache2-utils openssh-client].each do |package|
  check(failures, toolchain_dockerfile.include?(package),
        "the controller image must install #{package}, as the in-run fallback does")
end
# --no-cache: an install dying mid-write leaves a Galaxy cache entry every later read
# refuses, which would be baked into the layer.
check(failures,
      toolchain_dockerfile.include?("ansible-core==${ANSIBLE_CORE_VERSION}") &&
        toolchain_dockerfile.include?("requests==${REQUESTS_VERSION}") &&
        toolchain_dockerfile.include?("ansible-galaxy collection install --no-cache"),
      "the controller image must install the pinned Ansible toolchain and " \
      "collections, declining the Galaxy API cache")
# ARG with no default keeps tests/integration.sh the one Renovate-tracked copy.
%w[CONTROLLER_BASE_IMAGE ANSIBLE_CORE_VERSION REQUESTS_VERSION RUBY_PACKAGE CURL_PACKAGE].each do |argument|
  check(failures, toolchain_dockerfile.match?(/^ARG #{argument}$/),
        "the controller image must take #{argument} as an argument with no default")
end
# The sandbox teardown runs `docker run <image> python - ...` and relies on the
# base image's bare command.
check(failures, !toolchain_dockerfile.match?(/^\s*(ENTRYPOINT|CMD)\b/),
      "the controller image must not set an entrypoint or command: the teardown " \
      "runs python through the base image's own")

# Publishing it is the workflow's side of the same contract. Without the job the
# harness still works and every lane silently pays the install again.
toolchain_job = ci.fetch("jobs", {}).fetch("toolchain", {})
toolchain_steps = Array(toolchain_job["steps"]).select { |step| step.is_a?(Hash) }
check(failures,
      toolchain_steps.any? { |step| step.dig("env", "INTEGRATION_TOOLCHAIN_PUBLISH") == "1" },
      "CI must publish the controller toolchain image once per run")
check(failures,
      toolchain_job.fetch("permissions", {}) == { "contents" => "read", "packages" => "write" },
      "the toolchain job must hold exactly the scopes it publishes with")
# A per-suite case arm in the harness would silently split the table again.
check(failures, integration_body.include?("suite_table=$repo_dir/tests/ci/suites.conf"),
      "tests/integration.sh must read its suite tags from tests/ci/suites.conf")
check(failures, !integration_body.match?(/^\s*[a-z][a-z0-9-]*\)\s+fixed_tags=/),
      "tests/integration.sh must not restate per-suite tags: tests/ci/suites.conf owns them")

# Implemented acquisition lanes owe a second enabled converge over their own tags.
ACQUISITION_INFRASTRUCTURE_TAGS = %w[host_prep deployment_bundle media_acquisition_foundation].freeze
enabled_idempotence_service_tags = implemented_acquisition_lanes.to_h do |suite|
  [suite, suite_tags.fetch(suite, []) - ACQUISITION_INFRASTRUCTURE_TAGS]
end
enabled_idempotence_service_tags.each do |suite, service_tags|
  check(failures, !service_tags.empty?,
        "implemented acquisition suite #{suite} must converge at least one service role")
end
enabled_idempotence_contracts = enabled_idempotence_service_tags
                                .reject { |_suite, service_tags| service_tags.empty? }
                                .to_h do |suite, service_tags|
  selection = service_tags.join(",")
  [suite,
   ["run_enabled_idempotence #{selection}", "run_play --tags #{selection} --check --diff"]]
end
# Scan every block: the lane and vault-generator blocks both open with this `if` (#640).
enabled_idempotence_contracts.each do |suite, (idempotence_call, check_call)|
  suite_bodies = controller_body.scan(
    /if \[ "\$INTEGRATION_SUITE" = #{Regexp.escape(suite)} \]; then(.*?)^    fi$/m
  ).flatten
  suite_body = suite_bodies.find { |body| body.include?(idempotence_call) } ||
               suite_bodies.last.to_s
  check(failures, suite_body.include?(idempotence_call),
        "the #{suite} suite must run a second normal enabled convergence")
  check(failures,
        suite_body.include?(check_call) &&
          suite_body.index(idempotence_call).to_i < suite_body.index(check_call).to_i,
        "the #{suite} suite must run enabled idempotence before check mode")
end
check(failures,
      File.read(File.join(ROOT, "tests", "integration_controller_lib.sh"))
          .scan(/^enabled_idempotence_recap_is_clean\(\) \{/).length == 1,
      "tests/integration_controller_lib.sh must define one enabled idempotence " \
      "recap parser")

# Tolerant read: the manifest's shape is policed elsewhere; don't stack-trace twice.
implemented_services = PolicySupport.implemented_services(ROOT)
unless implemented_services.empty?
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

# An identity today (planned_acquisition_lanes is empty), kept as the correct rule
# for a planned lane.
check(failures, (service_image_sources.map(&:first) & planned_acquisition_lanes).empty?,
      "planned acquisition foundation suites must have zero service image sources")

validation_script_path = File.join(ROOT, "tests", "validate-policy.sh")
validation_commands = if owned_file?(validation_script_path, File.join(ROOT, "tests"))
                        File.readlines(validation_script_path).map(&:strip)
                      else
                        []
                      end
# Shard partition (#469): a line can be in the file yet in no shard (a comment, or
# stranded between heredocs), so REQUIRED_CHECKS must land in exactly one shard.
validation_shards = if owned_file?(validation_script_path, File.join(ROOT, "tests"))
                      PolicySupport.gate_shards(validation_script_path)
                    else
                      {}
                    end
REQUIRED_CHECKS = %w[
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
  ruby\ tests/docs_links_test.rb
  ruby\ tests/docs_links_test.rb\ --self-test
  ruby\ tests/run_contracts_test.rb
  ruby\ tests/run_contracts.rb\ --validate-only
  ruby\ tests/jellyfin_contract_test.rb
  ruby\ tests/jellyfin_contract_test.rb\ --self-test
  ruby\ tests/pinchflat_contract_test.rb
  ruby\ tests/pinchflat_contract_test.rb\ --self-test
  ruby\ tests/immich_contract_test.rb
  ruby\ tests/immich_contract_test.rb\ --self-test
  ruby\ tests/paperless_contract_test.rb
  ruby\ tests/paperless_contract_test.rb\ --self-test
  ruby\ tests/nextcloud_contract_test.rb
  ruby\ tests/nextcloud_contract_test.rb\ --self-test
  ruby\ tests/dozzle_contract_test.rb
  ruby\ tests/dozzle_contract_test.rb\ --self-test
  ruby\ tests/arr_contract_test.rb
  ruby\ tests/arr_contract_test.rb\ --self-test
  ruby\ tests/downloaders_contract_test.rb
  ruby\ tests/downloaders_contract_test.rb\ --self-test
  ruby\ tests/seerr_contract_test.rb
  ruby\ tests/seerr_contract_test.rb\ --self-test
  ruby\ tests/trailarr_contract_test.rb
  ruby\ tests/trailarr_contract_test.rb\ --self-test
  ruby\ tests/bindery_contract_test.rb
  ruby\ tests/bindery_contract_test.rb\ --self-test
  ruby\ tests/kapowarr_contract_test.rb
  ruby\ tests/kapowarr_contract_test.rb\ --self-test
  ruby\ tests/beszel_contract_test.rb
  ruby\ tests/beszel_contract_test.rb\ --self-test
  ruby\ tests/database_managed_users_test.rb
  ruby\ tests/database_managed_users_test.rb\ --self-test
  ruby\ tests/immich_configured_password_test.rb
  ruby\ tests/immich_user_onboarding_test.rb
  ruby\ tests/immich_system_config_test.rb
  ruby\ tests/immich_placement_wait_test.rb
  ruby\ tests/immich_selective_helper_integrity_test.rb
  ruby\ tests/komga_library_reconciliation_test.rb
  ruby\ tests/komga_library_reconciliation_test.rb\ --self-test
  ruby\ tests/komga_contract_test.rb
  ruby\ tests/komga_contract_test.rb\ --self-test
  ruby\ tests/reader_platform_identity_test.rb
  ruby\ tests/capture_helper_identity_test.rb
  ruby\ tests/audiobookshelf_initial_scan_test.rb
  ruby\ tests/audiobookshelf_initial_scan_behavior_test.rb
  ruby\ tests/audiobookshelf_contract_test.rb
  ruby\ tests/audiobookshelf_contract_test.rb\ --self-test
  ruby\ tests/paperless_mail_reconciliation_test.rb
  PYTHONDONTWRITEBYTECODE=1\ "$ansible_python"\ -m\ unittest\ -v\ tests.production_auto_deploy_test
  ruby\ tests/production_auto_deploy_role_test.rb
  PYTHONDONTWRITEBYTECODE=1\ "$ansible_python"\ -m\ unittest\ -v\ tests.image_prune_test
  ruby\ tests/image_prune_role_test.rb
  python3\ -m\ unittest\ -v\ tests/dozzle_alert_relay_test.py
  python3\ tests/deployment_lock_probe_test.py
  tests/deployment_lock_refusal_test.sh
  tests/dozzle_alert_state_symlink_test.sh
  tests/integration_lock_test.sh
  tests/integration_suite_test.sh
  tests/sandbox_cleanup_acquisition_ownership_test.sh
  tests/mac/manual-validation-runner-test.sh
  tests/mac/audiobookshelf-drift-hook-test.sh
  tests/contracts/audiobookshelf-audio-test.sh
  ruby\ tests/mac/report.rb\ --self-test
  tests/mac/cleanup.sh\ --self-test
  tests/mac/snapshot-immich.sh\ --self-test
  ruby\ tests/mac/sanitize-logs.rb\ --self-test
  ruby\ tests/mac/pin-protected-input-test.rb
  ruby\ tests/mac/pin-protected-input-test.rb\ --self-test
  ruby\ tests/mac/read-integration-ports-test.rb
  ruby\ tests/mac/read-integration-ports-test.rb\ --self-test
].freeze
REQUIRED_CHECKS.each do |command|
  check(failures, validation_commands.include?(command),
        "validate-policy.sh must run #{command}")
end
# Scoped to REQUIRED_CHECKS, not the whole manifest: policy_manifest_test.rb declares
# some manifest-line deletions as detected by `mac` only, and --audit would drift.
# gate_manifest_coverage_test.rb covers the rest.
# lives inside the policy set, where the mutation harness can reach it.
REQUIRED_CHECKS.each do |command|
  claiming = validation_shards.select { |_, commands| commands.include?(command) }.keys
  check(failures, claiming.length == 1,
        "validate-policy.sh must run #{command} in exactly one shard, not " \
        "#{claiming.empty? ? 'none' : claiming.inspect}")
end
# Also asserted in workflow_test.rb and gate_manifest_coverage_test.rb, three shards,
# so dropping any one shard leaves two guards. KEEP THEM IN DIFFERENT SHARDS.
workflow_static_shards = ci.dig("jobs", "static", "strategy", "matrix", "shard")
check(failures, workflow_static_shards == validation_shards.keys,
      "CI dispatches static shards #{workflow_static_shards.inspect} while " \
      "tests/validate-policy.sh partitions its manifest into " \
      "#{validation_shards.keys.inspect}: a shard the matrix does not name runs nowhere, and " \
      "every check it holds is still declared and still claimed by exactly one shard")
{
  'PYTHONDONTWRITEBYTECODE=1 "$ansible_python" -m unittest -v tests.production_auto_deploy_test' =>
    "the production auto-deploy poller suite",
  "ruby tests/production_auto_deploy_role_test.rb" =>
    "the production auto-deploy installer suite",
  'PYTHONDONTWRITEBYTECODE=1 "$ansible_python" -m unittest -v tests.image_prune_test' =>
    "the scheduled image prune suite",
  "ruby tests/image_prune_role_test.rb" =>
    "the image prune installer suite"
}.each do |command, description|
  check(failures, validation_commands.count(command) == 1,
        "validate-policy.sh must run #{description} exactly once")
end
check(failures,
      validation_commands.count("ruby tests/immich_configured_password_test.rb") == 1,
      "validate-policy.sh must run ruby tests/immich_configured_password_test.rb exactly once")
# Proxy-to-native conversion keeps the relationship filters fast (580s per converge)
# and is invisible in a unit test.
acquisition_conversion_check =
  'PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_filter_native_arguments_test.py'
check(failures,
      validation_commands.count(acquisition_conversion_check) == 1,
      "validate-policy.sh must run #{acquisition_conversion_check} exactly once")
check(failures,
      validation_commands.count("#{acquisition_conversion_check} --self-test") == 1,
      "validate-policy.sh must run #{acquisition_conversion_check} --self-test exactly once")
# The fixture samples one Configarr field per class; these prove every field projects.
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
# Argument specs are the filters' only input guard; this proves they still refuse.
filter_input_spec_check =
  'PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/filter_input_argument_spec_test.py'
check(failures,
      validation_commands.count(filter_input_spec_check) == 1,
      "validate-policy.sh must run #{filter_input_spec_check} exactly once")
# Bazarr provider keys are validated against no list; this keeps the documented blocks honest.
check(failures,
      validation_commands.count("ruby tests/bazarr_provider_schema_test.rb") == 1,
      "validate-policy.sh must run ruby tests/bazarr_provider_schema_test.rb exactly once")
check(failures,
      validation_commands.count("ruby tests/bazarr_provider_schema_test.rb --self-test") == 1,
      "validate-policy.sh must run ruby tests/bazarr_provider_schema_test.rb --self-test exactly once")
check(failures,
      validation_commands.count("ruby tests/audiobookshelf_initial_scan_test.rb") == 1,
      "validate-policy.sh must run ruby tests/audiobookshelf_initial_scan_test.rb exactly once")
check(failures,
      validation_commands.count("ruby tests/audiobookshelf_initial_scan_behavior_test.rb") == 1,
      "validate-policy.sh must run ruby tests/audiobookshelf_initial_scan_behavior_test.rb exactly once")
# Runs in its own job (it starved the gate); workflow_test.rb requires all three files.
check(failures,
      %w[core bazarr configarr].none? do |part|
        validation_commands.any? do |command|
          command.include?("media_acquisition_reconciliation_#{part}_test.rb")
        end
      end,
      "the media acquisition reconciliation checks belong to their own CI job, " \
      "not to validate-policy.sh")
# Moved from `static` steps into the gate (#653) so they run once, not per shard;
# required both ways so neither the drop nor the triplication returns.
{
  "tests/integration_cleanup_test.sh" => "the integration sandbox cleanup test",
  'PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/immich_probe_status_test.py' =>
    "the Immich probe status rendering test",
  "tests/generate-secrets-redaction-test.sh" => "the generated credential redaction test"
}.each do |command, description|
  check(failures, validation_commands.count(command) == 1,
        "validate-policy.sh must run #{description} exactly once: it left the static job so " \
        "that it runs once rather than once per shard")
  check(failures, ci_commands.none? { |line| line == command },
        "#{description} belongs to validate-policy.sh alone, not to a workflow step beside it")
end
# The mutation harness left the gate (it was the floor); CI must still run it.
check(failures,
      validation_commands.reject { |command| command.start_with?("#") }
                         .none? { |command| command.include?("policy_manifest_test.rb") },
      "the policy mutation harness belongs to its own CI job, not to validate-policy.sh")
check(failures, ci_commands.include?("ruby tests/policy_manifest_test.rb"),
      "CI must run ruby tests/policy_manifest_test.rb")
# The nightly runs --audit in place of the narrow form (#727).
check(failures, ci_commands.include?("ruby tests/policy_manifest_test.rb --audit"),
      "CI must run ruby tests/policy_manifest_test.rb --audit on the nightly")
# The audit-coverage guards are otherwise reached only by the nightly; this sub-second
# check drives them with synthetic rows on every change.
check(failures,
      validation_commands.count("ruby tests/policy_audit_coverage_test.rb") == 1,
      "validate-policy.sh must run ruby tests/policy_audit_coverage_test.rb exactly once")
# gate_manifest_coverage_test.rb cannot require itself: a prune removing its line
# would silently disable the refusal.
check(failures,
      validation_commands.count("ruby tests/gate_manifest_coverage_test.rb") == 1,
      "validate-policy.sh must run ruby tests/gate_manifest_coverage_test.rb exactly once")
# Executing the controller against stubs is only a guard while the gate runs it.
check(failures,
      validation_commands.count("tests/integration_controller_execution_test.sh") == 1,
      "validate-policy.sh must run tests/integration_controller_execution_test.sh " \
      "exactly once")
check(failures,
      validation_commands.count("python3 -m unittest -v tests/dozzle_alert_relay_test.py") == 1,
      "validate-policy.sh must run the Dozzle alert relay unit test exactly once")
check(failures,
      validation_commands.count("tests/dozzle_alert_state_symlink_test.sh") == 1,
      "validate-policy.sh must run the Dozzle alert state symlink test exactly once")
# The deployment lock (#326) is invisible to a syntax check; these prove the probe and
# the real role's refusal against a held lock.
check(failures,
      validation_commands.count("python3 tests/deployment_lock_probe_test.py") == 1,
      "validate-policy.sh must run the deployment lock probe test exactly once")
check(failures,
      validation_commands.count("tests/deployment_lock_refusal_test.sh") == 1,
      "validate-policy.sh must run the concurrent deployment refusal proof exactly once")
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

report(failures, "ci policy: all properties hold", "ci policy violation(s)")
