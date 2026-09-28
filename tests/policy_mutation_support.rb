#!/usr/bin/env ruby
# Shared harness for the policy mutation checks: build a sandbox from the fixture list,
# break one thing, run the policy scripts, require a named failure. BASE_FIXTURE_PATHS
# is stated rather than derived, so a check is proven to read the file it claims to.

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"
require_relative "case_pool_support"
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
  filter_plugins/vault_artifact_identity.py
  filter_plugins/media_usenet_provider.py
  filter_plugins/immich_preference_schema.py
  module_utils/schema_guards.py
  library/atomic_safe_slurp.py
  generate-secrets.yml
  install-production-auto-deploy.yml
  inventory/group_vars/all/main.yml
  inventory/group_vars/all/media_libraries.yml
  inventory/group_vars/all/media_acquisition.yml
  inventory/group_vars/all/vault.yml.example
  inventory/group_vars/all/vault_arr.yml
  inventory/group_vars/all/vault_audiobookshelf.yml
  inventory/group_vars/all/vault_beszel.yml
  inventory/group_vars/all/vault_bindery.yml
  inventory/group_vars/all/vault_downloaders.yml
  inventory/group_vars/all/vault_dozzle.yml
  inventory/group_vars/all/vault_healthchecks.yml
  inventory/group_vars/all/vault_immich.yml
  inventory/group_vars/all/vault_jellyfin.yml
  inventory/group_vars/all/vault_kapowarr.yml
  inventory/group_vars/all/vault_karakeep.yml
  inventory/group_vars/all/vault_komga.yml
  inventory/group_vars/all/vault_nextcloud.yml
  inventory/group_vars/all/vault_paperless_ngx.yml
  inventory/group_vars/all/vault_pinchflat.yml
  inventory/group_vars/all/vault_pushover.yml
  inventory/group_vars/all/vault_seerr.yml
  inventory/group_vars/all/vault_trailarr.yml
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
  roles/host_prep/tasks/verify_mdraid.yml
  roles/host_prep/defaults/main.yml
  roles/deployment_bundle/defaults/main.yml
  roles/deployment_bundle/meta/argument_specs.yml
  roles/deployment_bundle/files/validate_target.py
  roles/deployment_bundle/files/probe_deployment_lock.py
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
  roles/immich/tasks/verify_originals.yml
  roles/preflight/meta/argument_specs.yml
  roles/preflight/tasks/main.yml
  roles/preflight/tasks/gpu.yml
  roles/production_auto_deploy/defaults/main.yml
  roles/production_auto_deploy/meta/argument_specs.yml
  roles/production_auto_deploy/tasks/main.yml
  roles/production_auto_deploy/templates/config.json.j2
  roles/production_auto_deploy/templates/nas-platform-deploy.j2
  roles/beszel/tasks/alert.yml
  roles/deployment_bundle/tasks/report.yml
  roles/deployment_bundle/tasks/summary.yml
  roles/deployment_bundle/tasks/pushover_publish.yml
  roles/vault_contract/meta/argument_specs.yml
  roles/vault_contract/tasks/main.yml
  roles/pre_upgrade_backup/defaults/main.yml
  roles/pre_upgrade_backup/meta/argument_specs.yml
  roles/pre_upgrade_backup/tasks/main.yml
  roles/pre_upgrade_backup/tasks/pending.yml
  roles/pre_upgrade_backup/tasks/pg_dump.yml
  services/manifest.yml
  services/dozzle/alert_relay.py
  services/downloaders/clamav_gate.py
  services/downloaders/compose.mac.yml
  services/immich/classify_restore.py
  services/kapowarr/tasks.py
  scripts/production_auto_deploy.py
  scripts/image_prune.py
  templates/vault-plain.yml.j2
  tests/contracts/registry.yml
  tests/compose_metadata_filter_test.yml
  tests/ci/suites.conf
  tests/ci/classify_changes.rb
  tests/integration.Dockerfile
  tests/integration.sh
  tests/integration_cleanup_test.sh
  tests/integration_controller.sh
  tests/integration_controller_lib.sh
  tests/integration_lock.sh
  tests/integration_lock_test.sh
  tests/immich_release_helper_test.rb
  tests/immich_selective_helper_integrity_test.rb
  tests/sandbox_cleanup.sh
  tests/sandbox_cleanup_contents.py
  tests/sandbox_cleanup_acquisition_ownership_test.sh
  tests/generate-ephemeral-vault.sh
  tests/generate-secrets-redaction-test.sh
  tests/mac_inventory_path_test.yml
  tests/deployment_lock_refusal_test.yml
  tests/media_acquisition_foundation_test.rb
  tests/host_prep_integration_writer_test.rb
  tests/media_acquisition_foundation_verifier_test.rb
  tests/managed_user_state_filter_test.py
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
  tests/mac/hooks/drift/00-coverage.sh
  tests/mac/hooks/pre-converge/00-coverage.sh
  tests/mac/hooks/drift/15-media-acquisition-foundation.sh
  tests/mac/hooks/verify/15-media-acquisition-foundation.sh
  tests/mac/manual-review.md
  tests/mac/manual-validation-handoff.rb
  tests/mac/manual-validation-runner-test.sh
  tests/mac/report.rb
  tests/mac/media-acquisition-foundation-hook-test.sh
  tests/mac/media-acquisition-foundation-report-test.rb
  tests/mac/media-acquisition-foundation-cleanup-test.sh
  tests/mac/media-acquisition-foundation-hook-fake-docker.rb
  tests/mac/media-acquisition-foundation-cleanup-fake-docker.rb
  tests/mac/run.sh
  tests/mac/run-phase-status-test.sh
  tests/mac/pin-protected-input.rb
  tests/mac/read-integration-ports.rb
  tests/mac/config-isolation.sh
  tests/mac/config-isolation.rb
  tests/mac/snapshot-immich.sh
  tests/mac/snapshot-immich.rb
  tests/mac/snapshot-immich-test.rb
  tests/mac/snapshot-paperless.sh
  tests/mac/snapshot-paperless.rb
  tests/mac/snapshot-paperless-test.rb
  tests/mac/audiobookshelf-drift-hook-test.sh
  tests/mac/hooks/drift/30-audiobookshelf.sh
  tests/mac/sanitize-logs.rb
  tests/contracts/audiobookshelf-audio-test.sh
  tests/contracts/paperless.sh
  tests/mac/verify.sh
  tests/policy_test.rb
  tests/policy_support.rb
  tests/nas_storage_support.rb
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
  "immich" => "immich", "jellyfin" => "jellyfin", "komga" => "komga",
  "paperless-ngx" => "paperless_ngx", "arr" => "arr", "downloaders" => "downloaders",
  "bindery" => "bindery", "kapowarr" => "kapowarr", "pinchflat" => "pinchflat",
  "trailarr" => "trailarr", "seerr" => "seerr", "nextcloud" => "nextcloud",
  "vaultwarden" => "vaultwarden", "karakeep" => "karakeep"
}.freeze

# 22 of 26 roles are present in a sandbox; the four shared ones reached only through
# include_role (and image_prune, deliberately) are absent. The globs are role-agnostic,
# so that loses no detection. roles/pre_upgrade_backup is named explicitly (#836).

# Task files reached through static import_tasks, as PolicySupport.static_role_tasks
# follows. Dynamic include_tasks targets are left out on purpose: copying them lets
# stub-main rows see gated files whose callers the stub removed.
def static_task_files(root, role_root, relative = nil, seen = [])
  relative ||= File.join(role_root, "tasks", "main.yml")
  return [] if seen.include?(relative)

  absolute = File.join(root, relative)
  return [] unless File.file?(absolute)

  document = YAML.safe_load_file(absolute)
  return [relative] unless document.is_a?(Array)

  [relative] + document.flat_map do |task|
    imported = task.is_a?(Hash) ? task["ansible.builtin.import_tasks"] : nil
    file_name = imported.is_a?(Hash) ? imported["file"] : imported
    next [] unless file_name.is_a?(String)

    static_task_files(root, role_root, File.join(role_root, "tasks", file_name), seen + [relative])
  end
end

# The tests/contracts/*.rb programs a wrapper names (#147), derived the way
# tests/run_contracts.rb finds them; a glob over wrappers alone silently reads nothing.
def contract_program_files(root, contract_relative)
  source = File.join(root, contract_relative)
  return [] unless File.file?(source)

  File.read(source).each_line.reject { |line| line.lstrip.start_with?("#") }
      .flat_map { |line| line.scan(%r{tests/contracts/[A-Za-z0-9_./-]+\.rb}) }
      .map { |reference| Pathname.new(reference).cleanpath.to_s }
      .uniq
      .select { |relative| File.file?(File.join(root, relative)) }
end

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
    # Derived, not listed in BASE_FIXTURE_PATHS: a per-service obligation.
    paths << File.join("inventory", "group_vars", "all", "service_#{role}.yml")
    role_root = File.join("roles", role)
    paths << File.join(role_root, "meta", "argument_specs.yml")
    # main.yml plus everything it statically imports: main.yml alone is only an index,
    # which readers with an OR or nil-guard accept silently.
    paths.concat(static_task_files(root, role_root))
    %w[defaults vars].each do |variable_kind|
      role_variables = File.join(role_root, variable_kind, "main.yml")
      paths << role_variables if File.file?(File.join(root, role_variables))
    end
    env_template = File.join(role_root, "templates", "env.j2")
    paths << env_template if File.file?(File.join(root, env_template))
    # Read by policy_integration_test.rb; absent, every mutation fails with a stack trace.
    %w[integration mac].each do |override_kind|
      platform_override = File.join("services", name, "compose.#{override_kind}.yml")
      paths << platform_override if File.file?(File.join(root, platform_override))
    end
  end


  # One expectations file per rostered service, planned ones included.
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
    paths.concat(contract_program_files(root, expected_path))
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

    # ENV is process-wide, so no pooled row may be spawning scripts while it is hostile.
    drain_policy_rows
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
  # Cannot use run_policy_scripts, which strips the hostile GIT_* environment under test;
  # so it counts itself (see POLICY_AUDIT_COVERAGE).
  record_direct_audit_bypass(:direct_policy_script)
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

# YAML.dump drops comments; keep the leading header block because
# tests/policy_vault_test.rb reads it (#650).
def dump_yaml_preserving_header(path, document)
  header = []
  File.foreach(path) do |line|
    stripped = line.strip
    next if stripped == "---" && header.empty?
    break unless stripped.start_with?("#")

    header << line
  end
  body = YAML.dump(document)
  body = body.sub(/\A---\n/, "---\n#{header.join}\n") unless header.empty?
  File.write(path, body)
end

def mutate_yaml_file(root, relative_path)
  path = File.join(root, relative_path)
  document = YAML.safe_load_file(path)
  yield document
  dump_yaml_preserving_header(path, document)
end

# Text mutation with the match count asserted: sub/gsub silently plant nothing when the
# subject text moved, and the row would falsely pass as a real check.
def mutate_text(root, relative_path, pattern, replacement, occurrences: 1)
  path = File.join(root, relative_path)
  body = File.read(path)
  found = body.scan(pattern).length
  raise "#{relative_path}: expected #{occurrences} match(es) of #{pattern.inspect}, found #{found}" unless
    found == occurrences

  File.write(path, occurrences == 1 ? body.sub(pattern, replacement) : body.gsub(pattern, replacement))
end

def service(manifest, name)
  manifest.fetch("services").find { |entry| entry["name"] == name }
end

# Rows declare the scripts that detect their defect (`detected_by:`) rather than all eight.
POLICY_SCRIPTS_BY_NAME = {
  policy: "tests/policy_test.rb",
  platform: "tests/policy_platform_test.rb",
  ci: "tests/policy_ci_test.rb",
  beszel: "tests/policy_beszel_test.rb",
  integration: "tests/policy_integration_test.rb",
  deployment: "tests/policy_deployment_test.rb",
  mac: "tests/policy_mac_test.rb",
  vault: "tests/policy_vault_test.rb"
}.freeze

POLICY_SCRIPTS = POLICY_SCRIPTS_BY_NAME.values.freeze

# `--audit` re-derives every row's detecting set and reports drift; not in CI (costly).
# It sees only expect_failure rows, so it reports its own scope (#439).
POLICY_AUDIT = ARGV.include?("--audit")

# Keyed by call site: a loop is one declaration covering several mutations. One declared
# set per call site; give a loop with varying sets its own call site.
POLICY_AUDIT_SITES = {}

# Counted by the run rather than stated in prose, which went stale (#435). Counted from
# `detected_by`, so it reads the same under --audit.
POLICY_MUTATION_CENSUS = { mutations: 0, single_script: 0, integration: 0, sites: {} }

# A ratchet floor under the census (#725): a collapsed subject list would otherwise pass
# faster. Above passes, below fails naming the value to write.
POLICY_MUTATION_CENSUS_BASELINE = { mutations: 301, call_sites: 215 }.freeze

# What `--audit` did not re-derive, so its verdict states its own scope. Shapes that run
# a checker themselves must call record_direct_audit_bypass; forgetting that is invisible.
# bypass_sites is keyed on the whole frame chain so helper-routed rows stay distinct.
POLICY_AUDIT_COVERAGE = { policy_runs: 0, bypass_shapes: Hash.new(0), bypass_sites: {} }

POLICY_PROGRAM_PATH = File.expand_path($PROGRAM_NAME)

def resolve_policy_scripts(names, label)
  raise "#{label}: detected_by must be a nonempty list of script names" if names.nil? || names.empty?

  names.map do |name|
    POLICY_SCRIPTS_BY_NAME.fetch(name) do
      raise "#{label}: unknown policy script #{name.inspect}; " \
            "known names are #{POLICY_SCRIPTS_BY_NAME.keys.join(', ')}"
    end
  end
end

# Runs the named scripts concurrently (read-only sandboxes; subprocesses release the
# GVL). Results are collected by index so reports keep the caller's order.
def run_policy_scripts(scripts)
  POLICY_AUDIT_COVERAGE[:policy_runs] += 1
  Dir.mktmpdir("nas-platform-policy-") do |sandbox|
    copy_fixture(ROOT, sandbox)
    initialize_fixture_index(sandbox)
    yield sandbox
    execute_policy_scripts(scripts, sandbox)
  end
end

def execute_policy_scripts(scripts, sandbox)
  scripts.map do |script|
    Thread.new do
      stdout, stderr, status = capture3_without_git_routing(RbConfig.ruby, script, chdir: sandbox)
      [script, stdout + stderr, status.success?]
    end
  end.map(&:value)
end

# Rows run CASE_POOL_WORKERS at a time (#727): the mutation block runs in the calling
# thread in file order; only the scripts are deferred. Findings keep serial order;
# POLICY_JOBS=1 takes the serial path.
POLICY_ROW_SLOTS = SizedQueue.new([CASE_POOL_WORKERS, 1].max)
POLICY_ROW_LOCK = Mutex.new
POLICY_PENDING_ROWS = []

# Pooled rows are still running later, so process-wide writes are refused while any is
# pending: drain_policy_rows first.
module PolicyRowProcessState
  def self.refuse(what)
    return if POLICY_PENDING_ROWS.empty?

    raise "#{what} while #{POLICY_PENDING_ROWS.length} pooled policy rows are pending; call drain_policy_rows first"
  end

  def self.guard(target, name, methods, &applies)
    target.singleton_class.prepend(Module.new do
      methods.each do |method|
        define_method(method) do |*args, &block|
          PolicyRowProcessState.refuse("#{name}#{method == :[]= ? '[]=' : ".#{method}"}") if applies.nil? || applies.call(args)
          super(*args, &block)
        end
      end
    end)
  end
end
PolicyRowProcessState.guard(ENV, "ENV", %i[[]= store delete update merge! replace clear])
PolicyRowProcessState.guard(Dir, "Dir", %i[chdir])
PolicyRowProcessState.guard(File, "File", %i[umask]) { |args| !args.empty? }

def defer_policy_row(failures, scripts, settle, &mutation)
  return failures.concat(settle.call(run_policy_scripts(scripts, &mutation))) if CASE_POOL_WORKERS <= 1

  POLICY_AUDIT_COVERAGE[:policy_runs] += 1
  POLICY_ROW_SLOTS.push(true)
  sandbox = Dir.mktmpdir("nas-platform-policy-")
  begin
    copy_fixture(ROOT, sandbox)
    initialize_fixture_index(sandbox)
    mutation.call(sandbox)
  rescue Exception # rubocop:disable Lint/RescueException -- release the slot, then re-raise
    FileUtils.rm_rf(sandbox)
    POLICY_ROW_SLOTS.pop
    raise
  end
  worker = Thread.new do
    settle.call(execute_policy_scripts(scripts, sandbox))
  ensure
    FileUtils.rm_rf(sandbox)
    POLICY_ROW_SLOTS.pop
  end
  POLICY_PENDING_ROWS << [failures, failures.length, worker]
end

def drain_policy_rows
  rows = POLICY_PENDING_ROWS.dup
  POLICY_PENDING_ROWS.clear
  settled = rows.map { |failures, position, worker| [failures, position, worker.value] }
  settled.reverse_each { |failures, position, findings| failures.insert(position, *findings) }
end

# The route around the audit: explicit script list, self-reported failures, no
# `detected_by`. Recorded here rather than at each caller.
def run_policy(scripts = POLICY_SCRIPTS, &mutation)
  record_audit_bypass(:run_policy)
  results = run_policy_scripts(scripts, &mutation)
  output = results.map { |_script, script_output, _ok| script_output }.join
  [output, results.all? { |_script, _script_output, ok| ok }]
end

def run_compose_metadata_behavior
  record_direct_audit_bypass(:compose_metadata_behavior)
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

# Required, not defaulted, so a new row cannot silently run all eight. Too narrow fails
# by name; too wide costs invisible coverage, which --audit finds.
def expect_failure(failures, label, message, detected_by:)
  scripts = resolve_policy_scripts(detected_by, label)
  site = caller_locations(1, 1).first
  record_mutation_census(detected_by, site)
  scripts = POLICY_SCRIPTS if POLICY_AUDIT
  audit_entry = register_audit_site(label, detected_by, site) if POLICY_AUDIT
  settle = lambda do |results; output, findings|
    POLICY_ROW_LOCK.synchronize { merge_audit_detection(audit_entry, message, results) } if POLICY_AUDIT

    output = results.map { |_script, script_output, _ok| script_output }.join
    findings = []
    findings << "#{label}: policy unexpectedly passed" if results.all? { |_s, _o, ok| ok }
    findings << "#{label}: missing failure message #{message.inspect}" unless output.include?(message)
    findings << "#{label}: emitted a Ruby stack trace" if output.match?(/\.rb:\d+:in [`']/)
    findings
  end
  defer_policy_row(failures, scripts, settle) { |root| yield root }
end

def detecting_script_names(message, results)
  results.filter_map do |script, output, ok|
    detected = !ok || output.include?(message) || output.match?(/\.rb:\d+:in [`']/)
    POLICY_SCRIPTS_BY_NAME.key(script) if detected
  end
end

def record_mutation_census(declared, site)
  POLICY_MUTATION_CENSUS[:mutations] += 1
  POLICY_MUTATION_CENSUS[:single_script] += 1 if declared.length == 1
  POLICY_MUTATION_CENSUS[:integration] += 1 if declared.include?(:integration)
  POLICY_MUTATION_CENSUS[:sites][site.lineno] = true
end

# Printed in full, floored on mutations and call sites (#725). The floor is an argument
# so tests/policy_audit_coverage_test.rb can drive it; printed before report/1.
def report_mutation_census(failures, baseline: POLICY_MUTATION_CENSUS_BASELINE)
  drain_policy_rows
  observed = { mutations: POLICY_MUTATION_CENSUS[:mutations],
               call_sites: POLICY_MUTATION_CENSUS[:sites].length }
  puts "policy mutation census: #{observed[:mutations]} expect_failure mutations " \
       "at #{observed[:call_sites]} call sites; " \
       "#{POLICY_MUTATION_CENSUS[:single_script]} declare a single script, " \
       "#{POLICY_MUTATION_CENSUS[:integration]} declare " \
       "#{POLICY_SCRIPTS_BY_NAME.fetch(:integration)}"
  puts "policy mutation census floor: #{baseline.fetch(:mutations)} mutations at " \
       "#{baseline.fetch(:call_sites)} call sites, " \
       "headroom #{format('%+d', observed[:mutations] - baseline.fetch(:mutations))} mutations " \
       "#{format('%+d', observed[:call_sites] - baseline.fetch(:call_sites))} call sites"
  check_mutation_census_floor(failures, observed, baseline)
end

# Both figures, since a refactor can collapse either alone. The message states the value
# to write because only the causing diff says whether the drop is legitimate.
def check_mutation_census_floor(failures, observed, baseline)
  { mutations: "expect_failure mutations", call_sites: "call sites" }.each do |figure, noun|
    next if observed.fetch(figure) >= baseline.fetch(figure)

    failures << "policy mutation census: #{observed.fetch(figure)} #{noun}, below the floor of " \
                "#{baseline.fetch(figure)} declared by POLICY_MUTATION_CENSUS_BASELINE in " \
                "tests/policy_mutation_support.rb. A deliberate prune writes #{observed.fetch(figure)} " \
                "there in the same diff; anything else has stopped registering rows that still exist"
  end
end

def record_audit_detection(label, message, declared, results, site)
  merge_audit_detection(register_audit_site(label, declared, site), message, results)
end

def register_audit_site(label, declared, site)
  entry = POLICY_AUDIT_SITES[site.lineno] ||= { declared: declared, actual: [], label: label, mutations: 0 }
  entry[:mutations] += 1
  entry
end

def merge_audit_detection(entry, message, results)
  entry[:actual] |= detecting_script_names(message, results)
end

def record_audit_bypass(shape)
  POLICY_AUDIT_COVERAGE[:bypass_shapes][shape] += 1
  chain = caller_locations.filter_map do |frame|
    frame.lineno if File.expand_path(frame.path) == POLICY_PROGRAM_PATH
  end
  POLICY_AUDIT_COVERAGE[:bypass_sites][[shape, chain]] = true
end

# Counts its own run, which run_policy_scripts never sees.
def record_direct_audit_bypass(shape)
  POLICY_AUDIT_COVERAGE[:policy_runs] += 1
  record_audit_bypass(shape)
end

# Both directions: newly detecting is lost coverage; no longer detecting is a stale entry.
def audit_policy_detection(failures)
  drain_policy_rows
  return unless POLICY_AUDIT

  POLICY_AUDIT_SITES.each do |lineno, entry|
    missing = entry[:actual] - entry[:declared]
    stale = entry[:declared] - entry[:actual]
    where = "line #{lineno} (#{entry[:label]})"
    failures << "#{where}: detected_by omits #{missing.join(', ')}" if missing.any?
    failures << "#{where}: detected_by names #{stale.join(', ')}, which no longer detect it" if stale.any?
  end
  report_audit_coverage(failures)
end

# The audit's scope, printed with its verdict. Floored at two re-derived sites so a
# silently emptied list fails; no floor on bypasses (the tripwire covers that).
def report_audit_coverage(failures)
  mutations = POLICY_AUDIT_SITES.sum { |_lineno, entry| entry.fetch(:mutations) }
  shapes = POLICY_AUDIT_COVERAGE[:bypass_shapes]
  bypassed = shapes.values.sum
  breakdown = shapes.sort_by { |shape, _count| shape }.map { |shape, count| "#{count} #{shape}" }.join(", ")
  puts "policy mutation audit: #{mutations} mutations at #{POLICY_AUDIT_SITES.length} call sites " \
       "re-derived against all eight scripts; #{bypassed} mutations at " \
       "#{POLICY_AUDIT_COVERAGE[:bypass_sites].length} call sites never reach expect_failure and " \
       "were not re-derived (#{breakdown})"

  failures << "policy mutation audit: re-derived only #{POLICY_AUDIT_SITES.length} call sites" if
    POLICY_AUDIT_SITES.length < 2
  unlabelled = POLICY_AUDIT_COVERAGE[:policy_runs] - mutations
  return if unlabelled == bypassed

  failures << "policy mutation audit: #{unlabelled} runs bypass the re-derivation but #{bypassed} " \
              "are labelled; a shape outside the audit is not being reported"
end

# A backtrace outranks `FAIL` lines, which outrank the first line of output.
POLICY_DIAGNOSTIC_LIMIT = 500

def policy_failure_diagnostic(output)
  lines = output.lines.map(&:strip).reject(&:empty?)
  diagnostic = lines.find { |line| line.match?(/\.rb:\d+:in [`']/) } ||
               lines.find { |line| line.start_with?("FAIL ") } ||
               lines.first || "policy failed"
  diagnostic[0, POLICY_DIAGNOSTIC_LIMIT]
end

# Each failing script reported by name: the joined output once showed a missing fixture
# under policy_test.rb's success banner.
def expect_success(failures, label)
  record_audit_bypass(:expect_success)
  results = run_policy_scripts(POLICY_SCRIPTS) { |root| yield root }
  results.each do |script, output, ok|
    next if ok

    failures << "#{label}: #{script}: #{policy_failure_diagnostic(output)}"
  end
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
  # Plain mappings, not anchors: mutate_yaml_file loads without aliases. policy_test.rb
  # requires the fragments to be present.
  File.write(File.join(compose_dir, "compose.yml"), <<~YAML)
    ---
    x-logging:
      driver: json-file
      options:
        max-size: 10m
        max-file: "3"

    x-healthcheck-defaults:
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

    services:
      broker:
        image: docker.io/valkey/valkey:9-alpine@sha256:#{'0' * 64}
        cpuset: \${PLATFORM_CONTAINER_CPUSET:?}
        cpus: 0.5
        restart: unless-stopped
        security_opt:
          - no-new-privileges:true
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
        security_opt:
          - no-new-privileges:true
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
        security_opt:
          - no-new-privileges:true
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
        security_opt:
          - no-new-privileges:true
        logging:
          driver: json-file
          options:
            max-size: 10m
            max-file: "3"
      tika:
        image: docker.io/apache/tika:3.0.0@sha256:#{'0' * 64}
        cpuset: \${PLATFORM_CONTAINER_CPUSET:?}
        cpus: 2.0
        # For the same reason the fragments above are spelled out: this image is
        # on MEMORY_SELF_SIZING_IMAGES, so policy_test.rb requires a limit on it,
        # and a synthetic stack omitting one would fail every row built on this
        # fixture for a reason none of them is testing.
        mem_limit: 2g
        restart: unless-stopped
        security_opt:
          - no-new-privileges:true
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

  storage_path = File.join(root, "inventory", "group_vars", "all", "service_paperless_ngx.yml")
  storage = File.exist?(storage_path) ? YAML.safe_load_file(storage_path) : {}
  (storage["nas_storage_paperless_ngx"] ||= []) << {
    "path" => "{{ nas_docker_root }}/paperless-ngx/data",
    "mode" => "0755",
    "recovery" => "critical"
  }
  if File.exist?(storage_path)
    dump_yaml_preserving_header(storage_path, storage)
  else
    File.write(storage_path, YAML.dump(storage))
  end
end
