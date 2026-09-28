#!/usr/bin/env ruby
# frozen_string_literal: true

# Behaviour of the Audiobookshelf contract's static and runtime programs, in three
# layers: static rows, runtime modes needing no vault/container/network, and the
# wrapper. --self-test plants a regression per guard and proves a row catches it.

require "fileutils"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"
require "yaml"

require_relative "case_pool_support"
require_relative "policy_support"
require_relative "contract_test_support"

include TestScaffold
include ContractTestSupport

ROOT = File.expand_path("..", __dir__)
DIAGNOSTIC_PREFIX = "Audiobookshelf contract failed: "
CONTRACT = File.join(ROOT, "tests", "contracts", "audiobookshelf.sh")
STATIC_PROGRAM = File.join(ROOT, "tests", "contracts", "audiobookshelf-static.rb")
RUNTIME_PROGRAM = File.join(ROOT, "tests", "contracts", "audiobookshelf-runtime.rb")

# The `-ryaml` preload the wrapper carries; the static program does not require yaml.
STATIC_COMMAND = [RbConfig.ruby, "-ryaml"].freeze

# Exactly what the two halves read from the inspected tree.
FIXTURE_FILES = %w[
  roles/audiobookshelf/tasks/main.yml
  roles/audiobookshelf/tasks/deploy.yml
  roles/audiobookshelf/tasks/bootstrap.yml
  roles/audiobookshelf/tasks/settings.yml
  roles/audiobookshelf/tasks/managed_users.yml
  roles/audiobookshelf/tasks/administrator.yml
  roles/audiobookshelf/tasks/library.yml
  roles/audiobookshelf/tasks/initial_scan.yml
  roles/audiobookshelf/tasks/verify.yml
  roles/audiobookshelf/defaults/main.yml
  roles/audiobookshelf/meta/argument_specs.yml
  roles/audiobookshelf/templates/env.j2
  roles/managed_users/tasks/main.yml
  services/audiobookshelf/compose.yml
  services/audiobookshelf/compose.mac.yml
  inventory/group_vars/all/service_audiobookshelf.yml
  tests/integration.sh
  tests/integration_controller.sh
  tests/generate-ephemeral-vault.sh
  tests/policy_support.rb
  tests/contracts/audiobookshelf-runtime.rb
].freeze

# Deliberately absent: the wrapper and the static program. Carrying them would
# shadow #251 (a sibling resolved from $repo_dir).

STATIC_ARGUMENTS = %w[
  services/audiobookshelf/compose.yml
  services/audiobookshelf/compose.mac.yml
  roles/audiobookshelf/tasks/main.yml
  roles/audiobookshelf/defaults/main.yml
  roles/audiobookshelf/meta/argument_specs.yml
  roles/audiobookshelf/templates/env.j2
  tests/integration_controller.sh
  inventory/group_vars/all/service_audiobookshelf.yml
  tests/contracts/audiobookshelf-runtime.rb
].freeze


def build_fixture_repository(root)
  FIXTURE_FILES.each do |relative|
    destination = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.cp(File.join(ROOT, relative), destination)
    File.chmod(relative.end_with?(".sh") ? 0o755 : 0o644, destination)
  end
end

def edit_yaml(root, relative, aliases: true)
  path = File.join(root, relative)
  document = YAML.safe_load_file(path, aliases: aliases)
  yield document
  File.write(path, YAML.dump(document))
end

def edit_text(root, relative)
  path = File.join(root, relative)
  File.write(path, yield(File.read(path)))
end

def compose_service(root, relative = "services/audiobookshelf/compose.yml")
  edit_yaml(root, relative) { |document| yield document.fetch("services").fetch("audiobookshelf") }
end

ROLE_STAGES = FIXTURE_FILES.grep(%r{\Aroles/audiobookshelf/tasks/}).freeze

# Finds a task by name anywhere in the role, so a row survives stage splits.
def edit_role_task(root, name)
  ROLE_STAGES.each do |relative|
    path = File.join(root, relative)
    document = YAML.safe_load_file(path, aliases: false)
    next unless document.is_a?(Array)

    found = find_task(document, name)
    next unless found

    yield found
    File.write(path, YAML.dump(document))
    return relative
  end
  raise "fixture has no task named #{name.inspect} anywhere in the role"
end

def find_task(tasks, name)
  Array(tasks).each do |task|
    next unless task.is_a?(Hash)
    return task if task["name"] == name

    %w[block rescue always].each do |section|
      nested = find_task(task[section], name)
      return nested if nested
    end
  end
  nil
end

# --- static layer ----------------------------------------------------------
# One row per assertion family rather than per abort site.

STATIC_ROWS = [
  { name: "an intact repository", break: ->(_root) {}, expects: nil },
  {
    name: "the container running as something other than the NAS identity",
    break: ->(root) { compose_service(root) { |spec| spec["user"] = "0:0" } },
    expects: "platform identity differs"
  },
  {
    name: "the application port renumbered",
    break: ->(root) { compose_service(root) { |spec| spec["ports"] = ["13379:80"] } },
    expects: "NAS port differs"
  },
  {
    name: "the read-only media mount made writable",
    break: lambda { |root|
      compose_service(root) do |spec|
        spec["volumes"] = spec.fetch("volumes").map { |volume| volume.sub(":/audiobooks:ro", ":/audiobooks") }
      end
    },
    expects: "storage contract differs"
  },
  {
    name: "the shared media control network dropped",
    break: ->(root) { compose_service(root) { |spec| spec["networks"] = ["default"] } },
    expects: "media control network membership differs"
  },
  {
    name: "the health check retried fewer times",
    break: ->(root) { compose_service(root) { |spec| spec.fetch("healthcheck")["retries"] = 1 } },
    expects: "legacy health check differs"
  },
  {
    name: "a restart policy that is not unless-stopped",
    break: ->(root) { compose_service(root) { |spec| spec["restart"] = "always" } },
    expects: "restart policy differs"
  },
  {
    name: "a logging policy without a rotation bound",
    break: ->(root) { compose_service(root) { |spec| spec.fetch("logging").fetch("options").delete("max-file") } },
    expects: "logging policy differs"
  },
  {
    name: "the Mac override pinning an image",
    break: lambda { |root|
      compose_service(root, "services/audiobookshelf/compose.mac.yml") do |spec|
        spec["image"] = "audiobookshelf:local"
      end
    },
    expects: "Mac override differs"
  },
  {
    name: "the managed library rooted somewhere other than /audiobooks",
    break: lambda { |root|
      edit_yaml(root, "roles/audiobookshelf/defaults/main.yml", aliases: false) do |document|
        document["audiobookshelf_library_folders"] = [{ "path" => "/media" }]
      end
    },
    expects: "managed library must be rooted at /audiobooks"
  },
  {
    name: "an owned server setting changed",
    break: lambda { |root|
      edit_yaml(root, "roles/audiobookshelf/defaults/main.yml", aliases: false) do |document|
        document.fetch("audiobookshelf_owned_server_settings")["chromecastEnabled"] = false
      end
    },
    expects: "owned server settings differ"
  },
  {
    name: "the backup retention shortened",
    break: lambda { |root|
      edit_yaml(root, "roles/audiobookshelf/defaults/main.yml", aliases: false) do |document|
        document["audiobookshelf_backup_retention"] = 1
      end
    },
    expects: "backup policy defaults differ"
  },
  {
    name: "the backup path assignment surviving only as a comment",
    break: lambda { |root|
      edit_text(root, "roles/audiobookshelf/templates/env.j2") do |source|
        source.sub(/^AUDIOBOOKSHELF_BACKUP_PATH=/, "# AUDIOBOOKSHELF_BACKUP_PATH=")
      end
    },
    expects: "backup environment is absent"
  },
  {
    name: "the media network assignment pointing at a literal",
    break: lambda { |root|
      edit_text(root, "roles/audiobookshelf/templates/env.j2") do |source|
        source.sub(/^PLATFORM_MEDIA_NETWORK=.*$/, "PLATFORM_MEDIA_NETWORK=media-control")
      end
    },
    expects: "media network environment is absent"
  },
  {
    name: "the backup directory declared with the wrong recovery class",
    break: lambda { |root|
      edit_yaml(root, "inventory/group_vars/all/service_audiobookshelf.yml") do |document|
        entry = document.fetch("nas_storage_audiobookshelf").find do |candidate|
          candidate["path"] == "{{ nas_docker_root }}/audiobookshelf/backups"
        end
        entry["recovery"] = "cache"
      end
    },
    expects: "backup storage inventory differs"
  },
  {
    name: "the backup retention argument untyped",
    break: lambda { |root|
      edit_yaml(root, "roles/audiobookshelf/meta/argument_specs.yml") do |document|
        document.dig("argument_specs", "main", "options", "audiobookshelf_backup_retention")["type"] = "str"
      end
    },
    expects: "server settings argument validation is absent"
  },
  {
    name: "the backup path resolved after the environment is rendered",
    break: ->(root) { edit_role_task(root, "Resolve the effective Audiobookshelf backup directory") { |task| task["name"] = "Renamed" } },
    expects: "backup path is not resolved and validated before mutation"
  },
  {
    name: "the service role reclaiming host_prep's backup directory",
    break: lambda { |root|
      path = File.join(root, "roles/audiobookshelf/tasks/deploy.yml")
      document = YAML.safe_load_file(path, aliases: false)
      document << {
        "name" => "Own the Audiobookshelf backup directory",
        "ansible.builtin.file" => {
          "path" => "{{ audiobookshelf_effective_backup_host_path }}", "state" => "directory"
        }
      }
      File.write(path, YAML.dump(document))
    },
    expects: "service role duplicates host_prep backup ownership"
  },
  {
    name: "a required refusal surviving only as a comment",
    break: ->(root) { edit_role_task(root, "Refuse duplicate managed Audiobookshelf administrators") { |task| task["name"] = "Renamed" } },
    expects: "missing Refuse duplicate managed Audiobookshelf administrators"
  },
  {
    name: "an unsupported GET of the settings endpoint",
    break: lambda { |root|
      edit_role_task(root, "Reconcile owned Audiobookshelf server settings") do |task|
        task.fetch("ansible.builtin.uri")["method"] = "GET"
      end
    },
    expects: "unsupported GET /api/settings is assumed"
  },
  {
    # #753: the schema gate must read the version from the pin, not a literal.
    name: "the settings schema gate pinned to a literal version",
    break: lambda { |root|
      edit_role_task(root, "Validate current Audiobookshelf server settings schema") do |task|
        assertion = task.fetch("ansible.builtin.assert")
        assertion["that"] = Array(assertion["that"]).map do |condition|
          condition.to_s.sub("== audiobookshelf_pinned_version", "== '2.36.0'")
        end
      end
    },
    expects: "running server version is not compared against the pinned image"
  },
  {
    name: "an unparseable pin accepted by the settings schema gate",
    break: lambda { |root|
      edit_role_task(root, "Validate current Audiobookshelf server settings schema") do |task|
        assertion = task.fetch("ansible.builtin.assert")
        assertion["that"] = Array(assertion["that"]).reject { |condition| condition.to_s.include?("| length > 0") }
      end
    },
    expects: "running server version is not compared against the pinned image"
  },
  {
    name: "backupPath sent through the settings PATCH that drops it",
    break: lambda { |root|
      edit_role_task(root, "Reconcile owned Audiobookshelf server settings") do |task|
        task.fetch("ansible.builtin.uri")["body"] = "{{ audiobookshelf_desired_server_settings }}"
      end
    },
    expects: "backupPath is sent where Audiobookshelf drops it"
  },
  {
    name: "an authoritative settings read that logs its own response",
    break: lambda { |root|
      edit_role_task(root, "Read Audiobookshelf server settings for reconciliation") do |task|
        task["no_log"] = false
      end
    },
    expects: "authoritative settings reads must re-authorize"
  },
  {
    name: "an unconditional settings PATCH",
    break: lambda { |root|
      edit_role_task(root, "Reconcile owned Audiobookshelf server settings") { |task| task["when"] = [] }
    },
    expects: "settings mutation must be one conditional partial PATCH"
  },
  {
    name: "the authoritative timezone no longer checked on every read",
    break: lambda { |root|
      edit_role_task(root, "Require exact owned Audiobookshelf server settings after reconciliation") do |task|
        assertion = task.fetch("ansible.builtin.assert")
        assertion["that"] = Array(assertion["that"]).reject { |condition| condition.to_s.include?("timeZone") }
      end
    },
    expects: "authoritative timezone is not checked on every settings read"
  },
  {
    name: "a non-persisted timezone added to the owned settings",
    break: lambda { |root|
      edit_yaml(root, "roles/audiobookshelf/defaults/main.yml", aliases: false) do |document|
        document.fetch("audiobookshelf_owned_server_settings")["timeZone"] = "Europe/Berlin"
      end
    },
    # The equality check refuses before the PATCH-body assertion is reached.
    expects: "owned server settings differ"
  },
  {
    name: "an inactive-administrator reactivation claimed by the role",
    break: lambda { |root|
      edit_role_task(root, "Repair the managed Audiobookshelf administrator") do |task|
        task["when"] = "not audiobookshelf_existing_admin.isActive | bool"
      end
    },
    expects: "role still claims inactive administrator repair"
  },
  {
    name: "an integration marker that stopped being asserted",
    break: lambda { |root|
      edit_text(root, "tests/integration_controller.sh") do |source|
        source.gsub("AUDIOBOOKSHELF_DRIFT_REPAIRED", "ABSENT_DERIAPER_TFIRD_FLEHSKOOBOIDUA")
      end
    },
    expects: "integration is missing AUDIOBOOKSHELF_DRIFT_REPAIRED"
  },
  {
    name: "a drift commit that consumes its own reconciliation evidence",
    break: lambda { |root|
      edit_text(root, "tests/contracts/audiobookshelf-runtime.rb") do |source|
        source.sub(/(when "drift-commit"\n)/) { "#{Regexp.last_match(1)}  remove_drift_snapshot if false\n" }
      end
    },
    expects: "drift commit consumes reconciliation evidence"
  },
  {
    name: "the runtime half absent from the tree under inspection",
    break: ->(root) { FileUtils.rm(File.join(root, "tests/contracts/audiobookshelf-runtime.rb")) },
    expects: nil,
    # A crash rather than a diagnostic: the drift-commit read has no existence guard.
    expects_crash: ["audiobookshelf-runtime.rb", "No such file or directory"]
  },
  {
    name: "a role-shape defect under a non-static mode",
    mode: "run",
    break: ->(root) { edit_role_task(root, "Refuse duplicate managed Audiobookshelf administrators") { |task| task["name"] = "Renamed" } },
    expects: nil
  },
  {
    name: "a compose defect under a non-static mode",
    mode: "run",
    break: ->(root) { compose_service(root) { |spec| spec["restart"] = "always" } },
    expects: "restart policy differs"
  }
].freeze

def static_failures(program = STATIC_PROGRAM, rows = STATIC_ROWS)
  in_parallel_case_results(rows) do |row|
    Dir.mktmpdir("nas-platform-audiobookshelf-static.") do |raw|
      root = File.realpath(raw)
      build_fixture_repository(root)
      row.fetch(:break).call(root)
      arguments = STATIC_ARGUMENTS.map { |relative| File.join(root, relative) }
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => root },
        *STATIC_COMMAND, program, *arguments, row.fetch(:mode, "static")
      )
      judge("static: #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr, status,
            prefix: DIAGNOSTIC_PREFIX, expects_crash: row[:expects_crash])
    end
  end
end

# --- runtime layer ---------------------------------------------------------

RUNTIME_ROWS = [
  {
    name: "the audio fixture and diagnostic self-test",
    mode: "audio-self-test",
    break: ->(_root) {},
    expects: nil,
    reports: "Audiobookshelf audio and diagnostic self-test passed"
  },
  {
    name: "the diagnostic secret redaction self-test",
    mode: "secret-redaction-self-test",
    break: ->(_root) {},
    expects: nil,
    reports: "Audiobookshelf diagnostic secret redaction self-test passed"
  },
  {
    name: "the administrator selection self-test",
    mode: "administrator-selection-self-test",
    break: ->(_root) {},
    expects: nil,
    reports: "Audiobookshelf administrator selection self-test passed"
  },
  {
    name: "the drift snapshot recovery self-test",
    mode: "drift-recovery-self-test",
    break: ->(_root) {},
    expects: nil,
    reports: "Audiobookshelf exact drift snapshot recovery self-test passed"
  },
  {
    name: "the media pre-seed",
    mode: "seed-fixture-only",
    break: ->(_root) {},
    expects: nil,
    reports: "Audiobookshelf media fixture prepared before deployment"
  },
  {
    name: "the authentication budget self-test",
    mode: "authentication-budget-self-test",
    break: ->(_root) {},
    expects: nil,
    reports: "Audiobookshelf authentication budget self-test passed"
  },
  {
    name: "a contract mode dropped from the integration lane",
    mode: "authentication-budget-self-test",
    break: lambda { |root|
      edit_text(root, "tests/integration_controller.sh") do |source|
        source.sub(/^(\s*)run_audiobookshelf_contract seed-progress/, '\1run_audiobookshelf_contract run')
      end
    },
    expects: "Audiobookshelf integration contract call sequence differs"
  },
  {
    name: "an extra role run in the integration lane",
    mode: "authentication-budget-self-test",
    break: lambda { |root|
      edit_text(root, "tests/integration_controller.sh") do |source|
        source.sub(/^(\s*)(run_play --tags audiobookshelf\n)/) { "#{$1}#{$2}#{$1}#{$2}" }
      end
    },
    expects: "Audiobookshelf integration role call sequence differs"
  },
  {
    name: "the integration lane losing its cleanup trap",
    mode: "authentication-budget-self-test",
    break: lambda { |root|
      edit_text(root, "tests/integration.sh") do |source|
        source.sub("trap cleanup_integration_on_exit EXIT", "trap - EXIT")
      end
    },
    expects: "Audiobookshelf integration session cleanup lifecycle differs"
  },
  {
    name: "a runtime half with no direct authentication of its own",
    mode: "authentication-budget-self-test",
    break: lambda { |root|
      edit_text(root, "tests/contracts/audiobookshelf-runtime.rb") do |source|
        source.gsub(/request\(\s*"post",\s*"\/login"/, 'request("post", "/session"')
      end
    },
    expects: "Audiobookshelf direct authentication proof is absent"
  },
  {
    # The counted logins are roles/managed_users' generic request (#647).
    name: "a managed-user shim whose login path is no longer /login",
    mode: "authentication-budget-self-test",
    break: lambda { |root|
      edit_yaml(root, "roles/audiobookshelf/defaults/main.yml") do |document|
        document["audiobookshelf_managed_users_authenticate_path"] = "api/login"
      end
    },
    expects: "Audiobookshelf managed-user shim does not bind the shared login"
  },
  {
    name: "a managed-user shim that binds authenticated identities",
    mode: "authentication-budget-self-test",
    break: lambda { |root|
      edit_yaml(root, "roles/audiobookshelf/tasks/managed_users.yml") do |document|
        document.find { |task| task.key?("ansible.builtin.include_role") }
                .fetch("vars")["managed_users_bind_authenticated_ids"] = true
      end
    },
    expects: "Audiobookshelf managed-user shim binds authenticated identities"
  },
  {
    name: "a shared managed-user role whose login request was renamed",
    mode: "authentication-budget-self-test",
    break: lambda { |root|
      edit_text(root, "roles/managed_users/tasks/main.yml") do |source|
        source.sub('"Authenticate existing managed users: {{ managed_users_title }}"',
                   '"Probe existing managed users: {{ managed_users_title }}"')
      end
    },
    expects: "Audiobookshelf managed-user authentication task model differs"
  },
  {
    name: "a report root that is a symlink",
    mode: "drift-recovery-self-test",
    break: ->(_root) {},
    symlink_report_root: true,
    expects: "report root is unavailable or unsafe"
  }
].freeze

def runtime_sandbox(root)
  media = File.join(root, "media")
  reports = File.join(root, "reports")
  FileUtils.mkdir_p(media)
  FileUtils.mkdir_p(reports)
  File.chmod(0o700, reports)
  [media, reports]
end

def runtime_failures(program = RUNTIME_PROGRAM, rows = RUNTIME_ROWS)
  in_parallel_case_results(rows) do |row|
    Dir.mktmpdir("nas-platform-audiobookshelf-runtime.") do |raw|
      root = File.realpath(raw)
      build_fixture_repository(root)
      row.fetch(:break).call(root)
      media, reports = runtime_sandbox(root)
      if row[:symlink_report_root]
        elsewhere = File.join(root, "elsewhere")
        FileUtils.mkdir_p(elsewhere)
        File.chmod(0o700, elsewhere)
        FileUtils.rmdir(reports)
        File.symlink(elsewhere, reports)
      end
      stdout, stderr, status = Open3.capture3(
        {
          "PLATFORM_CONTRACT_REPO_DIR" => root, "PLATFORM_REPO_ROOT" => root,
          "PLATFORM_MEDIA_ROOT" => media, "PLATFORM_REPORT_ROOT" => reports,
          "PLATFORM_AUDIOBOOKSHELF_PORT" => "13378"
        },
        RbConfig.ruby, program, row.fetch(:mode)
      )
      failures = judge("runtime: #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr, status,
                       prefix: DIAGNOSTIC_PREFIX)
      if failures.empty? && row[:reports] && !stdout.include?(row.fetch(:reports))
        failures << "runtime: #{row.fetch(:name)}: did not report " \
                    "#{row.fetch(:reports).inspect}, got #{stdout.strip.inspect}"
      end
      failures
    end
  end
end

# --- wrapper layer ---------------------------------------------------------
# The wrapper resolves both programs from its own checkout, so a copy of the three
# files is a working contract that can be pointed at a broken fixture.

def with_contract_copy(static: File.read(STATIC_PROGRAM), runtime: File.read(RUNTIME_PROGRAM),
                       wrapper: File.read(CONTRACT), &block)
  with_contract_sandbox("audiobookshelf", wrapper, { "static" => static, "runtime" => runtime }, &block)
end

def broken_fixture_repository
  Dir.mktmpdir("nas-platform-audiobookshelf-broken.") do |raw|
    root = File.realpath(raw)
    build_fixture_repository(root)
    compose_service(root) { |spec| spec["restart"] = "always" }
    yield root
  end
end

REQUIRED_RUN_ENV = %w[
  PLATFORM_MEDIA_ROOT
  PLATFORM_REPORT_ROOT
].freeze

def wrapper_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(wrapper: wrapper_source) do |contract, copy_root|
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => ROOT }, contract, "static"
    )
    failures << "wrapper: static mode failed: #{(stdout + stderr).strip}" unless status.success?
    failures << "wrapper: static mode did not report the property it proved" unless
      stdout.include?("Audiobookshelf static contract passed")

    {
      "roles/audiobookshelf/tasks/main.yml" => "roles/audiobookshelf/tasks/main.yml is absent",
      "roles/audiobookshelf/defaults/main.yml" => "roles/audiobookshelf/defaults/main.yml is absent",
      "services/audiobookshelf/compose.yml" => "services/audiobookshelf/compose.yml is absent",
      "services/audiobookshelf/compose.mac.yml" => "services/audiobookshelf/compose.mac.yml is absent",
      "roles/audiobookshelf/meta/argument_specs.yml" => "roles/audiobookshelf/meta/argument_specs.yml is absent",
      "roles/audiobookshelf/templates/env.j2" => "roles/audiobookshelf/templates/env.j2 is absent"
    }.each do |relative, diagnostic|
      Dir.mktmpdir("nas-platform-audiobookshelf-preflight.") do |raw|
        incomplete = File.realpath(raw)
        build_fixture_repository(incomplete)
        FileUtils.rm(File.join(incomplete, relative))
        stdout, stderr, status = Open3.capture3(
          { "PLATFORM_CONTRACT_REPO_DIR" => incomplete }, contract, "static"
        )
        failures << "wrapper: a repository without #{relative} was accepted" if status.success?
        failures << "wrapper: a repository without #{relative} was refused without its diagnostic: " \
                    "#{(stdout + stderr).strip.inspect}" unless
          (stdout + stderr).include?("Audiobookshelf contract failed: #{diagnostic}")
      end
    end

    broken_fixture_repository do |broken|
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => broken }, contract, "static"
      )
      failures << "wrapper: static mode passed against a broken repository" if status.success?
      failures << "wrapper: static mode did not report the broken repository" unless
        (stdout + stderr).include?("restart policy differs")
    end

    compose_service(copy_root) { |spec| spec["restart"] = "always" }
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => ROOT }, contract, "static"
    )
    failures << "wrapper: a broken checkout was read instead of the named tree: " \
                "#{(stdout + stderr).strip}" unless status.success?
  end

  # The default branch (no PLATFORM_CONTRACT_REPO_DIR) is the only production path.
  with_contract_copy(wrapper: wrapper_source) do |contract, copy_root|
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => nil }, contract, "static"
    )
    failures << "wrapper: static mode failed with no repository named: #{(stdout + stderr).strip}" unless
      status.success?
    failures << "wrapper: static mode did not report the property it proved" unless
      stdout.include?("Audiobookshelf static contract passed")

    compose_service(copy_root) { |spec| spec["restart"] = "always" }
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => nil }, contract, "static"
    )
    failures << "wrapper: with no repository named, static mode inspected some other tree" if
      status.success?
    failures << "wrapper: with no repository named, static mode did not report the broken tree" unless
      (stdout + stderr).include?("restart policy differs")
  end

  # PLATFORM_REPO_ROOT and PLATFORM_CONTRACT_REPO_DIR must reach the runtime half
  # bound to the inspected tree; break each tree in turn to tell them apart.
  with_contract_copy(wrapper: wrapper_source) do |contract, copy_root|
    media, reports = runtime_sandbox(copy_root)
    sandbox = { "PLATFORM_MEDIA_ROOT" => media, "PLATFORM_REPORT_ROOT" => reports }
    edit_text(copy_root, "tests/integration.sh") do |source|
      source.sub("trap cleanup_integration_on_exit EXIT", "trap - EXIT")
    end

    Dir.mktmpdir("nas-platform-audiobookshelf-inspected.") do |raw|
      inspected = File.realpath(raw)
      build_fixture_repository(inspected)
      stdout, stderr, status = Open3.capture3(
        sandbox.merge("PLATFORM_CONTRACT_REPO_DIR" => inspected),
        contract, "authentication-budget-self-test"
      )
      failures << "wrapper: the runtime half read its own checkout instead of the named tree: " \
                  "#{(stdout + stderr).strip}" unless status.success?
      failures << "wrapper: the runtime half did not report its own success line" unless
        stdout.include?("Audiobookshelf authentication budget self-test passed")

      edit_text(inspected, "tests/integration.sh") do |source|
        source.sub("trap cleanup_integration_on_exit EXIT", "trap - EXIT")
      end
      stdout, stderr, status = Open3.capture3(
        sandbox.merge("PLATFORM_CONTRACT_REPO_DIR" => inspected),
        contract, "authentication-budget-self-test"
      )
      failures << "wrapper: the runtime half accepted a broken inspected tree" if status.success?
      failures << "wrapper: the runtime half did not report the broken inspected tree: " \
                  "#{(stdout + stderr).strip.inspect}" unless
        (stdout + stderr).include?("Audiobookshelf integration session cleanup lifecycle differs")
    end
  end

  with_contract_copy(wrapper: wrapper_source) do |contract|
    Dir.mktmpdir("nas-platform-audiobookshelf-sentinel.") do |raw|
      inspected = File.realpath(raw)
      build_fixture_repository(inspected)
      %w[audiobookshelf-static.rb audiobookshelf-runtime.rb].each do |name|
        File.write(File.join(inspected, "tests", "contracts", name),
                   %(warn "IMPOSTOR #{name} ran"\nexit 3\n))
      end
      media, reports = runtime_sandbox(inspected)
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => inspected,
          "PLATFORM_MEDIA_ROOT" => media, "PLATFORM_REPORT_ROOT" => reports },
        contract, "audio-self-test"
      )
      output = stdout + stderr
      failures << "wrapper: a program was resolved from the inspected tree: #{output.strip.inspect}" if
        output.include?("IMPOSTOR")
      failures << "wrapper: the checkout's own programs did not run: #{output.strip.inspect}" unless
        status.success? && stdout.include?("Audiobookshelf audio and diagnostic self-test passed")
    end
  end

  with_contract_copy(wrapper: wrapper_source) do |contract|
    Dir.mktmpdir("nas-platform-audiobookshelf-source.") do |raw|
      inspected = File.realpath(raw)
      build_fixture_repository(inspected)
      edit_text(inspected, "tests/contracts/audiobookshelf-runtime.rb") do |source|
        source.sub(/(when "drift-commit"\n)/) { "#{Regexp.last_match(1)}  remove_drift_snapshot if false\n" }
      end
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => inspected }, contract, "static"
      )
      failures << "wrapper: the checkout's own runtime source was read instead of the named tree's" if
        status.success?
      failures << "wrapper: a poisoned inspected runtime source was refused without its diagnostic: " \
                  "#{(stdout + stderr).strip.inspect}" unless
        (stdout + stderr).include?("Audiobookshelf contract failed: drift commit consumes reconciliation evidence")
    end
  end

  with_contract_copy(wrapper: wrapper_source) do |contract|
    Dir.mktmpdir("nas-platform-audiobookshelf-nosupport.") do |raw|
      inspected = File.realpath(raw)
      build_fixture_repository(inspected)
      FileUtils.rm(File.join(inspected, "tests", "policy_support.rb"))
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => inspected }, contract, "static"
      )
      output = stdout + stderr
      failures << "wrapper: policy_support was loaded from the checkout, not the named tree" if
        status.success?
      failures << "wrapper: a tree without tests/policy_support.rb was refused without naming it: " \
                  "#{output.strip.inspect}" unless
        output.include?(File.join(inspected, "tests", "policy_support"))
    end
  end

  # Run-mode environment: each name set to "" (${VAR:?} refuses null) one at a
  # time; the wrapper's own message is asserted.
  with_contract_copy(wrapper: wrapper_source) do |contract, copy_root|
    full = { "PLATFORM_CONTRACT_REPO_DIR" => copy_root,
             "PLATFORM_MEDIA_ROOT" => copy_root, "PLATFORM_REPORT_ROOT" => copy_root,
             "PLATFORM_AUDIOBOOKSHELF_PORT" => "not-a-number" }
    REQUIRED_RUN_ENV.each do |name|
      stdout, stderr, status = Open3.capture3(full.merge(name => ""), contract, "run", chdir: copy_root)
      output = stdout + stderr
      failures << "run env: #{name} unset was accepted" if status.success?
      failures << "run env: #{name} unset was not refused with the wrapper's own message: " \
                  "#{output.strip.inspect}" unless output.include?("#{name} is required")
    end
  end
  failures
end

# Neither program reads stdin, so a probe program is the only way to observe the redirect.
def stdin_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(static: STDIN_PROBE, wrapper: wrapper_source) do |contract|
    failures.concat(stdin_probe_failures(contract, %w[static], { "PLATFORM_CONTRACT_REPO_DIR" => ROOT },
                                         subject: "the static program"))
  end

  # The runtime invocation is exec'ed, so its redirect needs its own row.
  with_contract_copy(runtime: STDIN_PROBE, wrapper: wrapper_source) do |contract, copy_root|
    media, reports = runtime_sandbox(copy_root)
    environment = { "PLATFORM_CONTRACT_REPO_DIR" => ROOT,
                    "PLATFORM_MEDIA_ROOT" => media, "PLATFORM_REPORT_ROOT" => reports }
    failures.concat(stdin_probe_failures(contract, %w[audio-self-test], environment,
                                         subject: "the runtime program", status: false))
  end
  failures
end

# --- planted regressions ---------------------------------------------------

PROGRAM_MUTATIONS = [
  {
    label: "the platform identity check",
    program: :static,
    from: 'service.fetch("user") == "${NAS_UID:?}:${NAS_GID:?}"',
    to: "true",
    rows: ["the container running as something other than the NAS identity"]
  },
  {
    label: "the read-only media mount check",
    program: :static,
    from: 'abort "Audiobookshelf contract failed: storage contract differs" unless service.fetch("volumes") == [',
    to: 'abort "Audiobookshelf contract failed: storage contract differs" unless [] == [] || service.fetch("volumes") == [',
    rows: ["the read-only media mount made writable"]
  },
  {
    label: "the media control network check",
    program: :static,
    from: 'service.fetch("networks") == %w[default media-control] && compose.fetch("networks") == {',
    to: "true || compose.fetch(\"networks\") == {",
    rows: ["the shared media control network dropped"]
  },
  {
    label: "the restart policy check",
    program: :static,
    from: 'service.fetch("restart") == "unless-stopped"',
    to: "true",
    rows: ["a restart policy that is not unless-stopped"]
  },
  {
    label: "the owned server settings check",
    program: :static,
    from: 'defaults.fetch("audiobookshelf_owned_server_settings") == expected_owned_settings',
    to: "true",
    rows: ["an owned server setting changed"]
  },
  {
    # The equality check is what refuses timeZone; without it the PATCH-body
    # assertion refuses with a different sentence, which is the regression.
    label: "the owned server settings check, behind the timezone assertion",
    program: :static,
    from: 'defaults.fetch("audiobookshelf_owned_server_settings") == expected_owned_settings',
    to: "true",
    rows: ["a non-persisted timezone added to the owned settings"],
    detects: "refused for the wrong reason"
  },
  {
    label: "the parsed environment assignment check",
    program: :static,
    from: 'environment_assignments.select { |name, _value| name == "AUDIOBOOKSHELF_BACKUP_PATH" } ==',
    to: 'true || environment_assignments.select { |name, _value| name == "AUDIOBOOKSHELF_BACKUP_PATH" } ==',
    rows: ["the backup path assignment surviving only as a comment"]
  },
  {
    label: "the backup storage inventory check",
    program: :static,
    from: "backup_storage == {",
    to: "true || backup_storage == {",
    rows: ["the backup directory declared with the wrong recovery class"]
  },
  {
    label: "the deployment-order check",
    program: :static,
    from: "resolve_backup_index && validate_target_index && render_index &&",
    to: "true ||",
    rows: ["the backup path resolved after the environment is rendered"]
  },
  {
    label: "the required-task sweep",
    program: :static,
    from: %q{abort "Audiobookshelf contract failed: missing #{name}" unless role_task_names.include?(name)},
    to: "nil unless true",
    rows: ["a required refusal surviving only as a comment"]
  },
  {
    label: "the conditional-PATCH check",
    program: :static,
    from: 'settings_patch.length == 1 && settings_patch.fetch(0).fetch(1)["method"] == "PATCH" &&',
    to: "true ||",
    rows: ["an unconditional settings PATCH"]
  },
  {
    label: "the pinned-version comparison check",
    program: :static,
    from: 'schema_conditions.any? { |condition| condition.end_with?(" or audiobookshelf_pinned_version | length > 0") } &&',
    to: "true ||",
    rows: [
      "the settings schema gate pinned to a literal version",
      "an unparseable pin accepted by the settings schema gate"
    ]
  },
  {
    label: "the backupPath route check",
    program: :static,
    from: %q{patch_body.include?("rejectattr('key', 'equalto', 'backupPath')") &&},
    to: "true ||",
    rows: ["backupPath sent through the settings PATCH that drops it"]
  },
  {
    label: "the timezone assertion count",
    program: :static,
    from: "timezone_assertions.length >= 3",
    to: "true",
    rows: ["the authoritative timezone no longer checked on every read"]
  },
  {
    label: "the inactive-administrator repair check",
    program: :static,
    from: 'role_strings(all_role_tasks).any? { |value| value.include?("audiobookshelf_existing_admin.isActive") } ||',
    to: "false &&",
    rows: ["an inactive-administrator reactivation claimed by the role"]
  },
  {
    label: "the integration marker sweep",
    program: :static,
    from: %q{abort "Audiobookshelf contract failed: integration is missing #{marker}" unless integration.include?(marker)},
    to: "nil unless true",
    rows: ["an integration marker that stopped being asserted"]
  },
  {
    label: "the drift-commit read pointed back at the wrapper",
    program: :static,
    from: "drift_commit_branch = File.read(contract_source_path)",
    to: 'drift_commit_branch = File.read(File.join(File.dirname(contract_source_path), "audiobookshelf.sh"))',
    rows: ["a drift commit that consumes its own reconciliation evidence"],
    detects: "refused for the wrong reason"
  },
  {
    label: "the mode guard around the role-shape sweep",
    program: :static,
    from: 'if mode == "static"',
    to: "if true",
    rows: ["a role-shape defect under a non-static mode"],
    detects: "expected success"
  },
  {
    label: "the integration contract call sequence check",
    program: :runtime,
    from: "fail_contract(\"Audiobookshelf integration contract call sequence differs\") unless contract_modes == expected_modes",
    to: "nil unless true",
    rows: ["a contract mode dropped from the integration lane"]
  },
  {
    label: "the integration role call sequence check",
    program: :runtime,
    from: "tagged_role_calls == 7 && check_role_calls == 2 && verify_role_calls == 4",
    to: "true",
    rows: ["an extra role run in the integration lane"]
  },
  {
    label: "the session cleanup lifecycle check",
    program: :runtime,
    from: 'controller.include?("run_audiobookshelf_contract authentication-session-cleanup") &&',
    to: "true ||",
    rows: ["the integration lane losing its cleanup trap"]
  },
  {
    label: "the direct-login count pointed back at the wrapper",
    program: :runtime,
    from: 'repo_root.join("tests/contracts/audiobookshelf-runtime.rb").read',
    to: 'repo_root.join("tests/contracts/audiobookshelf.sh").read',
    rows: ["the authentication budget self-test"],
    detects: "expected success"
  },
  {
    label: "the managed-user shim login binding check",
    program: :runtime,
    from: 'fail_contract("Audiobookshelf managed-user shim does not bind the shared login") unless',
    to: "nil unless true ||",
    rows: ["a managed-user shim whose login path is no longer /login"]
  },
  {
    label: "the managed-user shim identity-binding check",
    program: :runtime,
    from: 'fail_contract("Audiobookshelf managed-user shim binds authenticated identities") unless',
    to: "nil unless true ||",
    rows: ["a managed-user shim that binds authenticated identities"]
  },
  {
    label: "the managed-user authentication task model check",
    program: :runtime,
    from: 'fail_contract("Audiobookshelf managed-user authentication task model differs") unless',
    to: "nil unless true ||",
    rows: ["a shared managed-user role whose login request was renamed"]
  },
  {
    label: "the direct authentication proof",
    program: :runtime,
    from: 'fail_contract("Audiobookshelf direct authentication proof is absent") unless count.positive?',
    to: "nil unless true",
    rows: ["a runtime half with no direct authentication of its own"],
    detects: "accepted what it must refuse"
  },
  {
    label: "the report root safety check",
    program: :runtime,
    from: "REPORT_ROOT.directory? && !REPORT_ROOT.symlink?",
    to: "true",
    # The guard stands in four places; the plant removes all four (#393).
    occurrences: 4,
    rows: ["a report root that is a symlink"],
    detects: "accepted what it must refuse"
  }
].freeze

def with_mutant(mutation)
  canonical = mutation.fetch(:program) == :static ? STATIC_PROGRAM : RUNTIME_PROGRAM
  Dir.mktmpdir("nas-platform-audiobookshelf-mutant.") do |directory|
    path = File.join(directory, File.basename(canonical))
    File.write(path, plant(File.read(canonical), mutation))
    yield path
  end
end

if ARGV.include?("--self-test")
  in_parallel_case_results(PROGRAM_MUTATIONS) do |mutation|
    with_mutant(mutation) do |mutant|
      caught = if mutation.fetch(:program) == :static
                 static_failures(mutant, rows_named(STATIC_ROWS, mutation.fetch(:rows)))
               else
                 runtime_failures(mutant, rows_named(RUNTIME_ROWS, mutation.fetch(:rows)))
               end
      abort "self-test failed: removing #{mutation.fetch(:label)} was accepted" if caught.empty?
      detects = mutation.fetch(:detects, "accepted what it must refuse")
      unless caught.all? { |failure| failure.include?(detects) }
        abort "self-test failed: removing #{mutation.fetch(:label)} was caught by the wrong " \
              "assertion: #{caught.join(' | ')}"
      end
    end
    []
  end

  # Neither program reads stdin, so dropping `</dev/null` needs a program that does.
  planted_redirects = 0
  [
    ["  \"$runtime_source\" \"$mode\" </dev/null\n", "  \"$runtime_source\" \"$mode\"\n"],
    ["  \"$mode\" \"$@\" </dev/null\n", "  \"$mode\" \"$@\"\n"],
    ["\nexec ruby ", "\ncat >/dev/null\nexec ruby "]
  ].each do |from, to|
    unredirected = File.read(CONTRACT).sub(from, to)
    abort "self-test could not plant a dropped stdin redirect: #{from.inspect}" if
      unredirected == File.read(CONTRACT)

    leaked = stdin_failures(wrapper_source: unredirected)
    abort "self-test failed: a dropped stdin redirect was accepted" if leaked.empty?
    planted_redirects += 1
  end

  # #251 and #259: programs must resolve from the script's own checkout.
  planted_roots = 0
  [
    ['ruby -ryaml "$contract_repo_dir/tests/contracts/audiobookshelf-static.rb"',
     'ruby -ryaml "$repo_dir/tests/contracts/audiobookshelf-static.rb"'],
    ['exec ruby "$contract_repo_dir/tests/contracts/audiobookshelf-runtime.rb"',
     'exec ruby "$repo_dir/tests/contracts/audiobookshelf-runtime.rb"'],
    ["PLATFORM_CONTRACT_REPO_DIR=$repo_dir\n", "PLATFORM_CONTRACT_REPO_DIR=$contract_repo_dir\n"],
    ["PLATFORM_REPO_ROOT=$repo_dir\n", "PLATFORM_REPO_ROOT=$contract_repo_dir\n"],
    ["runtime_source=$repo_dir/tests/contracts/audiobookshelf-runtime.rb\n",
     "runtime_source=$contract_repo_dir/tests/contracts/audiobookshelf-runtime.rb\n"]
  ].each do |from, to|
    misrooted = File.read(CONTRACT).sub(from, to)
    abort "self-test could not plant a misrooted program: #{from.inspect}" if
      misrooted == File.read(CONTRACT)

    caught = wrapper_failures(wrapper_source: misrooted)
    abort "self-test failed: #{from.strip.inspect} rerooted to the wrong tree was accepted" if
      caught.empty?
    planted_roots += 1
  end

  planted_requirements = 0
  REQUIRED_RUN_ENV.each do |name|
    from = %(: "${#{name}:?#{name} is required}")
    pristine = File.read(CONTRACT)
    abort "self-test could not plant a weakened #{name}" unless pristine.scan(from).length == 1

    caught = wrapper_failures(wrapper_source: pristine.sub(from, %(: "${#{name}:=}")))
    abort "self-test failed: a weakened #{name} requirement was accepted" if caught.empty?
    abort "self-test failed: a weakened #{name} requirement was caught by the wrong " \
          "assertion: #{caught.join(' | ')}" unless caught.all? { |failure| failure.include?(name) }
    planted_requirements += 1
  end

  puts "audiobookshelf contract: self-test detects " \
       "#{PROGRAM_MUTATIONS.length + planted_redirects + planted_roots + planted_requirements} " \
       "planted regressions"
  exit
end

failures = static_failures + runtime_failures + wrapper_failures + stdin_failures
unless failures.empty?
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Audiobookshelf contract violation(s)"
end

puts "audiobookshelf contract: #{STATIC_ROWS.length} static and #{RUNTIME_ROWS.length} runtime " \
     "properties hold, and the wrapper reaches both programs with an empty stdin"
