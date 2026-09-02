#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Behaviour of the Jellyfin service contract's two Ruby programs.
#
# Until #147 both lived in `<<'RUBY'` heredocs inside
# tests/contracts/jellyfin.sh -- 1,276 of that file's 1,353 lines. `sh -n` reads
# a quoted heredoc as opaque text, so nothing but an integration lane with
# Docker, a converged Jellyfin and a real vault ever executed either one.
# tests/contracts/jellyfin-static.rb and tests/contracts/jellyfin-runtime.rb are
# files now, so both are reachable here.
#
# Four layers, because the contract has four kinds of property:
#
#   Static -- build a fixture repository out of the files the contract reads,
#   break exactly one thing in it, and require the program to name that thing.
#   The assertion text is the interface: a guard that fails for the wrong reason
#   has stopped guarding what it names, so every row pins the exact diagnostic.
#   This layer also covers the platform axis, which is jellyfin's own: the same
#   program judges three different capability contracts depending on ARGV[1].
#
#   Runtime -- the one mode that reaches the runtime half's own code without a
#   vault, a container or a network. `seed-fixture-only` runs seed_fixture and
#   exits before the vault read, so the video fixture's own refusals move one at
#   a time here. Everything past that read needs a served Jellyfin interface;
#   tests/jellyfin_transcode_contract_test.rb already drives the transcode and
#   renamed-library proofs in process by loading this same file.
#
#   Wrapper -- tests/contracts/jellyfin.sh is what turns a mode into two
#   invocations. Its rows prove both programs are reached, that each is resolved
#   from the script's own checkout while the tree to inspect is passed in, and
#   that neither can consume the caller's stdin.
#
#   Self-read -- the static half reads the RUNTIME half's source for six
#   sentinels it cannot observe statically. Those six were partly vacuous while
#   both halves shared one file, because three of them quote their own subject
#   verbatim and so matched the assertion's own text; they are load-bearing for
#   the first time now. A row per sentinel, plus rows that the source is read out
#   of the INSPECTED tree and not out of the checkout.
#
# Run with --self-test to plant a regression in each program and prove the rows
# above detect it.

require "digest"
require "etc"
require "fileutils"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
CONTRACT = File.join(ROOT, "tests", "contracts", "jellyfin.sh")
STATIC_PROGRAM = File.join(ROOT, "tests", "contracts", "jellyfin-static.rb")
RUNTIME_PROGRAM = File.join(ROOT, "tests", "contracts", "jellyfin-runtime.rb")

# The `-ryaml -rdigest` preloads tests/contracts/jellyfin.sh carries, because
# the static program requires neither itself. Every invocation of it here must
# carry both or every row fails identically on an uninitialized constant, which
# would read as the extraction having broken everything. Jellyfin is the first
# contract in this series to need two.
STATIC_COMMAND = [RbConfig.ruby, "-ryaml", "-rdigest"].freeze

# Exactly what the two halves read out of the tree they inspect. A fixture
# holding only these is the proof that the list is the list they actually need --
# tests/contracts/jellyfin-runtime.rb included, because the static half reads the
# runtime half's source out of the inspected tree for its six runtime sentinels.
FIXTURE_FILES = %w[
  roles/jellyfin/tasks/main.yml
  roles/jellyfin/tasks/authentication.yml
  roles/jellyfin/tasks/bootstrap.yml
  roles/jellyfin/tasks/deploy.yml
  roles/jellyfin/tasks/identity.yml
  roles/jellyfin/tasks/libraries.yml
  roles/jellyfin/tasks/library_inventory.yml
  roles/jellyfin/tasks/managed_users.yml
  roles/jellyfin/tasks/preflight.yml
  roles/jellyfin/tasks/primary_identity.yml
  roles/jellyfin/tasks/qsv_probe.yml
  roles/jellyfin/tasks/settings.yml
  roles/jellyfin/tasks/verify.yml
  roles/jellyfin/defaults/main.yml
  roles/jellyfin/meta/argument_specs.yml
  roles/jellyfin/templates/env.j2
  roles/jellyfin/files/yonatan-avatar.jpeg
  services/jellyfin/compose.yml
  services/jellyfin/compose.mac.yml
  services/jellyfin/compose.integration.yml
  tests/policy_support.rb
  tests/contracts/jellyfin-runtime.rb
].freeze

# Deliberately absent from that list: tests/contracts/jellyfin.sh and
# tests/contracts/jellyfin-static.rb. Neither program reads them out of the
# inspected tree, and a fixture that carried them would shadow the defect #251
# shipped -- a sibling resolved from $repo_dir finds a copy there and nothing
# looks wrong. jellyfin-runtime.rb is present because the static half really does
# read it from the tree it is inspecting; the direction absence cannot decide is
# covered instead by planting a different program at that path.

# Runs independent cases through a worker pool, capped at the core count. The
# same shape and the same reasoning as in_parallel_cases in
# tests/media_acquisition_reconciliation_support.rb: a check that spawns a
# subprocess per case, serially, becomes the floor for the whole policy gate, and
# oversubscribing a four-core CI runner trades wall time for contention. Never
# more workers than cores.
CASE_WORKER_LIMIT = Integer(
  ENV.fetch("JELLYFIN_CONTRACT_CASE_WORKERS") { [Etc.nprocessors, 8].min.to_s }, 10
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

# Every text substitution asserts its own match count. A `sub` that silently
# matched nothing plants no defect and reports a pass that proves nothing, which
# is the hazard #263 recorded and tests/policy_mutation_support.rb's mutate_text
# now guards against. Rows here carry the same rule.
def edit_text(root, relative, from, to, expected: 1)
  path = File.join(root, relative)
  source = File.read(path)
  found = source.scan(from).length
  raise "#{relative}: #{found} matches for #{from.inspect}, expected #{expected}" unless
    found == expected

  File.write(path, source.gsub(from, to))
end

def compose_service(root, relative = "services/jellyfin/compose.yml")
  edit_yaml(root, relative) { |document| yield document.fetch("services").fetch("jellyfin") }
end

ROLE_STAGES = FIXTURE_FILES.grep(%r{\Aroles/jellyfin/tasks/}).freeze

# Finds one task by name anywhere in the role -- any stage file, and through the
# block/rescue/always sections a task list nests into -- and hands it to the
# caller to edit in place. Locating the task rather than naming its file keeps a
# row honest when a stage is split again, which #157 is still doing.
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

def rename_role_task(root, name, replacement)
  edit_role_task(root, name) { |task| task["name"] = replacement }
end

# --- static layer ----------------------------------------------------------
#
# One row per assertion family rather than one per abort site: the program has
# 58 refuse() calls, and a family shares its read, its parse and its shape, so
# covering each site individually would put this file on the policy gate's
# critical path for no additional signal.
#
# `platform` defaults to nas. The mac and integration rows exist because the
# override branch is the only part of the program that differs by platform, and
# `nas` never enters it at all.

STATIC_ROWS = [
  { name: "an intact repository", break: ->(_root) {}, expects: nil },
  { name: "an intact repository on mac", platform: "mac", break: ->(_root) {}, expects: nil },
  { name: "an intact repository on integration", platform: "integration",
    break: ->(_root) {}, expects: nil },
  {
    name: "the approved administrator avatar bytes replaced",
    break: ->(root) { File.binwrite(File.join(root, "roles/jellyfin/files/yonatan-avatar.jpeg"), "nope") },
    expects: "approved administrator avatar hash differs"
  },
  {
    name: "the container running as something other than the NAS identity",
    break: ->(root) { compose_service(root) { |spec| spec["user"] = "0:0" } },
    expects: "platform identity differs"
  },
  {
    name: "the application port renumbered",
    break: ->(root) { compose_service(root) { |spec| spec["ports"] = ["8097:8096/tcp"] } },
    expects: "NAS port differs"
  },
  {
    name: "the read-only media mount made writable",
    break: lambda { |root|
      compose_service(root) do |spec|
        spec["volumes"] = spec.fetch("volumes").map { |volume| volume.sub(":/media:ro", ":/media") }
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
    name: "the media network name assignment surviving only as a comment",
    break: lambda { |root|
      edit_text(root, "roles/jellyfin/templates/env.j2",
                "PLATFORM_MEDIA_NETWORK=", "# PLATFORM_MEDIA_NETWORK=")
    },
    expects: "media network environment is absent"
  },
  {
    name: "the media control network argument left optional",
    break: lambda { |root|
      edit_yaml(root, "roles/jellyfin/meta/argument_specs.yml", aliases: false) do |document|
        document.dig("argument_specs", "main", "options", "platform_media_control_network")
                .delete("required")
      end
    },
    expects: "media control network argument validation is absent"
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
    name: "the NAS render device dropped",
    break: ->(root) { compose_service(root) { |spec| spec["devices"] = [] } },
    expects: "NAS render device mapping is absent"
  },
  {
    name: "the NAS render device group access dropped",
    break: ->(root) { compose_service(root) { |spec| spec["group_add"] = [] } },
    expects: "NAS render device group access is absent"
  },
  {
    name: "the stop grace period shortened",
    break: ->(root) { compose_service(root) { |spec| spec["stop_grace_period"] = "10s" } },
    expects: "NAS stop grace period differs"
  },
  {
    # A scalar rather than an argv array: Compose accepts it, and the contract's
    # point is that the check has to be a real command list.
    name: "the health check reduced to a scalar",
    break: ->(root) { compose_service(root) { |spec| spec.fetch("healthcheck")["test"] = "CMD true" } },
    expects: "health check is absent"
  },
  {
    # The nas branch's whole content: production must carry no override at all.
    name: "a NAS override introduced",
    break: lambda { |root|
      FileUtils.cp(File.join(root, "services/jellyfin/compose.mac.yml"),
                   File.join(root, "services/jellyfin/compose.nas.yml"))
    },
    expects: "the NAS runs the production definition unmodified"
  },
  {
    name: "the mac override deleted",
    platform: "mac",
    break: ->(root) { FileUtils.rm(File.join(root, "services/jellyfin/compose.mac.yml")) },
    expects: "services/jellyfin/compose.mac.yml is absent"
  },
  {
    # Compose appends sequences, so an untagged empty list silently keeps the NAS
    # device. The !override tag is the only thing that actually replaces it, and
    # this row is why the assertion reads the override's TEXT and not just its
    # parse.
    name: "the mac override resetting devices without an explicit tag",
    platform: "mac",
    break: lambda { |root|
      edit_text(root, "services/jellyfin/compose.mac.yml", "devices: !override", "devices:")
    },
    expects: "mac override must reset devices with an explicit tag"
  },
  {
    # Every mac-override row edits the file as TEXT rather than through
    # edit_yaml. Re-dumping the document drops the !override tags, which makes
    # the explicit-tag assertion fire first and every one of these rows report
    # the wrong sentence -- a fixture artefact rather than the property.
    name: "the mac override resetting devices to something non-empty",
    platform: "mac",
    break: lambda { |root|
      edit_text(root, "services/jellyfin/compose.mac.yml",
                "devices: !override []", 'devices: !override ["/dev/null:/dev/null"]')
    },
    expects: "mac override must reset devices to empty"
  },
  {
    name: "the mac override redefining a key outside its allowance",
    platform: "mac",
    break: lambda { |root|
      edit_text(root, "services/jellyfin/compose.mac.yml",
                "    devices: !override []\n", "    restart: always\n    devices: !override []\n")
    },
    expects: "mac override may not redefine restart"
  },
  {
    name: "the mac override pinning an image",
    platform: "mac",
    break: lambda { |root|
      edit_text(root, "services/jellyfin/compose.mac.yml",
                "    devices: !override []\n", "    image: jellyfin:local\n    devices: !override []\n")
    },
    # `image` is outside the allowance too, so the surplus refusal comes first.
    # The row pins which sentence the program actually reaches rather than which
    # one reads best.
    expects: "mac override may not redefine image"
  },
  {
    # Only the mac override republishes a port -- the integration sandbox keeps
    # the production one -- so this branch is reachable on mac alone.
    name: "the mac override republishing ports without an explicit tag",
    platform: "mac",
    break: lambda { |root|
      edit_text(root, "services/jellyfin/compose.mac.yml", "ports: !override\n", "ports:\n")
    },
    expects: "mac override must replace published ports with an explicit tag"
  },
  {
    name: "the primary administrator renamed",
    break: lambda { |root|
      edit_yaml(root, "roles/jellyfin/defaults/main.yml", aliases: false) do |document|
        document["jellyfin_admin_username"] = "admin"
      end
    },
    expects: "primary administrator differs"
  },
  {
    name: "the server name changed",
    break: lambda { |root|
      edit_yaml(root, "roles/jellyfin/defaults/main.yml", aliases: false) do |document|
        document["jellyfin_server_name"] = "Jellyfin"
      end
    },
    expects: "server name differs"
  },
  {
    name: "the declared avatar hash drifting from the approved bytes",
    break: lambda { |root|
      edit_yaml(root, "roles/jellyfin/defaults/main.yml", aliases: false) do |document|
        document["jellyfin_admin_avatar_sha256"] = "0" * 64
      end
    },
    expects: "administrator avatar hash differs"
  },
  {
    name: "a managed library repointed",
    break: lambda { |root|
      edit_yaml(root, "roles/jellyfin/defaults/main.yml", aliases: false) do |document|
        document.fetch("jellyfin_libraries").first["path"] = "/media/Films"
      end
    },
    expects: "managed libraries differ"
  },
  {
    # Collections is Jellyfin's own automatic library. Declaring it makes the
    # platform fight the application for ownership, and the assertion that
    # refuses it is separate from the exact-list one so it survives a
    # deliberately widened list.
    name: "Collections declared as a managed library",
    break: lambda { |root|
      edit_yaml(root, "roles/jellyfin/defaults/main.yml", aliases: false) do |document|
        document.fetch("jellyfin_libraries") <<
          { "name" => "Collections", "collection_type" => "boxsets", "path" => "/media/Collections" }
      end
    },
    # The exact-list assertion fires first; the row pins that, and the dedicated
    # Collections refusal is covered by a self-test mutation that removes the
    # exact-list check and requires the Collections sentence to appear.
    expects: "managed libraries differ"
  },
  {
    name: "local metadata written into the read-only media mount",
    break: lambda { |root|
      edit_yaml(root, "roles/jellyfin/defaults/main.yml", aliases: false) do |document|
        document.fetch("jellyfin_library_options")["SaveLocalMetadata"] = true
      end
    },
    expects: "managed library must not write metadata into read-only media"
  },
  {
    # A task name that survives only inside a comment is not a task. The
    # assertion reads parsed structure rather than source text precisely so this
    # row fails.
    name: "a required task surviving only as a comment",
    break: lambda { |root|
      rename_role_task(root, "Verify exact Jellyfin owned state",
                       "Verify exact Jellyfin owned state, renamed")
    },
    expects: "missing Verify exact Jellyfin owned state"
  },
  {
    # A preflight read MOVED to after the mutations rather than renamed. Renaming
    # it would be caught by the required-task sweep instead, which is a different
    # assertion; relocating it keeps every required name present so the ordering
    # check is the only thing that can refuse. preflight.yml is imported before
    # identity.yml, so appending to identity.yml puts the read after every
    # mutation task in the concatenation the contract builds.
    name: "an identity preflight read moved after the mutations",
    break: lambda { |root|
      moved = nil
      preflight_path = File.join(root, "roles/jellyfin/tasks/preflight.yml")
      document = YAML.safe_load_file(preflight_path, aliases: false)
      document.reject! do |task|
        moved = task if task.is_a?(Hash) &&
                        task["name"] == "Read Jellyfin server configuration for preflight"
        !moved.nil? && task.equal?(moved)
      end
      raise "fixture has no preflight server configuration read" if moved.nil?

      File.write(preflight_path, YAML.dump(document))
      identity_path = File.join(root, "roles/jellyfin/tasks/identity.yml")
      identity = YAML.safe_load_file(identity_path, aliases: false)
      File.write(identity_path, YAML.dump(identity + [moved]))
    },
    expects: "all identity/library preflight must precede mutation"
  },
  {
    name: "the extra-path removal issuing a verb that is not DELETE",
    break: lambda { |root|
      edit_role_task(root, "Remove extra paths from Jellyfin managed libraries") do |task|
        task.fetch("ansible.builtin.uri")["method"] = "POST"
      end
    },
    expects: "current path removal API is absent"
  },
  {
    name: "a primary identity rename with no recovery path",
    break: lambda { |root|
      edit_role_task(root, "Reconcile the Jellyfin primary administrator name safely") do |task|
        task["always"] = task.delete("rescue")
      end
    },
    expects: "primary identity rename lacks recovery"
  },
  {
    name: "the recovery marker read before its privacy is checked",
    break: lambda { |root|
      edit_role_task(root, "Require safe Jellyfin primary administrator recovery marker file") do |task|
        task.fetch("ansible.builtin.assert")["that"] =
          Array(task.fetch("ansible.builtin.assert").fetch("that"))
          .reject { |that| that.to_s.include?("stat.mode == '0600'") }
      end
    },
    expects: "recovery marker privacy is not checked before reading"
  },
  {
    # Merging onto an empty dictionary rather than onto the configuration the
    # role read back. The merge is still there, so only the read clause can
    # refuse this -- which is what gives that clause its own row.
    name: "a server configuration overwrite that reads nothing first",
    break: lambda { |root|
      edit_role_task(root, "Update the Jellyfin server name") do |task|
        task.fetch("ansible.builtin.uri")["body"] =
          "{{ {} | combine({'ServerName': jellyfin_server_name}) }}"
      end
    },
    expects: "server configuration update does not preserve unrelated fields"
  },
  {
    # The other half of the same assertion, and the one that needs its own row:
    # the read is still there and only the merge is gone, so a POST would
    # replace the whole server configuration with one key. Without this row the
    # `combine` clause could be deleted and the row above would still refuse,
    # from the read clause, proving nothing.
    name: "a server configuration overwrite whose merge is gone",
    break: lambda { |root|
      edit_role_task(root, "Update the Jellyfin server name") do |task|
        task.fetch("ansible.builtin.uri")["body"] =
          "{{ jellyfin_server_configuration_for_update.json }}"
      end
    },
    expects: "server configuration update does not preserve unrelated fields"
  },
  {
    name: "an unconditional avatar upload",
    break: lambda { |root|
      edit_role_task(root, "Upload the Jellyfin primary administrator image") { |task| task.delete("when") }
    },
    expects: "avatar upload is unconditional"
  },
  {
    name: "the NAS hardware acceleration profile weakened",
    break: lambda { |root|
      edit_yaml(root, "roles/jellyfin/defaults/main.yml", aliases: false) do |document|
        document.dig("jellyfin_encoding_profiles", "nas")["HardwareAccelerationType"] = "none"
      end
    },
    expects: "NAS encoding policy differs"
  },
  {
    name: "the Mac profile claiming hardware it does not have",
    break: lambda { |root|
      edit_yaml(root, "roles/jellyfin/defaults/main.yml", aliases: false) do |document|
        document.dig("jellyfin_encoding_profiles", "mac")["EnableHardwareEncoding"] = true
      end
    },
    expects: "Mac encoding policy is not explicit CPU fallback"
  },
  {
    name: "a managed plugin repository URL changed",
    break: lambda { |root|
      edit_yaml(root, "roles/jellyfin/defaults/main.yml", aliases: false) do |document|
        document.fetch("jellyfin_plugin_repositories").first["Url"] = "https://example.invalid/manifest.json"
      end
    },
    expects: "managed plugin repositories differ"
  },
  {
    name: "the retired repository list emptied",
    break: lambda { |root|
      edit_yaml(root, "roles/jellyfin/defaults/main.yml", aliases: false) do |document|
        document["jellyfin_retired_plugin_repository_urls"] = []
      end
    },
    expects: "retired managed plugin repositories differ"
  },
  {
    name: "a managed plugin dropped",
    break: lambda { |root|
      edit_yaml(root, "roles/jellyfin/defaults/main.yml", aliases: false) do |document|
        document["jellyfin_plugins"] = ["Intro Skipper"]
      end
    },
    expects: "managed plugins differ"
  },
  {
    name: "a plugin assembly identity changed",
    break: lambda { |root|
      edit_yaml(root, "roles/jellyfin/defaults/main.yml", aliases: false) do |document|
        document.fetch("jellyfin_plugin_packages").first["AssemblyGuid"] = "0" * 36
      end
    },
    expects: "managed plugin package identities differ"
  },
  {
    name: "the Open Subtitles configuration plugin GUID changed",
    break: lambda { |root|
      edit_yaml(root, "roles/jellyfin/defaults/main.yml", aliases: false) do |document|
        document["jellyfin_opensubtitles_plugin_id"] = "00000000-0000-0000-0000-000000000000"
      end
    },
    expects: "Open Subtitles configuration API GUID differs"
  },
  {
    # A source-text count on purpose: no_log is a per-task directive with no
    # runtime observable in a static contract.
    name: "the Open Subtitles secret redaction floor lowered",
    break: lambda { |root|
      # The floor is five and settings.yml carries 39, so every one of them has
      # to go for the count to drop below it. The expected count is stated so a
      # drifted fixture is a broken row rather than a silent no-op.
      edit_text(root, "roles/jellyfin/tasks/settings.yml",
                "no_log: true\n", "no_log: false\n", expected: 39)
    },
    expects: "Open Subtitles secret operations are not suppressed"
  },
  {
    name: "an opaque database reference introduced into the role",
    break: lambda { |root|
      edit_role_task(root, "Verify exact Jellyfin owned state") do |task|
        task["vars"] = { "jellyfin_probe" => "select from library.db" }
      end
    },
    expects: "role must not edit an opaque database"
  }
].freeze

# The static half's own refusal for an unreadable inspected tree: it requires
# tests/policy_support.rb out of PLATFORM_CONTRACT_REPO_DIR, which is the
# inspected tree and not the checkout.
def run_static(program, root, platform, contract_repo_dir: root)
  Open3.capture3(
    { "PLATFORM_CONTRACT_REPO_DIR" => contract_repo_dir },
    *STATIC_COMMAND, program, root, platform
  )
end

def static_failures(program = STATIC_PROGRAM, rows = STATIC_ROWS)
  in_parallel_cases(rows) do |row|
    failures = []
    Dir.mktmpdir("nas-platform-jellyfin-static.") do |raw|
      root = File.realpath(raw)
      build_fixture_repository(root)
      row.fetch(:break).call(root)
      stdout, stderr, status = run_static(program, root, row.fetch(:platform, "nas"))
      output = (stdout + stderr).strip
      expected = row.fetch(:expects)
      if expected.nil?
        failures << "#{row.fetch(:name)}: expected success, got #{output.inspect}" unless
          status.success?
        failures << "#{row.fetch(:name)}: succeeded without its own success line: #{output.inspect}" unless
          !status.success? ||
          stdout.include?("Jellyfin static contract passed (#{row.fetch(:platform, 'nas')})")
      else
        failures << "#{row.fetch(:name)}: was accepted" if status.success?
        failures << "#{row.fetch(:name)}: refused for the wrong reason: #{output.inspect}" unless
          status.success? || output.include?("Jellyfin contract failed: #{expected}")
      end
    end
    failures
  end
end

# --- self-read layer -------------------------------------------------------
#
# The six sentinels the static half reads out of the runtime half's SOURCE,
# because a static contract cannot observe them any other way. Each row plants
# the defect in the inspected tree's copy of jellyfin-runtime.rb and requires the
# refusal.
#
# Three of these (marked `was_vacuous`) could not fail before #147: the static
# half quotes its subject verbatim, and while both halves shared one file the
# assertion's own text satisfied its own `include?`. Measured, not reasoned
# about -- the capture harness recorded them passing against a planted defect.
#
# One of the six is STILL vacuous and this extraction does not change that:
# `assert_acceleration_and_plugins(token, opensubtitles_username,
# opensubtitles_password)` is also the def's own signature, so the include? holds
# whether or not the seed path calls it. That is a pre-existing weakness in the
# contract's own assertion, recorded here rather than silently fixed, and the row
# below asserts the weakness so a later reader finds it stated.
SELF_READ_ROWS = [
  {
    name: "the fixture query dropping its runtime field",
    from: "fields=Path,MediaSources,RunTimeTicks",
    to: "fields=Path,MediaSources",
    expects: "fixture query does not request its runtime field"
  },
  {
    name: "the fixture wait no longer requiring probed metadata",
    from: "    ready = found &&\n",
    to: "    ready = found ||\n",
    expects: "fixture polling does not wait for probed media metadata"
  },
  {
    name: "synthetic Open Subtitles credentials no longer isolated by platform",
    from: 'VALIDATE_EXTERNAL_OPENSUBTITLES = PLATFORM != "integration"',
    to: "VALIDATE_EXTERNAL_OPENSUBTITLES = true",
    expects: "integration contract does not isolate synthetic Open Subtitles credentials",
    was_vacuous: true
  },
  {
    name: "the external validation request no longer guarded",
    from: "if VALIDATE_EXTERNAL_OPENSUBTITLES\n    _response, validation = request(",
    to: "if true\n    _response, validation = request(",
    expects: "integration contract does not isolate synthetic Open Subtitles credentials"
  },
  {
    name: "the Open Subtitles GUID comparison no longer normalizing",
    from: 'opensubtitles.fetch("Id").delete("-").casecmp?(OPENSUBTITLES_ID.delete("-"))',
    to: 'opensubtitles.fetch("Id").casecmp?(OPENSUBTITLES_ID)',
    expects: "runtime Open Subtitles identity verification does not normalize GUID representation",
    was_vacuous: true
  }
].freeze

# The sixth sentinel has no row, deliberately.
#
# `refuse("seed does not verify that owned plugin and encoding policy survived")
# unless contract.include?("assert_acceleration_and_plugins(token,
# opensubtitles_username, opensubtitles_password)")` is satisfied by
# jellyfin-runtime.rb:788 -- the def's own signature -- as well as by the seed
# path's call at :1317. Deleting the call leaves the signature, so the assertion
# holds either way and this extraction does not change that: it was vacuous
# before the cut for the same reason it is vacuous after it, which is why no
# declared difference covers it.
#
# It is recorded here rather than asserted. A row expecting success against the
# planted defect would pin the weakness in place: anchoring the literal to a
# call site (`/^  assert_acceleration_and_plugins\(/`) is the fix, and that fix
# would then read as a regression. Fixing it is a repair rather than a move, so
# it belongs to its own change and not to #147.

def self_read_failures(program = STATIC_PROGRAM, rows = SELF_READ_ROWS)
  in_parallel_cases(rows) do |row|
    failures = []
    Dir.mktmpdir("nas-platform-jellyfin-selfread.") do |raw|
      root = File.realpath(raw)
      build_fixture_repository(root)
      edit_text(root, "tests/contracts/jellyfin-runtime.rb", row.fetch(:from), row.fetch(:to))
      stdout, stderr, status = run_static(program, root, "nas")
      output = (stdout + stderr).strip
      if row.fetch(:expects).nil?
        failures << "#{row.fetch(:name)}: expected success, got #{output.inspect}" unless
          status.success?
      else
        failures << "#{row.fetch(:name)}: was accepted" if status.success?
        failures << "#{row.fetch(:name)}: refused for the wrong reason: #{output.inspect}" unless
          status.success? || output.include?("Jellyfin contract failed: #{row.fetch(:expects)}")
      end
    end
    failures
  end
end

# The other half of the same property: the source is read out of the INSPECTED
# tree, not out of the checkout the program was loaded from. Breaking the
# checkout's own copy while pointing at a whole tree must change nothing, and
# breaking the inspected tree's copy must refuse -- which is what says which file
# was read.
def self_read_root_failures(program = STATIC_PROGRAM)
  failures = []
  Dir.mktmpdir("nas-platform-jellyfin-selfroot.") do |raw|
    root = File.realpath(raw)
    build_fixture_repository(root)
    # A sentinel the checkout's copy does not have. If the program read the
    # checkout it could never see it, so the refusal is proof of which tree won.
    edit_text(root, "tests/contracts/jellyfin-runtime.rb",
              "fields=Path,MediaSources,RunTimeTicks", "fields=Path")
    _stdout, stderr, status = run_static(program, root, "nas")
    failures << "self-read: the checkout's runtime source was read instead of the inspected tree's" if
      status.success?
    failures << "self-read: a poisoned inspected runtime source was refused without its diagnostic: " \
                "#{stderr.strip.inspect}" unless
      status.success? || stderr.include?("fixture query does not request its runtime field")
  end
  failures
end

# --- runtime layer ---------------------------------------------------------
#
# seed-fixture-only is the whole Docker-free surface: it runs seed_fixture and
# exits before the vault read at jellyfin-runtime.rb:1103. The video fixture's
# own refusals are the interface, and they are what tests/integration.sh:1209
# depends on before a container exists.

# PLATFORM_MEDIA_ROOT/Media is what jellyfin-runtime.rb:109 derives when
# PLATFORM_JELLYFIN_MEDIA_ROOT is unset, which is every deployment.
FIXTURE_RELATIVE = "Media/Movies/Task 11 Contract Movie (2026)/Task 11 Contract Movie (2026).mp4"

def runtime_environment(media, docker, report)
  {
    "PLATFORM_JELLYFIN_PLATFORM" => "nas",
    "PLATFORM_JELLYFIN_PORT" => "8096",
    "PLATFORM_JELLYFIN_CONTAINER" => "jellyfin",
    "PLATFORM_JELLYFIN_FIXTURE_PRESEEDED" => "false",
    "PLATFORM_JELLYFIN_AVATAR_PATH" => File.join(ROOT, "roles/jellyfin/files/yonatan-avatar.jpeg"),
    "PLATFORM_MEDIA_ROOT" => media,
    "PLATFORM_DOCKER_ROOT" => docker,
    "PLATFORM_REPORT_ROOT" => report
  }
end

def with_runtime_sandbox
  Dir.mktmpdir("nas-platform-jellyfin-runtime.") do |raw|
    root = File.realpath(raw)
    media = File.join(root, "media")
    docker = File.join(root, "docker")
    report = File.join(root, "report")
    [media, docker, report].each { |directory| FileUtils.mkdir_p(directory) }
    yield root, runtime_environment(media, docker, report), media
  end
end

RUNTIME_ROWS = [
  {
    name: "an absent fixture is seeded",
    prepare: ->(_media) {},
    expects: nil,
    then: lambda { |media|
      path = File.join(media, FIXTURE_RELATIVE)
      next "the fixture was not written" unless File.file?(path)

      # Jellyfin reads the fixture as the container user, so seed_fixture opens
      # it 0o644. What lands on disk is 0o644 masked by the process umask, and
      # the umask belongs to the ENVIRONMENT rather than to the contract -- the
      # same mistake as pinning a shell's wording. Deriving the expectation is
      # what keeps this row about the mode the program asked for. Under an
      # unusually tight umask (0o077) the mutation to 0o600 becomes invisible;
      # the self-test then aborts with "was accepted", which is loud.
      expected = 0o644 & ~File.umask
      actual = File.stat(path).mode & 0o777
      next format("the fixture was written with mode 0o%o, not the 0o%o that 0o644 masks to",
                  actual, expected) unless actual == expected

      nil
    }
  },
  {
    name: "an identical fixture is accepted unchanged",
    prepare: lambda { |media|
      # Seeded by a first run, so the bytes are the program's own rather than
      # this file's copy of them -- which would drift.
      nil
    },
    seed_first: true,
    expects: nil
  },
  {
    name: "a fixture whose bytes drifted is refused",
    prepare: lambda { |media|
      path = File.join(media, FIXTURE_RELATIVE)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, "not the fixture")
    },
    expects: "video fixture bytes drifted"
  },
  {
    name: "a fixture path that is a symlink is refused",
    prepare: lambda { |media|
      path = File.join(media, FIXTURE_RELATIVE)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite("#{path}.real", "elsewhere")
      File.symlink("#{path}.real", path)
    },
    expects: "fixture path is a symlink"
  }
].freeze

def runtime_failures(program = RUNTIME_PROGRAM, rows = RUNTIME_ROWS)
  in_parallel_cases(rows) do |row|
    failures = []
    with_runtime_sandbox do |_root, environment, media|
      if row.fetch(:seed_first, false)
        _out, err, status = Open3.capture3(environment, RbConfig.ruby, program, "seed-fixture-only")
        failures << "#{row.fetch(:name)}: the first seeding run failed: #{err.strip}" unless
          status.success?
      end
      row.fetch(:prepare).call(media)
      stdout, stderr, status = Open3.capture3(
        environment, RbConfig.ruby, program, "seed-fixture-only"
      )
      output = (stdout + stderr).strip
      expected = row.fetch(:expects)
      if expected.nil?
        failures << "#{row.fetch(:name)}: expected success, got #{output.inspect}" unless
          status.success?
        failures << "#{row.fetch(:name)}: succeeded without its own success line: #{output.inspect}" unless
          !status.success? || stdout.include?("Jellyfin video fixture prepared before deployment")
        after = row[:then]&.call(media)
        failures << "#{row.fetch(:name)}: #{after}" if after
      else
        failures << "#{row.fetch(:name)}: was accepted" if status.success?
        failures << "#{row.fetch(:name)}: refused for the wrong reason: #{output.inspect}" unless
          status.success? || output.include?("Jellyfin contract failed: #{expected}")
      end
    end
    failures
  end
end

# The runtime half's argv and environment ABI, which the wrapper is the only
# caller of. A missing PLATFORM_* variable must be a named KeyError rather than a
# silent default, and the mode must come off ARGV[0].
def runtime_abi_failures(program = RUNTIME_PROGRAM)
  failures = []
  with_runtime_sandbox do |_root, environment, _media|
    _out, err, status = Open3.capture3(environment, RbConfig.ruby, program)
    failures << "runtime ABI: a missing mode argument was accepted" if status.success?
    failures << "runtime ABI: a missing mode argument did not name ARGV: #{err.strip.inspect}" unless
      status.success? || err.include?("IndexError")

    %w[PLATFORM_JELLYFIN_PLATFORM PLATFORM_JELLYFIN_PORT PLATFORM_MEDIA_ROOT
       PLATFORM_DOCKER_ROOT PLATFORM_REPORT_ROOT PLATFORM_JELLYFIN_CONTAINER
       PLATFORM_JELLYFIN_AVATAR_PATH].each do |name|
      partial = environment.merge(name => nil)
      _out, err, status = Open3.capture3(partial, RbConfig.ruby, program, "seed-fixture-only")
      failures << "runtime ABI: #{name} unset was accepted" if status.success?
      failures << "runtime ABI: #{name} unset was refused without naming it: #{err.strip.inspect}" unless
        status.success? || err.include?(name)
    end
  end
  failures
end

# --- wrapper layer ---------------------------------------------------------
#
# tests/contracts/jellyfin.sh resolves both programs from its own checkout
# rather than from the tree it is inspecting, so a copy of the three files into a
# throwaway tests/contracts/ is a whole working contract. That is what lets a row
# point PLATFORM_CONTRACT_REPO_DIR at a broken fixture and still exercise the
# real wrapper.

def with_contract_copy(static: File.read(STATIC_PROGRAM), runtime: File.read(RUNTIME_PROGRAM),
                       wrapper: File.read(CONTRACT))
  Dir.mktmpdir("nas-platform-jellyfin-wrapper.") do |raw|
    root = File.realpath(raw)
    build_fixture_repository(root)
    contracts = File.join(root, "tests", "contracts")
    {
      "jellyfin.sh" => wrapper,
      "jellyfin-static.rb" => static,
      "jellyfin-runtime.rb" => runtime
    }.each do |name, content|
      destination = File.join(contracts, name)
      File.write(destination, content)
      File.chmod(name.end_with?(".sh") ? 0o755 : 0o644, destination)
    end
    yield File.join(contracts, "jellyfin.sh"), root
  end
end

def broken_fixture_repository
  Dir.mktmpdir("nas-platform-jellyfin-broken.") do |raw|
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
      { "PLATFORM_CONTRACT_REPO_DIR" => ROOT }, contract, "--platform", "nas", "static"
    )
    failures << "wrapper: static mode failed: #{(stdout + stderr).strip}" unless status.success?
    failures << "wrapper: static mode did not report the property it proved" unless
      stdout.include?("Jellyfin static contract passed (nas)")

    # The platform argument has to reach the static program, because that
    # program judges a different capability contract for each value.
    %w[mac integration].each do |platform|
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => ROOT }, contract, "--platform", platform, "static"
      )
      failures << "wrapper: --platform #{platform} failed: #{(stdout + stderr).strip}" unless
        status.success?
      failures << "wrapper: --platform #{platform} did not reach the static program" unless
        stdout.include?("Jellyfin static contract passed (#{platform})")
    end
    # ... and PLATFORM_KIND is the same argument off the environment, which is
    # how the integration lane passes it.
    stdout, _stderr, _status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => ROOT, "PLATFORM_KIND" => "integration" },
      contract, "static"
    )
    failures << "wrapper: PLATFORM_KIND did not reach the static program" unless
      stdout.include?("Jellyfin static contract passed (integration)")

    # Each of the four files the wrapper checks before it runs anything.
    {
      "roles/jellyfin/tasks/main.yml" => "roles/jellyfin/tasks/main.yml is absent",
      "roles/jellyfin/defaults/main.yml" => "roles/jellyfin/defaults/main.yml is absent",
      "services/jellyfin/compose.yml" => "services/jellyfin/compose.yml is absent",
      "roles/jellyfin/files/yonatan-avatar.jpeg" => "approved administrator avatar is absent"
    }.each do |relative, diagnostic|
      Dir.mktmpdir("nas-platform-jellyfin-preflight.") do |raw|
        incomplete = File.realpath(raw)
        build_fixture_repository(incomplete)
        FileUtils.rm(File.join(incomplete, relative))
        stdout, stderr, status = Open3.capture3(
          { "PLATFORM_CONTRACT_REPO_DIR" => incomplete }, contract, "static"
        )
        failures << "wrapper: a repository without #{relative} was accepted" if status.success?
        failures << "wrapper: a repository without #{relative} was refused without its diagnostic: " \
                    "#{(stdout + stderr).strip.inspect}" unless
          (stdout + stderr).include?("Jellyfin contract failed: #{diagnostic}")
      end
    end

    # The argument parser's own three refusals.
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => ROOT }, contract, "--platform", "solaris", "static"
    )
    failures << "wrapper: an unknown platform was accepted" if status.success?
    failures << "wrapper: an unknown platform was refused without its diagnostic" unless
      (stdout + stderr).include?("Jellyfin contract failed: unknown platform: solaris")
    [["--platform"], ["-x"]].each do |argv|
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => ROOT }, contract, *argv
      )
      failures << "wrapper: #{argv.inspect} was accepted" if status.success?
      failures << "wrapper: #{argv.inspect} did not print usage" unless
        (stdout + stderr).include?("usage: jellyfin.sh [--platform mac|nas|integration] [MODE]")
      failures << "wrapper: #{argv.inspect} did not exit 2" unless status.exitstatus == 2
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
  with_contract_copy do |contract, copy_root|
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => nil }, contract, "static"
    )
    failures << "wrapper: static mode failed with no repository named: #{(stdout + stderr).strip}" unless
      status.success?
    failures << "wrapper: static mode did not report the property it proved" unless
      stdout.include?("Jellyfin static contract passed (nas)")

    compose_service(copy_root) { |spec| spec["restart"] = "always" }
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => nil }, contract, "static"
    )
    failures << "wrapper: with no repository named, static mode inspected some other tree" if
      status.success?
    failures << "wrapper: with no repository named, static mode did not report the broken tree" unless
      (stdout + stderr).include?("restart policy differs")
  end

  # The runtime half is reached, and reached with the mode. seed-fixture-only is
  # the mode that answers without Docker; every other mode reaches the vault
  # read, which is the second row below.
  with_contract_copy(wrapper: wrapper_source) do |contract, copy_root|
    with_runtime_sandbox do |_root, environment, media|
      sandbox = environment.reject { |name, _| name == "PLATFORM_JELLYFIN_PLATFORM" }
      stdout, stderr, status = Open3.capture3(
        sandbox.merge("PLATFORM_CONTRACT_REPO_DIR" => copy_root),
        contract, "seed-fixture-only"
      )
      failures << "wrapper: seed-fixture-only failed: #{(stdout + stderr).strip}" unless
        status.success?
      failures << "wrapper: seed-fixture-only did not reach the runtime program" unless
        stdout.include?("Jellyfin video fixture prepared before deployment")
      failures << "wrapper: seed-fixture-only did not seed the fixture" unless
        File.file?(File.join(media, FIXTURE_RELATIVE))

      # A vault that cannot be read is the runtime half's first refusal, and it
      # is the proof the mode argument reached it at all: `static` would have
      # exited before this point.
      unreadable = sandbox.merge(
        "PLATFORM_CONTRACT_REPO_DIR" => copy_root,
        "PLATFORM_CONTRACT_VAULT_FILE" => File.join(media, "absent-vault.yml"),
        "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(media, "absent-password")
      )
      stdout, stderr, status = Open3.capture3(unreadable, contract, "run")
      failures << "wrapper: run mode passed with no readable vault" if status.success?
      failures << "wrapper: run mode did not reach the runtime half's vault read: " \
                  "#{(stdout + stderr).strip.inspect}" unless
        (stdout + stderr).include?("Jellyfin contract failed: encrypted vault could not be read")
    end
  end

  # The three `:?` environment refusals the wrapper makes before it execs the
  # runtime half. Each names itself, and static mode must reach none of them.
  #
  # `<NAME>: parameter` is the portable part of a POSIX `:?` diagnostic and the
  # only part this row may assert. The rest of the sentence belongs to the
  # SHELL, not to the contract: bash writes "parameter null or not set" and dash
  # writes "parameter not set or null", the same words in a different order. An
  # earlier version of this row pinned bash's order, passed on a macOS box whose
  # /bin/sh is bash, and failed CI's Ubuntu runner where /bin/sh is dash --
  # asserting which shell the machine had rather than what the contract did.
  with_contract_copy(wrapper: wrapper_source) do |contract|
    with_runtime_sandbox do |_root, environment, _media|
      %w[PLATFORM_MEDIA_ROOT PLATFORM_DOCKER_ROOT PLATFORM_REPORT_ROOT].each do |name|
        partial = environment.merge("PLATFORM_CONTRACT_REPO_DIR" => ROOT, name => nil)
        stdout, stderr, status = Open3.capture3(partial, contract, "run")
        output = stdout + stderr
        failures << "wrapper: #{name} unset was accepted" if status.success?
        failures << "wrapper: #{name} unset was refused without naming it: " \
                    "#{output.strip.inspect}" unless
          status.success? || output.include?("#{name}: parameter")
        # The substantive property the wording was standing in for, and the
        # reason the guards are `:?` rather than `:-`: an unset root must stop
        # the wrapper before it execs the runtime half, so the runtime program
        # never starts against a relative or empty path. Both sentences below
        # are the runtime half's own, so either one appearing means it ran.
        failures << "wrapper: #{name} unset still reached the runtime half: " \
                    "#{output.strip.inspect}" if
          output.include?("encrypted vault could not be read") ||
          output.include?("Jellyfin video fixture prepared before deployment")
      end
      # static mode exits before those three are demanded, which is what lets
      # tests/contract_structure_mutation_test.rb run this contract with no
      # sandbox at all.
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => ROOT }, contract, "static"
      )
      failures << "wrapper: static mode demanded the runtime environment: " \
                  "#{(stdout + stderr).strip.inspect}" unless status.success?
    end
  end

  # The programs themselves, in the direction absence cannot prove. A tree that
  # is pointed at holds a *different* program at each sibling path; running
  # either of them is the defect, and it is visible as a sentinel rather than as
  # a missing file, so it stays visible however the fixture is assembled.
  with_contract_copy(wrapper: wrapper_source) do |contract|
    Dir.mktmpdir("nas-platform-jellyfin-sentinel.") do |raw|
      inspected = File.realpath(raw)
      build_fixture_repository(inspected)
      # The static impostor can be anything: no program reads
      # jellyfin-static.rb out of the inspected tree.
      File.write(File.join(inspected, "tests", "contracts", "jellyfin-static.rb"),
                 %(warn "IMPOSTOR jellyfin-static.rb ran"\nexit 3\n))
      # The runtime impostor cannot. The static half reads that path as TEXT for
      # its six sentinels, so a stub there refuses the tree before the runtime
      # half is ever reached and the row would prove nothing about the runtime
      # program path. Keep the real bytes and prepend the sentinel instead: the
      # static half still finds every sentinel, and the warning appears if and
      # only if this copy is what got executed.
      File.write(File.join(inspected, "tests", "contracts", "jellyfin-runtime.rb"),
                 %(warn "IMPOSTOR jellyfin-runtime.rb ran"\n) + File.read(RUNTIME_PROGRAM))
      with_runtime_sandbox do |_root, environment, media|
        stdout, stderr, status = Open3.capture3(
          environment.merge("PLATFORM_CONTRACT_REPO_DIR" => inspected),
          contract, "seed-fixture-only"
        )
        output = stdout + stderr
        failures << "wrapper: a program was resolved from the inspected tree: #{output.strip.inspect}" if
          output.include?("IMPOSTOR")
        failures << "wrapper: the checkout's own programs did not run: #{output.strip.inspect}" unless
          status.success? && File.file?(File.join(media, FIXTURE_RELATIVE))
      end
    end
  end

  # PLATFORM_CONTRACT_REPO_DIR is what the static program requires
  # tests/policy_support from, and it too must name the inspected tree. An
  # inspected tree without that file has to be a LoadError naming *its* path, not
  # a silent fallback to the checkout's copy.
  with_contract_copy(wrapper: wrapper_source) do |contract|
    Dir.mktmpdir("nas-platform-jellyfin-nosupport.") do |raw|
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
  with_contract_copy(runtime: STDIN_PROBE, wrapper: wrapper_source) do |contract|
    with_runtime_sandbox do |_root, environment, _media|
      stdout, stderr, _status = Open3.capture3(
        environment.merge("PLATFORM_CONTRACT_REPO_DIR" => ROOT),
        "/bin/sh", "-c", "#{contract.shellescape} seed-fixture-only; printf 'left:'; cat",
        stdin_data: "caller-payload\n"
      )
      output = stdout + stderr
      failures << "stdin: the runtime program was handed the caller's input: #{output.strip.inspect}" unless
        output.include?('probe read ""')
    end
  end
  failures
end

# --- planted regressions ---------------------------------------------------
#
# Each entry removes one guard from one program and names the rows that must
# catch it. A row that survives its own guard being deleted is proving nothing.
# Every substitution asserts its own match count for the reason edit_text does.

PROGRAM_MUTATIONS = [
  {
    label: "the approved avatar byte check",
    program: :static,
    from: "  Digest::SHA256.file(avatar).hexdigest ==\n",
    to: "  true ||\n",
    rows: ["the approved administrator avatar bytes replaced"]
  },
  {
    label: "the platform identity check",
    program: :static,
    from: 'service.fetch("user") == "${NAS_UID:?}:${NAS_GID:?}"',
    to: "true",
    rows: ["the container running as something other than the NAS identity"]
  },
  {
    label: "the published port check",
    program: :static,
    from: 'service.fetch("ports") == ["8096:8096/tcp"]',
    to: "true",
    rows: ["the application port renumbered"]
  },
  {
    label: "the read-only media mount check",
    program: :static,
    from: 'refuse("storage contract differs") unless service.fetch("volumes") == [',
    to: 'refuse("storage contract differs") unless [] == [] || service.fetch("volumes") == [',
    rows: ["the read-only media mount made writable"]
  },
  {
    label: "the media control network check",
    program: :static,
    from: '  service.fetch("networks") == %w[default media-control] && compose.fetch("networks") == {',
    to: '  true || compose.fetch("networks") == {',
    rows: ["the shared media control network dropped"]
  },
  {
    label: "the parsed media network assignment check",
    program: :static,
    from: '  environment_assignments.select { |name, _value| name == "PLATFORM_MEDIA_NETWORK" } == [',
    to: "  true || [",
    rows: ["the media network name assignment surviving only as a comment"]
  },
  {
    label: "the restart policy check",
    program: :static,
    from: 'service.fetch("restart") == "unless-stopped"',
    to: "true",
    rows: ["a restart policy that is not unless-stopped"]
  },
  {
    label: "the render device check",
    program: :static,
    from: '  service.fetch("devices") == ["/dev/dri/renderD128:/dev/dri/renderD128"]',
    to: "  true",
    rows: ["the NAS render device dropped"]
  },
  {
    label: "the production-definition-unmodified check",
    program: :static,
    from: '  refuse("the NAS runs the production definition unmodified") if File.exist?(override_path)',
    to: "  nil if false",
    rows: ["a NAS override introduced"]
  },
  {
    label: "the explicit-tag check on an override reset",
    program: :static,
    from: "      override_text.match?(/^\\s+#{'#{key}'}: !override(\\s|$)/)",
    to: "      true",
    rows: ["the mac override resetting devices without an explicit tag"]
  },
  {
    label: "the override key allowance",
    program: :static,
    from: '  refuse("#{platform} override may not redefine #{surplus.join(\', \')}") unless surplus.empty?',
    to: "  nil unless true",
    rows: ["the mac override redefining a key outside its allowance"]
  },
  {
    # The same mutation against the image row, which the allowance is only the
    # first of two guards for: without it the row reaches the dedicated image
    # refusal, so it still refuses and the sentence is the regression. Recorded
    # as its own entry rather than folded into the row above, because the two
    # outcomes are different and a single `detects` would have to be the weaker
    # of them.
    label: "the override key allowance, ahead of the image refusal",
    program: :static,
    from: '  refuse("#{platform} override may not redefine #{surplus.join(\', \')}") unless surplus.empty?',
    to: "  nil unless true",
    rows: ["the mac override pinning an image"],
    detects: "refused for the wrong reason"
  },
  {
    label: "the published-ports override tag check",
    program: :static,
    from: "      override_text.match?(/^\\s+ports: !override(\\s|$)/)",
    to: "      true",
    rows: ["the mac override republishing ports without an explicit tag"]
  },
  {
    label: "the primary administrator check",
    program: :static,
    from: 'defaults.fetch("jellyfin_admin_username") == "Yonatan"',
    to: "true",
    rows: ["the primary administrator renamed"]
  },
  {
    label: "the managed library list check",
    program: :static,
    from: 'refuse("managed libraries differ") unless defaults.fetch("jellyfin_libraries") == [',
    to: 'refuse("managed libraries differ") unless [] == [] || defaults.fetch("jellyfin_libraries") == [',
    rows: ["a managed library repointed"]
  },
  {
    # The Collections row's cascade, recorded rather than tolerated: without the
    # exact-list check it reaches the dedicated Collections refusal instead, so
    # the row still refuses and the sentence is the regression. That refusal is
    # the one the platform actually cares about -- Collections is Jellyfin's own
    # automatic library -- so this entry is also the proof it is reachable.
    label: "the managed library list check, ahead of the Collections refusal",
    program: :static,
    from: 'refuse("managed libraries differ") unless defaults.fetch("jellyfin_libraries") == [',
    to: 'refuse("managed libraries differ") unless [] == [] || defaults.fetch("jellyfin_libraries") == [',
    rows: ["Collections declared as a managed library"],
    detects: "refused for the wrong reason"
  },
  {
    label: "the read-only metadata check",
    program: :static,
    from: '  defaults.fetch("jellyfin_library_options").fetch("SaveLocalMetadata") == false',
    to: "  true",
    rows: ["local metadata written into the read-only media mount"]
  },
  {
    # There are two `refuse("missing ...")` sweeps in the program -- the identity
    # and library one, and the settings/plugin one further down -- so the anchor
    # has to carry the `each` above it to be unique.
    label: "the required-task sweep",
    program: :static,
    from: "required_tasks.each do |name|\n  refuse(\"missing \#{name}\") unless role_names.include?(name)",
    to: "required_tasks.each do |name|\n  nil unless true",
    rows: ["a required task surviving only as a comment"]
  },
  {
    label: "the preflight-before-mutation ordering check",
    program: :static,
    from: "  preflight.none?(&:nil?) && mutations.none?(&:nil?) && preflight.max < mutations.min",
    to: "  true",
    rows: ["an identity preflight read moved after the mutations"]
  },
  {
    label: "the extra-path removal verb check",
    program: :static,
    from: '    extra_path_removal["method"] == "DELETE"',
    to: "    true",
    rows: ["the extra-path removal issuing a verb that is not DELETE"]
  },
  {
    label: "the rename recovery check",
    program: :static,
    from: '  Array(primary_rename["block"]).any? && Array(primary_rename["rescue"]).any?',
    to: "  true",
    rows: ["a primary identity rename with no recovery path"]
  },
  {
    label: "the recovery marker privacy check",
    program: :static,
    from: "    marker_conditions.any? { |that| that.include?(\"stat.mode == '0600'\") } &&",
    to: "    true &&",
    rows: ["the recovery marker read before its privacy is checked"]
  },
  {
    label: "the server configuration merge check",
    program: :static,
    from: '    server_name_update_body.include?("combine({\'ServerName\': jellyfin_server_name})")',
    to: "    true",
    rows: ["a server configuration overwrite whose merge is gone"]
  },
  {
    label: "the server configuration read check",
    program: :static,
    from: '  server_name_update_body.include?("jellyfin_server_configuration_for_update.json") &&',
    to: "  true &&",
    rows: ["a server configuration overwrite that reads nothing first"]
  },
  {
    label: "the conditional avatar upload check",
    program: :static,
    # The whole condition, because the row deletes the `when` clause outright:
    # weakening only the predicate leaves `[].any?` false and the guard still
    # refuses, which would have read as the row proving something it did not.
    from: "refuse(\"avatar upload is unconditional\") unless\n  Array(role_task.call(\"Upload the Jellyfin primary administrator image\")[\"when\"])\n" \
          "    .map(&:to_s).any? { |that| that.include?(\"jellyfin_admin_avatar_upload_required\") }",
    to: 'refuse("avatar upload is unconditional") unless true',
    rows: ["an unconditional avatar upload"]
  },
  {
    label: "the NAS encoding profile check",
    program: :static,
    from: '  defaults.dig("jellyfin_encoding_profiles", "nas") == expected_nas_encoding',
    to: "  true",
    rows: ["the NAS hardware acceleration profile weakened"]
  },
  {
    label: "the Mac CPU fallback check",
    program: :static,
    from: '  defaults.dig("jellyfin_encoding_profiles", "mac") == expected_nas_encoding.merge(',
    to: "  true || expected_nas_encoding.merge(",
    rows: ["the Mac profile claiming hardware it does not have"]
  },
  {
    label: "the managed plugin repository check",
    program: :static,
    from: 'refuse("managed plugin repositories differ") unless defaults["jellyfin_plugin_repositories"] == [',
    to: 'refuse("managed plugin repositories differ") unless [] == [] || defaults["jellyfin_plugin_repositories"] == [',
    rows: ["a managed plugin repository URL changed"]
  },
  {
    label: "the plugin package identity check",
    program: :static,
    from: 'refuse("managed plugin package identities differ") unless defaults["jellyfin_plugin_packages"] == [',
    to: 'refuse("managed plugin package identities differ") unless [] == [] || defaults["jellyfin_plugin_packages"] == [',
    rows: ["a plugin assembly identity changed"]
  },
  {
    label: "the Open Subtitles secret redaction floor",
    program: :static,
    from: "  settings.scan(/no_log: true/).length >= 5",
    to: "  true",
    rows: ["the Open Subtitles secret redaction floor lowered"]
  },
  {
    label: "the opaque database sweep",
    program: :static,
    from: "  deep_strings(role_tasks).any? { |value| value.match?(/sqlite|library\\.db|jellyfin\\.db/i) }",
    to: "  false",
    rows: ["an opaque database reference introduced into the role"]
  },
  # --- the six runtime sentinels the static half reads out of source ---------
  {
    label: "the runtime field sentinel",
    program: :static,
    from: 'refuse("fixture query does not request its runtime field") unless contract.include?(runtime_query)',
    to: "nil unless true",
    rows: ["the fixture query dropping its runtime field"]
  },
  {
    label: "the probed-metadata wait sentinel",
    program: :static,
    from: "  contract.match?(runtime_readiness)",
    to: "  true",
    rows: ["the fixture wait no longer requiring probed metadata"]
  },
  {
    label: "the synthetic-credential isolation sentinel",
    program: :static,
    from: '  contract.include?(\'VALIDATE_EXTERNAL_OPENSUBTITLES = PLATFORM != "integration"\') &&',
    to: "  true &&",
    rows: ["synthetic Open Subtitles credentials no longer isolated by platform"]
  },
  {
    label: "the guarded-validation sentinel",
    program: :static,
    from: '    contract.include?("if VALIDATE_EXTERNAL_OPENSUBTITLES\\n    _response, validation = request(")',
    to: "    true",
    rows: ["the external validation request no longer guarded"]
  },
  {
    label: "the GUID normalization sentinel",
    program: :static,
    from: '  contract.include?(\'opensubtitles.fetch("Id").delete("-").casecmp?(OPENSUBTITLES_ID.delete("-"))\')',
    to: "  true",
    rows: ["the Open Subtitles GUID comparison no longer normalizing"]
  },
  {
    # The assertion #147 repointed. Restoring the old path is the exact
    # regression the repoint exists to prevent: the wrapper is 102 lines now and
    # holds none of the six sentinels, so the first of them would refuse every
    # repository forever -- and the fixture carries no wrapper at all, so it is
    # an Errno instead. Either way the intact-repository rows report it.
    label: "the runtime self-read pointed back at the wrapper",
    program: :static,
    from: 'contract = File.read(File.join(root, "tests", "contracts", "jellyfin-runtime.rb"))',
    to: 'contract = File.read(File.join(root, "tests", "contracts", "jellyfin.sh"))',
    rows: ["an intact repository"],
    detects: "expected success"
  },
  # --- the runtime half -----------------------------------------------------
  {
    label: "the fixture symlink refusal",
    program: :runtime,
    from: '  fail_contract("fixture path is a symlink") if FIXTURE_PATH.symlink?',
    to: "  nil if false",
    rows: ["a fixture path that is a symlink is refused"],
    # A symlink pointing at other bytes is refused by the byte comparison one
    # line down, so removing the symlink guard changes the sentence rather than
    # the outcome. That the guard is still worth having is the point: a symlink
    # pointing at a byte-identical copy would be accepted, and the platform
    # would then be reading a file it does not own.
    detects: "refused for the wrong reason"
  },
  {
    label: "the fixture byte comparison",
    program: :runtime,
    from: "      FIXTURE_PATH.file? && FIXTURE_PATH.binread == VIDEO_FIXTURE",
    to: "      true",
    rows: ["a fixture whose bytes drifted is refused"]
  },
  {
    # 0o600 rather than a wider mode, because the umask masks the widening ones
    # back to 0o644 and the mutation would plant nothing -- the silent-no-op
    # hazard, in a place a match count cannot see.
    label: "the fixture's create mode",
    program: :runtime,
    from: "    FIXTURE_PATH.open(File::WRONLY | File::CREAT | File::EXCL, 0o644) do |file|",
    to: "    FIXTURE_PATH.open(File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|",
    rows: ["an absent fixture is seeded"],
    detects: "that 0o644 masks to"
  }
].freeze

def plant(source, mutation)
  from = mutation.fetch(:from)
  occurrences = source.scan(from).length
  abort "self-test: #{mutation.fetch(:label)} matched #{occurrences} times, expected 1" unless
    occurrences == 1

  source.sub(from, mutation.fetch(:to))
end

def with_mutant(mutation)
  canonical = mutation.fetch(:program) == :static ? STATIC_PROGRAM : RUNTIME_PROGRAM
  Dir.mktmpdir("nas-platform-jellyfin-mutant.") do |directory|
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

ALL_STATIC_ROWS = (STATIC_ROWS + SELF_READ_ROWS).freeze

if ARGV.include?("--self-test")
  in_parallel_cases(PROGRAM_MUTATIONS) do |mutation|
    with_mutant(mutation) do |mutant|
      rows = mutation.fetch(:program) == :static ? ALL_STATIC_ROWS : RUNTIME_ROWS
      named = rows_named(rows, mutation.fetch(:rows))
      caught = if mutation.fetch(:program) == :static
                 static_rows = named.select { |row| STATIC_ROWS.include?(row) }
                 self_rows = named - static_rows
                 (static_rows.empty? ? [] : static_failures(mutant, static_rows)) +
                   (self_rows.empty? ? [] : self_read_failures(mutant, self_rows))
               else
                 runtime_failures(mutant, named)
               end
      abort "self-test failed: removing #{mutation.fetch(:label)} was accepted" if caught.empty?
      # "was accepted" is the row's own wording for a mutant that let a broken
      # repository through, which is the default expectation. `detects:` names a
      # different wording where a mutation cascades into another assertion, and
      # is documentation of a recorded cascade rather than an escape hatch.
      detects = mutation.fetch(:detects, "was accepted")
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
    ["  \"$repo_dir\" \"$platform\" </dev/null\n", "  \"$repo_dir\" \"$platform\"\n"],
    ["  \"$mode\" \"$@\" </dev/null\n", "  \"$mode\" \"$@\"\n"]
  ].each do |from, to|
    pristine = File.read(CONTRACT)
    abort "self-test could not plant a dropped stdin redirect: #{from.inspect}" unless
      pristine.scan(from).length == 1

    leaked = stdin_failures(wrapper_source: pristine.sub(from, to))
    abort "self-test failed: a dropped stdin redirect was accepted" if leaked.empty?
    planted_redirects += 1
  end

  # The three `:?` guards, one at a time. `:-` in place of `:?` is the realistic
  # weakening -- it leaves the variable unset instead of refusing -- and it is
  # what proves those rows can still fail now that they no longer pin a shell's
  # choice of words. Without this the portable assertion could have gone
  # vacuously true and nothing would have said so.
  planted_guards = 0
  %w[PLATFORM_MEDIA_ROOT PLATFORM_DOCKER_ROOT PLATFORM_REPORT_ROOT].each do |name|
    pristine = File.read(CONTRACT)
    from = %(: "${#{name}:?}"\n)
    abort "self-test could not plant a dropped :? guard for #{name}" unless
      pristine.scan(from).length == 1

    caught = wrapper_failures(wrapper_source: pristine.sub(from, %(: "${#{name}:-}"\n)))
    abort "self-test failed: a dropped :? guard for #{name} was accepted" if caught.empty?
    planted_guards += 1
  end

  # The defect #251 shipped one version of and #259 found a second site for:
  # resolving a program from the tree being inspected rather than from the
  # script's own checkout, and the inverse -- rebinding to the checkout something
  # that names the inspected tree on purpose. Jellyfin has three sites, and only
  # the first two move.
  planted_roots = 0
  [
    ['ruby -ryaml -rdigest "$contract_repo_dir/tests/contracts/jellyfin-static.rb"',
     'ruby -ryaml -rdigest "$repo_dir/tests/contracts/jellyfin-static.rb"'],
    ['exec ruby "$contract_repo_dir/tests/contracts/jellyfin-runtime.rb"',
     'exec ruby "$repo_dir/tests/contracts/jellyfin-runtime.rb"'],
    ["PLATFORM_CONTRACT_REPO_DIR=$repo_dir\n", "PLATFORM_CONTRACT_REPO_DIR=$contract_repo_dir\n"]
  ].each do |from, to|
    pristine = File.read(CONTRACT)
    abort "self-test could not plant a misrooted program: #{from.inspect}" unless
      pristine.scan(from).length == 1

    caught = wrapper_failures(wrapper_source: pristine.sub(from, to))
    abort "self-test failed: #{from.strip.inspect} rerooted to the wrong tree was accepted" if
      caught.empty?
    planted_roots += 1
  end

  # The static half's own self-read root, which is Ruby rather than shell and so
  # is planted in the program instead of the wrapper. It must stay bound to the
  # inspected tree; binding it to the checkout is the inverse defect.
  misrooted_self_read = File.read(STATIC_PROGRAM).sub(
    'contract = File.read(File.join(root, "tests", "contracts", "jellyfin-runtime.rb"))',
    'contract = File.read(File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), ' \
    '"tests", "contracts", "jellyfin-runtime.rb"))'
  )
  planted_self_reads = 0
  Dir.mktmpdir("nas-platform-jellyfin-selfmutant.") do |directory|
    path = File.join(directory, "jellyfin-static.rb")
    File.write(path, misrooted_self_read)
    # PLATFORM_CONTRACT_REPO_DIR and `root` are the same tree in every real
    # invocation, so the rebinding has to be exercised with them deliberately
    # apart: the tree under inspection is poisoned and the one policy_support
    # comes from is not.
    Dir.mktmpdir("nas-platform-jellyfin-selfmutant-tree.") do |raw|
      inspected = File.realpath(raw)
      build_fixture_repository(inspected)
      edit_text(inspected, "tests/contracts/jellyfin-runtime.rb",
                "fields=Path,MediaSources,RunTimeTicks", "fields=Path")
      _stdout, stderr, status = run_static(path, inspected, "nas", contract_repo_dir: ROOT)
      abort "self-test failed: the self-read rebound to PLATFORM_CONTRACT_REPO_DIR " \
            "still refused the poisoned inspected tree" unless
        status.success? || !stderr.include?("fixture query does not request its runtime field")
      planted_self_reads += 1
    end
  end

  puts "jellyfin contract: self-test detects " \
       "#{PROGRAM_MUTATIONS.length + planted_redirects + planted_guards + planted_roots + planted_self_reads} " \
       "planted regressions"
  exit
end

failures = static_failures + self_read_failures + self_read_root_failures +
           runtime_failures + runtime_abi_failures + wrapper_failures + stdin_failures
unless failures.empty?
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Jellyfin contract violation(s)"
end

puts "jellyfin contract: #{STATIC_ROWS.length} static, #{SELF_READ_ROWS.length} runtime-source " \
     "and #{RUNTIME_ROWS.length} runtime properties hold, and the wrapper reaches both programs " \
     "with an empty stdin"
