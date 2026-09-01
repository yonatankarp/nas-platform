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
  module_utils/schema_guards.py
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
  tests/ci/suites.conf
  tests/ci/classify_changes.rb
  tests/integration.Dockerfile
  tests/integration.sh
  tests/integration_controller.sh
  tests/integration_controller_lib.sh
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
  tests/mac/pin-protected-input.rb
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

# The task files a role reaches through static import_tasks, main.yml included.
# This follows exactly what PolicySupport.static_role_tasks follows, because that
# is what assembles a role for the readers this fixture has to be able to satisfy,
# and because Ansible resolves an import at parse time -- an imported file is part
# of the role's body, not a separate thing the role calls.
#
# A dynamic include_tasks target is deliberately left out, and that exclusion is
# load-bearing rather than an omission. Ansible resolves an include at runtime with
# vars the caller passes, no reader assembles it into the role, and copying it
# changes what the rows that replace a role's main.yml with a stub can see: with
# managed_users.yml present, policy_test.rb's phase-gate check finds a gated file
# whose caller the stub removed, and four expect_success rows fail on a mutation
# they never made -- measured, not predicted:
#
#   FAIL assert from registered URI result: FAIL roles/ntfy/tasks/managed_users.yml:
#     declares ntfy_managed_users_phase phases provision, subscription_sync, verify
#     but its callers pass none
#
# Enumerated from the role rather than stated, which is the opposite of the rule
# BASE_FIXTURE_PATHS states below, and deliberately so. That rule exists so a policy
# check cannot be credited with reading a file the sandbox never had: the fixture
# names the file, so the check has to find it. This is the other kind of path. A
# role's stage files are not a check's subject, they are the subject's body, and
# they have no fixed names -- a stated list would have to be extended by every
# future split, which is the mistake that produced this bug.
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

# The sibling Ruby programs a contract invokes, which since #147 are where a
# contract's body lives -- the wrapper is its entry point. Exactly the same class
# of path as a role's statically imported stage files above, and absent for
# exactly the same reason: the list was stated as `<name>.sh` when a contract was
# one file, and stayed stated when it stopped being one.
#
# The failure this prevents is not a missing-file crash, which would be loud. It
# is a reader whose subjects are assembled by a glob over tests/contracts/, which
# inside a sandbox holding only wrappers quietly has nothing to read.
# policy_integration_test.rb requires every contract that runs a play of its own
# to derive its project from the exported sandbox namespace; audiobookshelf is
# the only contract that runs one, and when #147 moved that play into
# audiobookshelf-runtime.rb the glob went from one subject to none. That check
# carries its own "polices nothing" tripwire and so failed loudly -- every
# expect_success row at once, on an unmutated tree. A reader without such a
# tripwire would simply have stopped policing.
#
# Enumerated from the contract rather than stated, the way static_task_files is,
# and by the same rule tests/run_contracts.rb:203 uses to find them: a
# tests/contracts/*.rb path named anywhere in the wrapper except a commented-out
# line. A stated list would have to be extended by every future extraction, which
# is the mistake being fixed here rather than repeated.
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
    role_root = File.join("roles", role)
    paths << File.join(role_root, "meta", "argument_specs.yml")
    # main.yml and everything it statically imports, because that whole set is
    # the role's body rather than its entry point. A role that is one stage per
    # file reaches its stages through import_tasks, so a sandbox holding only
    # main.yml hands every reader that assembles the role an index of imports
    # instead of the role -- and that is silent rather than loud wherever the
    # reader's property is an OR or a nil-guard. audiobookshelf has been one
    # stage per file since #238, and inside this fixture role_has_verification?
    # answered false for it ever since, with policy_test.rb's verification
    # property carried by the contract half of its OR and nobody told.
    paths.concat(static_task_files(root, role_root))
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
    paths.concat(contract_program_files(root, expected_path))
  end

  # tests/policy_ci_test.rb requires a static foundation contract beside every
  # planned acquisition lane. Those scripts are not registry contracts -- the
  # registry only carries services that are built -- so name them from the same
  # two sources the policy reads: the catalog says which projects are acquisition
  # lanes, the manifest says which of them are still planned. Without them every
  # mutation would fail on the absent contract rather than on the mutation.
  acquisition_catalog = YAML.safe_load_file(File.join(root, "config", "media-acquisition.yml"))
  acquisition_catalog.fetch("projects").each_key do |project|
    next unless statuses[project] == "planned"

    paths << File.join("tests", "contracts", "#{project}-foundation.sh")
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

# Every policy script the suite is split across, keyed by the short name a
# mutation row names it with. A row declares the scripts that actually detect its
# defect (`detected_by:`) instead of running all eight, because seven of them
# cannot produce the message it asserts and the harness builds a sandbox per row.
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

# `--audit` re-derives every row's detecting set by running the whole policy set
# against it, and reports each call site whose declared set disagrees. It is the
# answer to the one thing narrowing cannot fail loudly on: a check added to a
# script a row no longer runs stops covering that row, and nothing else would say
# so. Deliberately not in CI -- it is exactly the eightfold cost narrowing removed.
POLICY_AUDIT = ARGV.include?("--audit")

# Keyed by call site rather than by label, because a call site inside a loop is
# one declaration covering several mutations and only their union has to match
# it. Labels cannot key this: several rows share one, and some are interpolated.
#
# The key assumes one declared set per call site, which is what every loop here
# does -- it passes the same `detected_by` on each iteration. A loop that
# computed a different set per iteration would record only the first, so give it
# its own call site rather than teaching this to merge declarations.
POLICY_AUDIT_SITES = {}

def resolve_policy_scripts(names, label)
  raise "#{label}: detected_by must be a nonempty list of script names" if names.nil? || names.empty?

  names.map do |name|
    POLICY_SCRIPTS_BY_NAME.fetch(name) do
      raise "#{label}: unknown policy script #{name.inspect}; " \
            "known names are #{POLICY_SCRIPTS_BY_NAME.keys.join(', ')}"
    end
  end
end

# Runs the named scripts against one mutated sandbox and reports each one's
# output and exit status separately.
#
# The scripts run concurrently. Every one of them only reads the sandbox, and
# each is a subprocess that releases the GVL, so this is the same parallelism
# tests/validate-policy.sh applies to the checks themselves. Serially it was the
# policy gate's floor: this harness builds a sandbox per mutation and there are
# over a hundred of them, so a second spent here is spent a hundred times.
#
# Results are collected by index rather than appended as they finish, so the
# output a caller matches against stays in the caller's order and a failure
# report does not depend on which script happened to exit first.
def run_policy_scripts(scripts)
  Dir.mktmpdir("nas-platform-policy-") do |sandbox|
    copy_fixture(ROOT, sandbox)
    initialize_fixture_index(sandbox)
    yield sandbox
    scripts.map do |script|
      Thread.new do
        stdout, stderr, status = capture3_without_git_routing(RbConfig.ruby, script, chdir: sandbox)
        [script, stdout + stderr, status.success?]
      end
    end.map(&:value)
  end
end

def run_policy(scripts = POLICY_SCRIPTS, &mutation)
  results = run_policy_scripts(scripts, &mutation)
  output = results.map { |_script, script_output, _ok| script_output }.join
  [output, results.all? { |_script, _script_output, ok| ok }]
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

# `detected_by` is the set of policy scripts that actually reject this mutation,
# and it is required rather than defaulted: a default would let the next row
# added quietly go back to running all eight, with nothing reporting it.
#
# Getting it wrong in the narrowing direction is fail-closed -- drop the script
# that owns the diagnostic and the row's own assertions fail by name. Getting it
# wrong in the other direction, by listing fewer scripts than really detect the
# defect, costs coverage that no assertion here can see, which is what `--audit`
# exists to find.
def expect_failure(failures, label, message, detected_by:)
  scripts = resolve_policy_scripts(detected_by, label)
  scripts = POLICY_SCRIPTS if POLICY_AUDIT
  results = run_policy_scripts(scripts) { |root| yield root }
  record_audit_detection(label, message, detected_by, results, caller_locations(1, 1).first) if POLICY_AUDIT

  output = results.map { |_script, script_output, _ok| script_output }.join
  failures << "#{label}: policy unexpectedly passed" if results.all? { |_s, _o, ok| ok }
  failures << "#{label}: missing failure message #{message.inspect}" unless output.include?(message)
  failures << "#{label}: emitted a Ruby stack trace" if output.match?(/\.rb:\d+:in [`']/)
end

# A script detects a mutation if it rejects it, names it, or crashes on it --
# all three are properties the row asserts, so all three keep a script listed.
def detecting_script_names(message, results)
  results.filter_map do |script, output, ok|
    detected = !ok || output.include?(message) || output.match?(/\.rb:\d+:in [`']/)
    POLICY_SCRIPTS_BY_NAME.key(script) if detected
  end
end

def record_audit_detection(label, message, declared, results, site)
  entry = POLICY_AUDIT_SITES[site.lineno] ||= { declared: declared, actual: [], label: label }
  entry[:actual] |= detecting_script_names(message, results)
end

# Both directions are silent without this. A script that starts detecting a row
# is coverage the row has stopped running; one that stops detecting it is a stale
# entry paying for a subprocess that proves nothing.
def audit_policy_detection(failures)
  return unless POLICY_AUDIT

  POLICY_AUDIT_SITES.each do |lineno, entry|
    missing = entry[:actual] - entry[:declared]
    stale = entry[:declared] - entry[:actual]
    where = "line #{lineno} (#{entry[:label]})"
    failures << "#{where}: detected_by omits #{missing.join(', ')}" if missing.any?
    failures << "#{where}: detected_by names #{stale.join(', ')}, which no longer detect it" if stale.any?
  end
  puts "policy mutation audit: #{POLICY_AUDIT_SITES.length} call sites re-derived against all eight scripts"
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

  storage_path = File.join(root, "inventory", "group_vars", "all", "main.yml")
  storage = YAML.safe_load_file(storage_path)
  storage.fetch("nas_storage") << {
    "path" => "{{ nas_docker_root }}/paperless-ngx/data",
    "mode" => "0755",
    "recovery" => "critical"
  }
  File.write(storage_path, YAML.dump(storage))
end
