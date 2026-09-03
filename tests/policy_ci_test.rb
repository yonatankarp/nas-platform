#!/usr/bin/env ruby
# CI and policy-runner policy.
#
# One table decides which roles a suite converges -- tests/ci/suites.conf, which
# the integration runner and the CI classifier both read -- so what is policed
# here is that table's content rather than the agreement of two copies of it. The
# runner itself is pinned here: every policy script must be registered in
# validate-policy.sh, which is what stops a check from being written and then
# never run. Collections pin like images do.

require "open3"
require "rbconfig"
require "set"
require "yaml"
require_relative "ci/classify_changes"
require_relative "policy_support"

include PolicySupport
include TestScaffold

failures = []

# tests/ci/suites.conf is the one table that says which roles each suite
# converges: tests/integration.sh reads it for the tags a suite gets when the
# caller passes none, and tests/ci/classify_changes.rb derives its lanes, its CI
# matrix and its tag plans from the same rows. There is no second copy to
# reconcile, so what is checked here is the table itself. Every lane but the
# planned acquisition foundations must name the alerting sink, because a suite
# that leaves ntfy out now fails at the service's deployment report rather than
# at anything the suite is about.
integration_path = File.join(ROOT, "tests", "integration.sh")
suite_table_path = File.join(ROOT, "tests", "ci", "suites.conf")
integration_body = File.file?(integration_path) ? File.read(integration_path) : ""
# What the controller does is asserted against the controller. It is a program
# in a file of its own now rather than escaped text inside an sh -c argument,
# so these read it unescaped, at the place the code they police actually lives.
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

# Which acquisition lanes are inert and which converge a real role is a
# consequence of services/manifest.yml, not a separate fact. It used to be
# written out here twice -- once to exempt the inert lanes from the ntfy
# requirement and once to require they ship no image -- so promoting a project
# meant editing two literals in this file that nothing held to the manifest or to
# each other. The catalog supplies which projects are acquisition projects; the
# manifest supplies whether each one is built yet.
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

unless suite_rows.empty?
  suite_rows.each do |suite, kind, tags|
    next unless %w[acquisition service].include?(kind)
    next if planned_acquisition_lanes.include?(suite)

    check(failures, tags.include?("ntfy"),
          "service lane #{suite} must converge ntfy: its role reports its deployment there")
  end

  planned_acquisition_lanes.each do |lane|
    row = suite_rows.find { |suite, _kind, _tags| suite == lane }
    check(failures,
          row && row.last == %w[host_prep deployment_bundle media_acquisition_foundation],
          "acquisition foundation suite #{lane} must converge only shared inert foundation tags")
    contract = File.join(ROOT, "tests", "contracts", "#{lane}-foundation.sh")
    check(failures, File.file?(contract),
          "acquisition foundation suite #{lane} has no matching static contract")
  end
end
if File.file?(controller_path)
  check(failures,
        controller_body.include?(
          "/repo/tests/contracts/$INTEGRATION_SUITE-foundation.sh static"
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
image_source_block = integration_body[/^service_image_sources='\n(.*?)'$/m].to_s
service_image_sources = image_source_block.scan(/^([a-z0-9_-]+) ([a-z0-9-]+)$/)
check(failures, !service_image_sources.empty?,
      "tests/integration.sh: service_image_sources could not be read")
check(failures, integration_body.include?('pull_image "$runner_image"'),
      "tests/integration.sh must retry the base image pull it falls back to: " \
      "Docker Hub is anonymous here")
check(failures, integration_body.include?("prepull_images\n"),
      "tests/integration.sh must pre-pull the suite's images before the converge")

# The controller toolchain is a published ghcr.io image the harness pulls instead
# of installing apk, pip and ansible-galaxy inside every leg. The saving is not
# the install time -- it is that the base python image stops being a Docker Hub
# pull on every lane, measured at 66 Hub pulls per full matrix before and 52
# after, with the remaining 52 belonging to services. Three lines are what that
# rests on, and each of them is silently reversible, so each is pinned here as
# well as in tests/ci/workflow_test.rb: this is the suite that runs on a mutated
# copy of the tree.
toolchain_dockerfile_path = File.join(ROOT, "tests", "integration.Dockerfile")
toolchain_dockerfile = File.file?(toolchain_dockerfile_path) ? File.read(toolchain_dockerfile_path) : ""
check(failures, integration_body.include?("toolchain_dockerfile=tests/integration.Dockerfile"),
      "tests/integration.sh must name the Dockerfile its controller image is built from")
# Named as a path in the harness rather than only in CI, which is what puts it in
# the classifier's harness closure and therefore keeps it selecting every lane it
# defines. tests/ci/classify_changes_test.rb enforces the other half.
check(failures, ClassifyChanges::INTEGRATION_HARNESS_PATHS.include?("tests/integration.Dockerfile"),
      "the controller Dockerfile must route as a harness input, not as a policy-gate test")
resolve_index = integration_body.index("resolve_controller_image || return 1")
service_skip_index = integration_body.index('[ "$pull_candidate" != "$controller_image" ]')
check(failures, !resolve_index.nil? && !service_skip_index.nil? && resolve_index < service_skip_index,
      "the pre-pull must resolve the controller image before it enumerates services, " \
      "and must skip whatever the controller actually runs from")
check(failures, integration_body.include?("cleanup_sandbox_image=$controller_image"),
      "the sandbox teardown must reuse the resolved controller image: every lane " \
      "runs it, so leaving it on the base image restores a Docker Hub pull per lane")
# Correctness rather than cost. tests/media_control_network_collision_test.sh
# starts its endpoints with --pull=never and refuses a reference that is not
# digest-pinned, so it needs an image that is both local and named by digest.
# Handing it the base image would fail the arr lane on a path that never pulls
# one; handing it a locally built toolchain tag would fail the same lane on the
# digest guard. Both properties are resolved rather than assumed.
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
check(failures,
      toolchain_dockerfile.include?("ansible-core==${ANSIBLE_CORE_VERSION}") &&
        toolchain_dockerfile.include?("requests==${REQUESTS_VERSION}") &&
        toolchain_dockerfile.include?("ansible-galaxy collection install"),
      "the controller image must install the pinned Ansible toolchain and collections")
# Every version the image is built from arrives as an argument, so Renovate keeps
# tracking exactly one copy of each in tests/integration.sh and the two paths
# cannot drift. A default here is how that silently stops being true.
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
# The runner must read the suite table rather than restate it. This is what the
# equality check between two hand-maintained tables used to buy, bought instead
# by there being only one table: a case arm reintroducing per-suite tags in the
# harness is the regression that would silently split them again.
check(failures, integration_body.include?("suite_table=$repo_dir/tests/ci/suites.conf"),
      "tests/integration.sh must read its suite tags from tests/ci/suites.conf")
check(failures, !integration_body.match?(/^\s*[a-z][a-z0-9-]*\)\s+fixed_tags=/),
      "tests/integration.sh must not restate per-suite tags: tests/ci/suites.conf owns them")

# Every acquisition lane that converges a real role owes a second enabled
# convergence, and the roles it converges are the suite's own fixed tags minus the
# shared infrastructure ones. Both used to be transcribed per suite, so a promoted
# project silently skipped the phase until someone remembered to add it.
ACQUISITION_INFRASTRUCTURE_TAGS = %w[host_prep deployment_bundle ntfy media_acquisition_foundation].freeze
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
enabled_idempotence_contracts.each do |suite, (idempotence_call, check_call)|
  suite_body = controller_body[
    /if \[ \$INTEGRATION_SUITE = #{Regexp.escape(suite)} \]; then(.*?)^    fi$/m,
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
      File.read(File.join(ROOT, "tests", "integration_controller_lib.sh"))
          .scan(/^enabled_idempotence_recap_is_clean\(\) \{/).length == 1,
      "tests/integration_controller_lib.sh must define one enabled idempotence " \
      "recap parser")

# The manifest's own shape is policed elsewhere, which reports a malformed
# document or a non-string service name by name. PolicySupport reads it tolerantly
# so the cross-check is skipped rather than raising a second time on the same
# input: a stack trace out of this suite would bury that diagnosis.
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

check(failures, (service_image_sources.map(&:first) & planned_acquisition_lanes).empty?,
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
  ruby\ tests/immich_selective_helper_integrity_test.rb
  ruby\ tests/komga_library_reconciliation_test.rb
  ruby\ tests/komga_library_reconciliation_test.rb\ --self-test
  ruby\ tests/komga_contract_test.rb
  ruby\ tests/komga_contract_test.rb\ --self-test
  ruby\ tests/reader_platform_identity_test.rb
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
  ruby\ tests/mac/pin-protected-input-test.rb
  ruby\ tests/mac/pin-protected-input-test.rb\ --self-test
].each do |command|
  check(failures, validation_commands.include?(command),
        "validate-policy.sh must run #{command}")
end
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
# The structured declarations the relationship filters consume are validated at
# role entry and nowhere else, and an argument spec is only a guard while
# something proves it still refuses a malformed element. Too strict fails a
# deployment, too loose fails nothing, and neither shows up in a syntax check.
filter_input_spec_check =
  'PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/filter_input_argument_spec_test.py'
check(failures,
      validation_commands.count(filter_input_spec_check) == 1,
      "validate-policy.sh must run #{filter_input_spec_check} exactly once")
# media_bazarr_providers is validated against no list of known providers, so a
# misspelled setting key converges and fetches nothing. The documented blocks
# are the operator's protection against that, and they only protect while
# something proves they still validate and still match the deployed version.
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
# The policy mutation harness left the gate for the same reason: it builds a
# sandbox and runs the whole policy set once per mutation, which made it the
# gate's floor rather than one more check in its pool. CI must still run it --
# a check that is in neither place is a guard that silently stopped running.
check(failures,
      validation_commands.reject { |command| command.start_with?("#") }
                         .none? { |command| command.include?("policy_manifest_test.rb") },
      "the policy mutation harness belongs to its own CI job, not to validate-policy.sh")
check(failures, ci_commands.include?("ruby tests/policy_manifest_test.rb"),
      "CI must run ruby tests/policy_manifest_test.rb")
# The controller's dispatch is proved by running it against stubs, not by
# reading its source text. The gate must run that file: a property asserted
# against argv is only a guard while something executes the program, and unlike
# a grep it leaves no trace in the file it guards to say it stopped.
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
