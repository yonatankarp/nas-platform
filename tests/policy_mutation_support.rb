#!/usr/bin/env ruby
# Shared harness for the policy mutation checks.
#
# Every mutation follows the same shape: build a sandbox from the fixture list,
# break one thing in it, run the policy scripts, and require a named failure. The
# sandbox construction, the fixture list and the expectation helpers live here so
# the mutation files stay a list of what is broken and what must be reported.
#
# BASE_FIXTURE_PATHS is deliberately stated rather than derived from the repository:
# a sandbox built from whatever happens to be on disk would stop proving that a
# policy check reads the file it claims to read.

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"
require_relative "policy_support"

include PolicySupport
include TestScaffold

BASE_FIXTURE_PATHS = %w[
  .gitignore
  .github/workflows/ci.yml
  README.md
  ansible.cfg
  config/managed-user-capabilities.yml
  config/media-acquisition.yml
  controller-requirements.txt
  docs/ansible-basics.md
  docs/adding-a-service.md
  docs/getting-started.md
  docs/getting-started-mac.md
  docs/asustor-adm-rollout.md
  docs/getting-started-nas.md
  filter_plugins/platform_paths.py
  filter_plugins/compose_metadata.py
  filter_plugins/managed_user_state.py
  filter_plugins/vault_managed_user_schema.py
  filter_plugins/vault_credential_schema.py
  filter_plugins/immich_preference_schema.py
  library/atomic_safe_slurp.py
  generate-secrets.yml
  install-production-auto-deploy.yml
  inventory/group_vars/all/main.yml
  inventory/group_vars/all/vault.yml.example
  inventory/group_vars/mac_hosts/main.yml
  inventory/group_vars/nas_hosts/main.yml
  inventory/local.yml
  inventory/mac.yml
  inventory/remote.yml
  requirements.yml
  site.yml
  validate-vault.yml
  verify.yml
  roles/host_prep/meta/argument_specs.yml
  roles/host_prep/tasks/main.yml
  roles/host_prep/tasks/verify_media_acquisition.yml
  roles/deployment_bundle/defaults/main.yml
  roles/deployment_bundle/meta/argument_specs.yml
  roles/deployment_bundle/files/validate_target.py
  roles/deployment_bundle/files/compare_release_trees.py
  roles/deployment_bundle/files/validate_controller_input.py
  roles/deployment_bundle/tasks/controller.yml
  roles/deployment_bundle/tasks/controller_input.yml
  roles/deployment_bundle/tasks/inputs.yml
  roles/deployment_bundle/tasks/main.yml
  roles/deployment_bundle/tasks/target.yml
  roles/deployment_bundle/templates/manifest.yml.j2
  roles/immich/tasks/restore.yml
  roles/immich/tasks/verify_classifier.yml
  roles/preflight/meta/argument_specs.yml
  roles/preflight/tasks/main.yml
  roles/preflight/tasks/gpu.yml
  roles/production_auto_deploy/defaults/main.yml
  roles/production_auto_deploy/meta/argument_specs.yml
  roles/production_auto_deploy/tasks/main.yml
  roles/production_auto_deploy/templates/config.json.j2
  roles/production_auto_deploy/templates/nas-platform-deploy.j2
  roles/production_auto_deploy/templates/ntfy.curl.j2
  roles/beszel/tasks/alert.yml
  roles/ntfy/tasks/deployment_report.yml
  roles/vault_contract/meta/argument_specs.yml
  roles/vault_contract/tasks/main.yml
  services/manifest.yml
  services/dozzle/alert_relay.py
  services/immich/classify_restore.py
  scripts/production_auto_deploy.py
  templates/vault-plain.yml.j2
  tests/contracts/registry.yml
  tests/compose_metadata_filter_test.yml
  tests/integration.sh
  tests/integration_lock.sh
  tests/integration_lock_test.sh
  tests/immich_release_helper_test.rb
  tests/immich_selective_helper_integrity_test.rb
  tests/sandbox_cleanup.sh
  tests/sandbox_cleanup_acquisition_ownership_test.sh
  tests/generate-ephemeral-vault.sh
  tests/generate-secrets-redaction-test.sh
  tests/mac_inventory_path_test.yml
  tests/media_acquisition_foundation_test.rb
  tests/host_prep_integration_writer_test.rb
  tests/media_acquisition_foundation_verifier_test.rb
  tests/managed_user_state_filter_test.py
  tests/ntfy_verify_execution_test.rb
  tests/komga_library_reconciliation_test.rb
  tests/paperless_mail_reconciliation_test.rb
  tests/media_acquisition_reconciliation_core_test.rb
  tests/media_acquisition_reconciliation_bazarr_test.rb
  tests/media_acquisition_reconciliation_configarr_test.rb
  tests/media_acquisition_reconciliation_support.rb
  tests/production_auto_deploy_test.py
  tests/production_auto_deploy_role_test.rb
  tests/safe_slurp_test.py
  tests/safe_slurp_test.yml
  tests/mac/cleanup.sh
  tests/mac/drift.sh
  tests/mac/fixtures.sh
  tests/mac/lib.sh
  tests/mac/run-contract.sh
  tests/mac/hooks/fixtures-seed/00-services.sh
  tests/mac/hooks/fixtures-persistence/00-services.sh
  tests/mac/hooks/fixtures-recreate/00-services.sh
  tests/mac/hooks/verify/30-services.sh
  tests/mac/hooks/drift/15-media-acquisition-foundation.sh
  tests/mac/hooks/verify/15-media-acquisition-foundation.sh
  tests/mac/manual-review.md
  tests/mac/manual-validation-handoff.rb
  tests/mac/manual-validation-runner-test.sh
  tests/mac/report.rb
  tests/mac/media-acquisition-foundation-hook-test.sh
  tests/mac/media-acquisition-foundation-report-test.rb
  tests/mac/media-acquisition-foundation-cleanup-test.sh
  tests/mac/run.sh
  tests/mac/run-phase-status-test.sh
  tests/mac/snapshot-paperless.sh
  tests/mac/audiobookshelf-drift-hook-test.sh
  tests/mac/hooks/drift/30-audiobookshelf.sh
  tests/mac/sanitize-logs.rb
  tests/contracts/audiobookshelf-audio-test.sh
  tests/contracts/paperless.sh
  tests/mac/verify.sh
  tests/policy_test.rb
  tests/policy_support.rb
  tests/http_fixture_support.rb
  tests/policy_platform_test.rb
  tests/policy_ci_test.rb
  tests/policy_beszel_test.rb
  tests/policy_integration_test.rb
  tests/policy_deployment_test.rb
  tests/policy_mac_test.rb
  tests/policy_vault_test.rb
  tests/run_contracts.rb
  tests/verify_deployment_manifest.rb
  tests/validate-policy.sh
].freeze
EXPECTED_FIXTURE_ROLES = {
  "audiobookshelf" => "audiobookshelf", "beszel" => "beszel", "dozzle" => "dozzle",
  "immich" => "immich", "jellyfin" => "jellyfin", "komga" => "komga", "ntfy" => "ntfy",
  "paperless-ngx" => "paperless_ngx", "arr" => "arr", "downloaders" => "downloaders",
  "bindery" => "bindery", "kapowarr" => "kapowarr", "pinchflat" => "pinchflat",
  "trailarr" => "trailarr", "seerr" => "seerr"
}.freeze

def fixture_paths(root = ROOT)
  paths = BASE_FIXTURE_PATHS.dup
  paths.concat(%w[
    scripts/migrate-media-acquisition-vault.py
    tests/media_acquisition_vault_migration_test.py
  ].select { |relative_path| File.file?(File.join(root, relative_path)) })
  manifest_path = File.join(root, "services", "manifest.yml")
  registry_path = File.join(root, "tests", "contracts", "registry.yml")
  raise "duplicate manifest fixture key" unless duplicate_yaml_keys(Psych.parse_stream(File.read(manifest_path))).empty?
  raise "duplicate registry fixture key" unless duplicate_yaml_keys(Psych.parse_stream(File.read(registry_path))).empty?

  manifest = YAML.safe_load_file(manifest_path)
  manifest.fetch("services").each do |entry|
    next unless %w[implemented accepted].include?(entry.fetch("status"))

    name = entry.fetch("name")
    role = entry.fetch("role")
    raise "unsafe manifest fixture identity" unless EXPECTED_FIXTURE_ROLES[name] == role

    paths << File.join("services", name, "compose.yml")
    role_root = File.join("roles", role)
    paths << File.join(role_root, "meta", "argument_specs.yml")
    paths << File.join(role_root, "tasks", "main.yml")
    # A role states its Compose project either in defaults or, where the value is
    # not overridable, in vars. policy_integration_test.rb renders both to prove
    # every service derives its project from the platform namespace.
    %w[defaults vars].each do |variable_kind|
      role_variables = File.join(role_root, variable_kind, "main.yml")
      paths << role_variables if File.file?(File.join(root, role_variables))
    end
    env_template = File.join(role_root, "templates", "env.j2")
    paths << env_template if File.file?(File.join(root, env_template))
    # policy_integration_test.rb reads the disposable-lane overrides of every
    # service that has them, and requires the two lanes to agree on one container
    # identity, so a sandbox without them fails every mutation with a Ruby stack
    # trace instead of the failure under test.
    %w[integration mac].each do |override_kind|
      platform_override = File.join("services", name, "compose.#{override_kind}.yml")
      paths << platform_override if File.file?(File.join(root, platform_override))
    end
  end


  # policy_test.rb reads one pinned expectations file per rostered service, so the
  # sandbox needs every one of them regardless of deployment status: a planned service
  # is still on the roster, and a missing file would fail every mutation below for the
  # wrong reason instead of the one under test.
  manifest.fetch("services").each do |entry|
    name = entry.fetch("name")
    raise "unsafe expectation fixture identity" unless EXPECTED_FIXTURE_ROLES.key?(name)

    paths << File.join("tests", "expected", "#{name}.yml")
  end
  statuses = manifest.fetch("services").to_h { |entry| [entry.fetch("name"), entry.fetch("status")] }
  registry = YAML.safe_load_file(registry_path)
  registry.fetch("contracts").each do |entry|
    raise "invalid registry fixture entry" unless entry.is_a?(Hash) && entry.keys.sort == %w[path service]

    service_name = entry.fetch("service")
    basename = contract_basename(service_name)
    expected_path = "tests/contracts/#{basename}.sh"
    raise "unsafe registry fixture path" unless %w[implemented accepted].include?(statuses[service_name]) &&
                                                entry.fetch("path") == expected_path

    paths << expected_path
  end
  paths.uniq
end

def copy_fixture(source_root, sandbox)
  planned = fixture_paths(source_root).map do |relative_path|
    clean = Pathname.new(relative_path).cleanpath.to_s
    raise "unsafe fixture path" unless clean == relative_path && !Pathname.new(clean).absolute? &&
                                       !Pathname.new(clean).each_filename.include?("..")

    source = File.expand_path(clean, source_root)
    destination = File.expand_path(clean, sandbox)
    source_prefix = File.expand_path(source_root) + File::SEPARATOR
    sandbox_prefix = File.expand_path(sandbox) + File::SEPARATOR
    raise "unsafe fixture source" unless source.start_with?(source_prefix) && owned_file?(source, source_root)
    raise "unsafe fixture destination" unless destination.start_with?(sandbox_prefix)

    [source, destination]
  end

  planned.each do |source, destination|
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.cp(source, destination)
  end
end

def capture3_without_git_routing(*command, **options)
  clean_environment = ENV.each_key.grep(/\AGIT_/).to_h { |name| [name, nil] }
  Open3.capture3(clean_environment, *command, **options)
end

def initialize_fixture_index(sandbox)
  commands = [
    %w[git init -q],
    ["git", "config", "user.name", "Policy Fixture"],
    %w[git config user.email policy-fixture@invalid.example],
    %w[git add -A]
  ]
  commands.each do |command|
    _stdout, stderr, status = capture3_without_git_routing(*command, chdir: sandbox)
    raise "could not initialize policy fixture index: #{stderr.lines.first&.strip}" unless status.success?
  end
end

def check_fixture_index_hostile_environment(failures)
  Dir.mktmpdir("nas-platform-hostile-git-") do |parent|
    sandbox = File.join(parent, "sandbox")
    unrelated = File.join(parent, "unrelated")
    FileUtils.mkdir_p(unrelated)
    copy_fixture(ROOT, sandbox)

    hostile = {
      "GIT_DIR" => File.join(unrelated, ".git"),
      "GIT_WORK_TREE" => unrelated,
      "GIT_INDEX_FILE" => File.join(unrelated, ".git", "index")
    }
    clean_environment = ENV.each_key.grep(/\AGIT_/).to_h { |name| [name, nil] }
    _stdout, stderr, status = Open3.capture3(clean_environment, "git", "init", "-q", unrelated)
    raise "could not initialize unrelated policy repository: #{stderr.lines.first&.strip}" unless status.success?
    File.write(File.join(unrelated, "unrelated.txt"), "must remain untracked\n")
    before_config, = Open3.capture3(clean_environment, "git", "-C", unrelated,
                                    "config", "--local", "--list")
    before_index, = Open3.capture3(clean_environment, "git", "-C", unrelated,
                                   "diff", "--cached", "--binary")

    previous = hostile.to_h { |name, _value| [name, ENV.key?(name) ? ENV[name] : nil] }
    absent = hostile.keys.reject { |name| ENV.key?(name) }
    hostile.each { |name, value| ENV[name] = value }
    begin
      initialize_fixture_index(sandbox)
    ensure
      previous.each { |name, value| ENV[name] = value }
      absent.each { |name| ENV.delete(name) }
    end

    after_config, = Open3.capture3(clean_environment, "git", "-C", unrelated,
                                   "config", "--local", "--list")
    after_index, = Open3.capture3(clean_environment, "git", "-C", unrelated,
                                  "diff", "--cached", "--binary")
    failures << "hostile git routing: fixture repository was not initialized" unless
      File.directory?(File.join(sandbox, ".git"))
    failures << "hostile git routing: unrelated repository configuration changed" unless
      after_config == before_config
    failures << "hostile git routing: unrelated repository index changed" unless
      after_index == before_index
  end
end

def check_direct_policy_hostile_environment(failures, retired_token)
  Dir.mktmpdir("nas-platform-direct-hostile-git-") do |parent|
    sandbox = File.join(parent, "sandbox")
    unrelated = File.join(parent, "unrelated")
    FileUtils.mkdir_p(unrelated)
    copy_fixture(ROOT, sandbox)
    initialize_fixture_index(sandbox)
    File.open(File.join(sandbox, "README.md"), "a") { |file| file.puts(retired_token) }

    clean_environment = ENV.each_key.grep(/\AGIT_/).to_h { |name| [name, nil] }
    [
      ["git", "init", "-q", unrelated],
      ["git", "-C", unrelated, "config", "user.name", "Unrelated Repository"],
      ["git", "-C", unrelated, "config", "user.email", "unrelated@invalid.example"]
    ].each do |command|
      _stdout, stderr, status = Open3.capture3(clean_environment, *command)
      raise "could not prepare unrelated policy repository: #{stderr.lines.first&.strip}" unless status.success?
    end
    unrelated_file = File.join(unrelated, "unrelated.txt")
    File.write(unrelated_file, "staged unrelated content\n")
    _stdout, stderr, status = Open3.capture3(
      clean_environment, "git", "-C", unrelated, "add", "unrelated.txt"
    )
    raise "could not stage unrelated policy fixture: #{stderr.lines.first&.strip}" unless status.success?
    File.write(unrelated_file, "modified unrelated content\n")

    inspect_unrelated = lambda do
      commands = {
        "configuration" => %w[config --local --list],
        "index" => %w[ls-files --stage -z],
        "worktree status" => %w[status --porcelain=v2 -z --untracked-files=all]
      }
      state = commands.to_h do |label, arguments|
        stdout, inspection_error, inspection_status = Open3.capture3(
          clean_environment, "git", "-C", unrelated, *arguments
        )
        raise "could not inspect unrelated policy repository: #{inspection_error.lines.first&.strip}" unless
          inspection_status.success?

        [label, stdout]
      end
      state.merge("worktree content" => File.binread(unrelated_file))
    end
    before = inspect_unrelated.call

    hostile_environment = clean_environment.merge(
      "GIT_DIR" => File.join(unrelated, ".git"),
      "GIT_WORK_TREE" => unrelated,
      "GIT_INDEX_FILE" => File.join(unrelated, ".git", "index")
    )
    stdout, stderr, status = Open3.capture3(
      hostile_environment, RbConfig.ruby, "tests/policy_test.rb", chdir: sandbox
    )
    output = stdout + stderr
    failures << "direct hostile git routing: policy unexpectedly passed" if status.success?
    failures << "direct hostile git routing: missing retired README diagnostic" unless
      output.include?("retired declaration remains: README.md")
    after = inspect_unrelated.call
    before.each do |label, value|
      failures << "direct hostile git routing: unrelated #{label} changed" unless after.fetch(label) == value
    end
  end
end

def check_fixture_index_containment(failures)
  source_index_before, source_error, source_status = capture3_without_git_routing(
    "git", "diff", "--cached", "--binary", chdir: ROOT
  )
  unless source_status.success?
    failures << "fixture index containment: could not inspect source index: #{source_error.lines.first&.strip}"
    return
  end

  Dir.mktmpdir("nas-platform-index-containment-") do |sandbox|
    copy_fixture(ROOT, sandbox)
    failures << "fixture index containment: copied fixture unexpectedly contains .git" if
      File.exist?(File.join(sandbox, ".git"))
    initialize_fixture_index(sandbox)

    _head, _head_error, head_status = capture3_without_git_routing(
      "git", "rev-parse", "--verify", "HEAD", chdir: sandbox
    )
    failures << "fixture index containment: fixture must not contain a commit" if head_status.success?
    staged, staged_error, staged_status = capture3_without_git_routing(
      "git", "diff", "--cached", "--name-only", "-z", chdir: sandbox
    )
    unless staged_status.success?
      failures << "fixture index containment: could not inspect fixture index: #{staged_error.lines.first&.strip}"
    end
    failures << "fixture index containment: fixture files were not staged" if
      staged_status.success? && staged.split("\0").empty?
  end

  source_index_after, source_error, source_status = capture3_without_git_routing(
    "git", "diff", "--cached", "--binary", chdir: ROOT
  )
  unless source_status.success?
    failures << "fixture index containment: could not re-inspect source index: #{source_error.lines.first&.strip}"
  end
  failures << "fixture index containment: source repository index changed" if
    source_status.success? && source_index_after != source_index_before
end

def mutate_manifest(root)
  path = File.join(root, "services", "manifest.yml")
  manifest = YAML.safe_load_file(path)
  yield manifest
  File.write(path, YAML.dump(manifest))
end

def mutate_yaml_file(root, relative_path)
  path = File.join(root, relative_path)
  document = YAML.safe_load_file(path)
  yield document
  File.write(path, YAML.dump(document))
end

def service(manifest, name)
  manifest.fetch("services").find { |entry| entry["name"] == name }
end

# Every policy script the suite is split across. A mutation may be caught by any of
# them, so all of them run against one sandbox and their output is concatenated: a
# check that moved to another file must still report, not silently stop mattering.
POLICY_SCRIPTS = %w[
  tests/policy_test.rb
  tests/policy_platform_test.rb
  tests/policy_ci_test.rb
  tests/policy_beszel_test.rb
  tests/policy_integration_test.rb
  tests/policy_deployment_test.rb
  tests/policy_mac_test.rb
  tests/policy_vault_test.rb
].freeze

def run_policy(scripts = POLICY_SCRIPTS)
  Dir.mktmpdir("nas-platform-policy-") do |sandbox|
    copy_fixture(ROOT, sandbox)
    initialize_fixture_index(sandbox)
    yield sandbox
    output = ""
    succeeded = true
    scripts.each do |script|
      stdout, stderr, status = capture3_without_git_routing(RbConfig.ruby, script, chdir: sandbox)
      output += stdout + stderr
      succeeded &&= status.success?
    end
    [output, succeeded]
  end
end

def run_compose_metadata_behavior
  Dir.mktmpdir("nas-platform-compose-metadata-") do |sandbox|
    copy_fixture(ROOT, sandbox)
    initialize_fixture_index(sandbox)
    yield sandbox
    stdout, stderr, status = capture3_without_git_routing(
      "ansible-playbook", "-i", "localhost,", "-c", "local",
      "tests/compose_metadata_filter_test.yml", chdir: sandbox
    )
    [stdout + stderr, status]
  end
end

def expect_failure(failures, label, message)
  output, succeeded = run_policy { |root| yield root }
  failures << "#{label}: policy unexpectedly passed" if succeeded
  failures << "#{label}: missing failure message #{message.inspect}" unless output.include?(message)
  failures << "#{label}: emitted a Ruby stack trace" if output.match?(/\.rb:\d+:in [`']/)
end

def expect_success(failures, label)
  output, succeeded = run_policy { |root| yield root }
  failures << "#{label}: #{output.lines.first&.strip || 'policy failed'}" unless succeeded
end

def replace_last(body, source, replacement)
  index = body.rindex(source)
  raise "mutation source is absent" unless index

  body[0...index] + replacement + body[(index + source.length)..]
end

def expect_fixture_identity_rejection(failures, label, service_entry)
  Dir.mktmpdir("nas-platform-fixture-source-") do |parent|
    source = File.join(parent, "source")
    sandbox = File.join(parent, "sandbox")
    FileUtils.mkdir_p(File.join(source, "services"))
    FileUtils.mkdir_p(File.join(source, "tests", "contracts"))
    File.write(File.join(source, "services", "manifest.yml"), YAML.dump("services" => [service_entry]))
    File.write(File.join(source, "tests", "contracts", "registry.yml"), YAML.dump("contracts" => []))
    source_sentinel = File.join(parent, "source-sentinel")
    sandbox_sentinel = File.join(parent, "sandbox-sentinel")
    File.write(source_sentinel, "SOURCE_SAFE")
    File.write(sandbox_sentinel, "SANDBOX_SAFE")

    error = begin
      copy_fixture(source, sandbox)
      nil
    rescue StandardError => e
      e
    end
    failures << "#{label}: fixture identity was not rejected clearly" unless error&.message&.include?("unsafe manifest fixture identity")
    failures << "#{label}: source sentinel changed" unless File.read(source_sentinel) == "SOURCE_SAFE"
    failures << "#{label}: sandbox sentinel changed" unless File.read(sandbox_sentinel) == "SANDBOX_SAFE"
  end
end

def write_contract(root, basename, body)
  contract = File.join(root, "tests", "contracts", "#{basename}.sh")
  FileUtils.mkdir_p(File.dirname(contract))
  File.write(contract, body)
  File.chmod(0o755, contract)
end

def register_contract(root, basename)
  registry = File.join(root, "tests", "contracts", "registry.yml")
  FileUtils.mkdir_p(File.dirname(registry))
  service_name = basename == "paperless" ? "paperless-ngx" : basename
  contracts = File.file?(registry) ? YAML.safe_load_file(registry).fetch("contracts") : []
  contracts.reject! { |entry| entry["service"] == service_name }
  contracts << { "service" => service_name, "path" => "tests/contracts/#{basename}.sh" }
  File.write(registry, YAML.dump("contracts" => contracts))
end

def implement_paperless(root)
  mutate_manifest(root) { |manifest| service(manifest, "paperless-ngx")["status"] = "implemented" }
  compose_dir = File.join(root, "services", "paperless-ngx")
  FileUtils.mkdir_p(compose_dir)
  File.write(File.join(compose_dir, "compose.yml"), <<~YAML)
    ---
    services:
      broker:
        image: docker.io/valkey/valkey:9-alpine@sha256:#{'0' * 64}
        cpuset: \${PLATFORM_CONTAINER_CPUSET:?}
        cpus: 0.5
        restart: unless-stopped
        logging:
          driver: json-file
          options:
            max-size: 10m
            max-file: "3"
      db:
        image: docker.io/library/postgres:18-alpine@sha256:#{'0' * 64}
        cpuset: \${PLATFORM_CONTAINER_CPUSET:?}
        cpus: 2.0
        restart: unless-stopped
        logging:
          driver: json-file
          options:
            max-size: 10m
            max-file: "3"
      webserver:
        image: ghcr.io/paperless-ngx/paperless-ngx:2.0@sha256:#{'0' * 64}
        cpuset: \${PLATFORM_CONTAINER_CPUSET:?}
        cpus: 3.0
        restart: unless-stopped
        logging:
          driver: json-file
          options:
            max-size: 10m
            max-file: "3"
      gotenberg:
        image: docker.io/gotenberg/gotenberg:8.35.0@sha256:#{'0' * 64}
        cpuset: \${PLATFORM_CONTAINER_CPUSET:?}
        cpus: 2.0
        restart: unless-stopped
        logging:
          driver: json-file
          options:
            max-size: 10m
            max-file: "3"
      tika:
        image: docker.io/apache/tika:3.0.0@sha256:#{'0' * 64}
        cpuset: \${PLATFORM_CONTAINER_CPUSET:?}
        cpus: 2.0
        restart: unless-stopped
        logging:
          driver: json-file
          options:
            max-size: 10m
            max-file: "3"
  YAML

  role_dir = File.join(root, "roles", "paperless_ngx")
  FileUtils.mkdir_p(File.join(role_dir, "tasks"))
  File.write(File.join(role_dir, "tasks", "main.yml"), <<~YAML)
    ---
    - name: Provision Paperless
      ansible.builtin.uri:
        url: http://127.0.0.1/paperless/
  YAML

  storage_path = File.join(root, "inventory", "group_vars", "all", "main.yml")
  storage = YAML.safe_load_file(storage_path)
  storage.fetch("nas_storage") << {
    "path" => "{{ nas_docker_root }}/paperless-ngx/data",
    "mode" => "0755",
    "recovery" => "critical"
  }
  File.write(storage_path, YAML.dump(storage))
end
