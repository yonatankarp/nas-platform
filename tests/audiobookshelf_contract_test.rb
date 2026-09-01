#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Behaviour of the Audiobookshelf service contract's two Ruby programs.
#
# Until #147 both lived in `<<'RUBY'` heredocs inside
# tests/contracts/audiobookshelf.sh -- 1,485 of that file's 1,537 lines. `sh -n`
# reads a quoted heredoc as opaque text, so nothing but an integration lane with
# Docker, a converged Audiobookshelf and a real vault ever executed either one.
# tests/contracts/audiobookshelf-static.rb and
# tests/contracts/audiobookshelf-runtime.rb are files now, so both are reachable
# here.
#
# Three layers, because the contract has three kinds of property:
#
#   Static -- build a fixture repository out of the files the contract reads,
#   break exactly one thing in it, and require the program to name that thing.
#   The assertion text is the interface: a guard that fails for the wrong reason
#   has stopped guarding what it names, so every row pins the exact diagnostic.
#
#   Runtime -- the six modes that reach the runtime half's own code without a
#   vault, a container or a network: the audio fixture, diagnostic redaction,
#   administrator selection, the authentication budget, drift snapshot recovery
#   and the media pre-seed. They are what tests/contracts/audiobookshelf-audio-test.sh
#   and tests/mac/audiobookshelf-drift-hook-test.sh already drive, one process at
#   a time; here each is also driven against a broken inspected tree so its
#   refusals move one at a time. This layer deliberately stops before the vault
#   read at audiobookshelf-runtime.rb:781 -- everything past it needs a served
#   Audiobookshelf interface, and fixturing login, libraries, settings drift and
#   the check-mode lifecycle is a separate piece of work.
#
#   Wrapper -- tests/contracts/audiobookshelf.sh is what turns a mode into two
#   invocations. Its rows prove both programs are reached, that each is resolved
#   from the script's own checkout while the tree to inspect is passed in, and
#   that neither can consume the caller's stdin.
#
# Run with --self-test to plant a regression in each program and prove the rows
# above detect it.

require "etc"
require "fileutils"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
CONTRACT = File.join(ROOT, "tests", "contracts", "audiobookshelf.sh")
STATIC_PROGRAM = File.join(ROOT, "tests", "contracts", "audiobookshelf-static.rb")
RUNTIME_PROGRAM = File.join(ROOT, "tests", "contracts", "audiobookshelf-runtime.rb")

# The `-ryaml` preload tests/contracts/audiobookshelf.sh carries, because the
# static program does not require yaml itself. Every invocation of it here must
# carry the same preload or every row fails identically on an uninitialized
# constant, which would read as the extraction having broken everything.
STATIC_COMMAND = [RbConfig.ruby, "-ryaml"].freeze

# Exactly what the two halves read out of the tree they inspect. A fixture
# holding only these is the proof that the list is the list they actually need --
# audiobookshelf-runtime.rb included, because the static half reads the runtime
# half's drift-commit branch out of the inspected tree, and the runtime half
# counts its own direct logins the same way.
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
  services/audiobookshelf/compose.yml
  services/audiobookshelf/compose.mac.yml
  inventory/group_vars/all/main.yml
  tests/integration.sh
  tests/integration_controller.sh
  tests/generate-ephemeral-vault.sh
  tests/policy_support.rb
  tests/contracts/audiobookshelf-runtime.rb
].freeze

# Deliberately absent from that list: tests/contracts/audiobookshelf.sh and
# tests/contracts/audiobookshelf-static.rb. Neither program reads them out of the
# inspected tree, and a fixture that carried them would shadow the defect #251
# shipped -- a sibling resolved from $repo_dir finds a copy there and nothing
# looks wrong. audiobookshelf-runtime.rb is present because both halves really do
# read it from the tree they are inspecting.

# The arguments tests/contracts/audiobookshelf.sh passes the static half, in its
# order. Kept here rather than spelled out at each call site so a row cannot
# silently drift from the wrapper's own invocation.
STATIC_ARGUMENTS = %w[
  services/audiobookshelf/compose.yml
  services/audiobookshelf/compose.mac.yml
  roles/audiobookshelf/tasks/main.yml
  roles/audiobookshelf/defaults/main.yml
  roles/audiobookshelf/meta/argument_specs.yml
  roles/audiobookshelf/templates/env.j2
  tests/integration_controller.sh
  inventory/group_vars/all/main.yml
  tests/contracts/audiobookshelf-runtime.rb
].freeze

# Runs independent cases through a worker pool, capped at the core count. The
# same shape and the same reasoning as in_parallel_cases in
# tests/media_acquisition_reconciliation_support.rb: a check that spawns a
# subprocess per case, serially, becomes the floor for the whole policy gate, and
# oversubscribing a four-core CI runner trades wall time for contention. Never
# more workers than cores.
CASE_WORKER_LIMIT = Integer(
  ENV.fetch("AUDIOBOOKSHELF_CONTRACT_CASE_WORKERS") { [Etc.nprocessors, 8].min.to_s }, 10
)

def in_parallel_cases(items)
  items = items.to_a
  workers = [CASE_WORKER_LIMIT, items.length].min
  return items.flat_map { |item| yield item } if workers <= 1

  pending = Queue.new
  items.each_with_index { |item, index| pending << [index, item] }
  collected = {}
  lock = Mutex.new
  Array.new(workers) do
    Thread.new do
      loop do
        index, item = begin
                        pending.pop(true)
                      rescue ThreadError
                        break
                      end
        # A row whose fixture edit raises is a broken row, not a crashed suite:
        # without this the worker thread dies and the pool reports nothing about
        # the other rows it was carrying.
        local = begin
          yield item
        rescue StandardError => error
          ["#{item.is_a?(Hash) ? item.fetch(:name, item) : item}: fixture raised " \
           "#{error.class}: #{error.message}"]
        end
        lock.synchronize { collected[index] = local }
      end
    end
  end.each(&:join)
  collected.keys.sort.flat_map { |index| collected.fetch(index) }
end

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

# Finds one task by name anywhere in the role -- any stage file, and through the
# block/rescue/always sections a task list nests into -- and hands it to the
# caller to edit in place. Locating the task rather than naming its file keeps a
# row honest when a stage is split again, which has happened twice.
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
#
# One row per assertion family rather than one per abort site. A family shares
# its read, its parse and its shape, so covering each site individually would put
# this file on the policy gate's critical path for no additional signal.

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
    # A commented-out sample of the right assignment is the regression the
    # environment file is parsed rather than grepped for.
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
      edit_yaml(root, "inventory/group_vars/all/main.yml") do |document|
        entry = document.fetch("nas_storage").find do |candidate|
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
    # The owned settings are pinned exactly, so adding a key trips the equality
    # check before it can reach the PATCH-body assertion. Both refuse; this row
    # records which one gets there first.
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
  # The assertion the extraction repointed. It reads the runtime half's source
  # out of the tree under inspection and requires the drift-commit branch to
  # leave the reconciliation snapshot alone. Two rows, because the interesting
  # failure is not only "the branch consumes it" but "the file it is read from is
  # the wrong one".
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
    # Honestly a crash rather than a diagnostic: the drift-commit read has no
    # existence guard in front of it, where the six files the wrapper checks with
    # [ -f ] do. Both fragments are required so the row cannot pass on the
    # filename alone.
    expects_crash: ["audiobookshelf-runtime.rb", "No such file or directory"]
  },
  # The mode argument. Everything above the `if mode == "static"` block runs for
  # every mode; everything inside it is the deployment-order and role-shape
  # sweep, which a deployed run has no business repeating.
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

def judge(label, expects, stdout, stderr, status, expects_crash: nil)
  output = stdout + stderr
  failures = []
  if expects_crash
    failures << "#{label}: accepted what it must refuse" if status.success?
    Array(expects_crash).each do |fragment|
      failures << "#{label}: did not name #{fragment}, got #{output.strip.inspect}" unless
        output.include?(fragment)
    end
    return failures
  end
  if expects.nil?
    failures << "#{label}: expected success, got exit #{status.exitstatus}: #{output.strip}" unless
      status.success?
    return failures
  end

  if status.success?
    failures << "#{label}: accepted what it must refuse"
  elsif !output.include?("Audiobookshelf contract failed: #{expects}")
    failures << "#{label}: refused for the wrong reason, wanted #{expects.inspect}, " \
                "got #{output.strip.lines.first.to_s.strip.inspect}"
  end
  failures
end

def static_failures(program = STATIC_PROGRAM, rows = STATIC_ROWS)
  in_parallel_cases(rows) do |row|
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
            expects_crash: row[:expects_crash])
    end
  end
end

# --- runtime layer ---------------------------------------------------------
#
# The runtime half's first `case MODE` handles every mode that needs no vault,
# no container and no network: it is the half of the program the audio test and
# the drift hook test already drive. Each row below runs one of those modes
# against a fixture repository, so the modes that read the inspected tree can be
# moved one property at a time.

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
    # The runtime half's own second self-read. It counts the direct logins this
    # very program makes, against the copy in the tree it is inspecting.
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
    # Diagnostics and drift snapshots are written under the report root, so a
    # report root that is a symlink is somewhere else's directory.
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
  in_parallel_cases(rows) do |row|
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
      failures = judge("runtime: #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr, status)
      # Only worth asking what a passing mode reported; a mode that refused has
      # already been judged, and a second failure line about the missing success
      # line says nothing the first did not.
      if failures.empty? && row[:reports] && !stdout.include?(row.fetch(:reports))
        failures << "runtime: #{row.fetch(:name)}: did not report " \
                    "#{row.fetch(:reports).inspect}, got #{stdout.strip.inspect}"
      end
      failures
    end
  end
end

# --- wrapper layer ---------------------------------------------------------
#
# tests/contracts/audiobookshelf.sh resolves both programs from its own checkout
# rather than from the tree it is inspecting, so a copy of the three files into a
# throwaway tests/contracts/ is a whole working contract. That is what lets a row
# point PLATFORM_CONTRACT_REPO_DIR at a broken fixture and still exercise the
# real wrapper.

def with_contract_copy(static: File.read(STATIC_PROGRAM), runtime: File.read(RUNTIME_PROGRAM),
                       wrapper: File.read(CONTRACT))
  Dir.mktmpdir("nas-platform-audiobookshelf-wrapper.") do |raw|
    root = File.realpath(raw)
    build_fixture_repository(root)
    contracts = File.join(root, "tests", "contracts")
    {
      "audiobookshelf.sh" => wrapper,
      "audiobookshelf-static.rb" => static,
      "audiobookshelf-runtime.rb" => runtime
    }.each do |name, content|
      destination = File.join(contracts, name)
      File.write(destination, content)
      File.chmod(name.end_with?(".sh") ? 0o755 : 0o644, destination)
    end
    yield File.join(contracts, "audiobookshelf.sh"), root
  end
end

def broken_fixture_repository
  Dir.mktmpdir("nas-platform-audiobookshelf-broken.") do |raw|
    root = File.realpath(raw)
    build_fixture_repository(root)
    compose_service(root) { |spec| spec["restart"] = "always" }
    yield root
  end
end

def wrapper_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(wrapper: wrapper_source) do |contract, copy_root|
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => ROOT }, contract, "static"
    )
    failures << "wrapper: static mode failed: #{(stdout + stderr).strip}" unless status.success?
    failures << "wrapper: static mode did not report the property it proved" unless
      stdout.include?("Audiobookshelf static contract passed")

    # Each of the six files the wrapper checks before it runs anything.
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

    # The row that proves the wrapper still runs the static program at all: the
    # tree under inspection is broken, the wrapper's own checkout is not.
    broken_fixture_repository do |broken|
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => broken }, contract, "static"
      )
      failures << "wrapper: static mode passed against a broken repository" if status.success?
      failures << "wrapper: static mode did not report the broken repository" unless
        (stdout + stderr).include?("restart policy differs")
    end

    # ... and that it is the *inspected* tree that is read, not the checkout the
    # programs came from. Breaking the copy's own compose.yml while pointing the
    # variable at this repository must change nothing.
    compose_service(copy_root) { |spec| spec["restart"] = "always" }
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => ROOT }, contract, "static"
    )
    failures << "wrapper: a broken checkout was read instead of the named tree: " \
                "#{(stdout + stderr).strip}" unless status.success?
  end

  # The branch every deployment actually takes. Neither tests/integration.sh nor
  # run_contracts.rb --execute sets PLATFORM_CONTRACT_REPO_DIR, so the default is
  # the only path in production -- and it is the one where resolving the programs
  # from the script's own checkout is load-bearing rather than shadowed.
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

  # The runtime half's own roots. PLATFORM_REPO_ROOT and
  # PLATFORM_CONTRACT_REPO_DIR must both reach it bound to the inspected tree
  # rather than to the checkout the program was loaded from -- the second and
  # third sites of the same two-roots defect, a few lines over from the first.
  # The two trees have to be genuinely different files for the question to have
  # an answer, so the contract's own checkout is broken and the tree it is
  # pointed at is not, and then the other way round. The authentication budget
  # mode reads both variables.
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

  # The programs themselves, in the direction absence cannot prove. A tree that
  # is pointed at holds a *different* program at each sibling path; running
  # either of them is the defect, and it is visible as a sentinel rather than as
  # a missing file, so it stays visible however the fixture is assembled.
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

  # The runtime half's *source*, which the static half reads for its drift-commit
  # branch, is a fourth binding to the inspected tree: the wrapper hands it over
  # as $runtime_source. Poison the inspected tree's copy and leave the checkout's
  # alone -- the refusal is what says which one was read.
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

  # PLATFORM_CONTRACT_REPO_DIR is what both programs require tests/policy_support
  # from, and it too must name the inspected tree. An inspected tree without that
  # file has to be a LoadError naming *its* path, not a silent fallback to the
  # checkout's copy.
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
  failures
end

# Reports what each program saw on stdin and what the caller still has, which is
# the only way the redirect is observable: neither real program reads stdin, so
# the redirect is what keeps that true rather than something that changes an
# outcome today.
STDIN_PROBE = <<~'PROBE'
  warn "probe read #{$stdin.read.inspect}"
  exit 1
PROBE

def stdin_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  # The static invocation, which runs for every mode.
  with_contract_copy(static: STDIN_PROBE, wrapper: wrapper_source) do |contract|
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => ROOT },
      "/bin/sh", "-c", "#{contract.shellescape} static; printf 'left:'; cat",
      stdin_data: "caller-payload\n"
    )
    output = stdout + stderr
    failures << "stdin: the probing shell itself failed: #{output.strip}" unless status.success?
    failures << "stdin: the static program was handed the caller's input: #{output.strip.inspect}" unless
      output.include?('probe read ""')
    failures << "stdin: the caller's input did not survive the contract: #{output.strip.inspect}" unless
      output.include?("left:caller-payload")
  end

  # The runtime invocation, which is `exec`ed and so is the last thing the script
  # does -- its redirect needs its own row because the static one cannot cover it.
  with_contract_copy(runtime: STDIN_PROBE, wrapper: wrapper_source) do |contract, copy_root|
    media, reports = runtime_sandbox(copy_root)
    stdout, stderr, _status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => ROOT,
        "PLATFORM_MEDIA_ROOT" => media, "PLATFORM_REPORT_ROOT" => reports },
      "/bin/sh", "-c", "#{contract.shellescape} audio-self-test; printf 'left:'; cat",
      stdin_data: "caller-payload\n"
    )
    output = stdout + stderr
    failures << "stdin: the runtime program was handed the caller's input: #{output.strip.inspect}" unless
      output.include?('probe read ""')
  end
  failures
end

# --- planted regressions ---------------------------------------------------
#
# Each entry removes one guard from one program and names the rows that must
# catch it. A row that survives its own guard being deleted is proving nothing.

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
    # The same guard, and the timezone row's cascade recorded rather than
    # tolerated: the owned settings are pinned exactly, so the equality check is
    # what refuses a repository that adds timeZone. Remove it and the row still
    # refuses -- from the PATCH-body assertion further down, with a different
    # sentence, which is the regression.
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
    # The assertion #147 repointed. Restoring the old path is the exact
    # regression the repoint exists to prevent: the wrapper is 74 lines now and
    # holds no drift-commit branch, so the slice would be empty forever and the
    # guard would accept anything.
    label: "the drift-commit read pointed back at the wrapper",
    program: :static,
    from: "drift_commit_branch = File.read(contract_source_path)",
    to: 'drift_commit_branch = File.read(File.join(File.dirname(contract_source_path), "audiobookshelf.sh"))',
    rows: ["a drift commit that consumes its own reconciliation evidence"],
    # In this repository the mutant would accept every tree in silence: the
    # wrapper is still there, holds no drift-commit branch, and rpartition on an
    # absent separator yields a slice with nothing in it. Against the fixture,
    # which carries no wrapper because neither program reads one, the same
    # mutation is an Errno instead. Either way the row refuses -- and the reason
    # it gives is the regression.
    detects: "refused for the wrong reason"
  },
  {
    label: "the mode guard around the role-shape sweep",
    program: :static,
    from: 'if mode == "static"',
    to: "if true",
    rows: ["a role-shape defect under a non-static mode"],
    # Removing the guard does not accept anything -- it makes a mode that should
    # have said nothing refuse. The row's own expectation is success, so it
    # reports the refusal rather than an acceptance.
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
    # The runtime half's own self-read, the second one this extraction had to
    # repoint. Pointing it back at the wrapper makes it count zero logins in a
    # 74-line file and refuse every repository forever.
    label: "the direct-login count pointed back at the wrapper",
    program: :runtime,
    from: 'repo_root.join("tests/contracts/audiobookshelf-runtime.rb").read',
    to: 'repo_root.join("tests/contracts/audiobookshelf.sh").read',
    rows: ["the authentication budget self-test"],
    detects: "expected success"
  },
  {
    label: "the direct authentication proof",
    program: :runtime,
    from: 'fail_contract("Audiobookshelf direct authentication proof is absent") unless count.positive?',
    to: "nil unless true",
    rows: ["a runtime half with no direct authentication of its own"],
    # With no proof required the login count is zero, which lowers the budget
    # total rather than raising it -- so the mode reaches its success line and
    # the row reports an acceptance.
    detects: "accepted what it must refuse"
  },
  {
    label: "the report root safety check",
    program: :runtime,
    from: "REPORT_ROOT.directory? && !REPORT_ROOT.symlink?",
    to: "true",
    rows: ["a report root that is a symlink"],
    # Nothing downstream re-checks it, so the snapshot lands in the symlink's
    # target and the mode reaches its success line.
    detects: "accepted what it must refuse"
  }
].freeze

def plant(source, mutation)
  from = mutation.fetch(:from)
  abort "self-test could not plant #{mutation.fetch(:label)}: #{from.inspect} is absent" unless
    source.include?(from)

  source.sub(from, mutation.fetch(:to))
end

def with_mutant(mutation)
  canonical = mutation.fetch(:program) == :static ? STATIC_PROGRAM : RUNTIME_PROGRAM
  Dir.mktmpdir("nas-platform-audiobookshelf-mutant.") do |directory|
    path = File.join(directory, File.basename(canonical))
    File.write(path, plant(File.read(canonical), mutation))
    yield path
  end
end

def rows_named(rows, names)
  selected = rows.select { |row| names.include?(row.fetch(:name)) }
  abort "self-test names a row that does not exist: #{names.inspect}" unless
    selected.length == names.length

  selected
end

if ARGV.include?("--self-test")
  in_parallel_cases(PROGRAM_MUTATIONS) do |mutation|
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

  # The redirects' own regression, one per invocation. Neither real program reads
  # stdin, so dropping `</dev/null` changes no outcome today -- which is exactly
  # why it needs a program that does read, and why the rule cannot be proven by
  # the contract passing.
  planted_redirects = 0
  [
    ["  \"$runtime_source\" \"$mode\" </dev/null\n", "  \"$runtime_source\" \"$mode\"\n"],
    ["  \"$mode\" \"$@\" </dev/null\n", "  \"$mode\" \"$@\"\n"]
  ].each do |from, to|
    unredirected = File.read(CONTRACT).sub(from, to)
    abort "self-test could not plant a dropped stdin redirect: #{from.inspect}" if
      unredirected == File.read(CONTRACT)

    leaked = stdin_failures(wrapper_source: unredirected)
    abort "self-test failed: a dropped stdin redirect was accepted" if leaked.empty?
    planted_redirects += 1
  end

  # The defect #251 shipped one version of and #259 found a second site for:
  # resolving a program from the tree being inspected rather than from the
  # script's own checkout. Both sites, and the reverse direction of the two the
  # wrapper binds to the inspected tree on purpose.
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

  puts "audiobookshelf contract: self-test detects " \
       "#{PROGRAM_MUTATIONS.length + planted_redirects + planted_roots} planted regressions"
  exit
end

failures = static_failures + runtime_failures + wrapper_failures + stdin_failures
unless failures.empty?
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Audiobookshelf contract violation(s)"
end

puts "audiobookshelf contract: #{STATIC_ROWS.length} static and #{RUNTIME_ROWS.length} runtime " \
     "properties hold, and the wrapper reaches both programs with an empty stdin"
