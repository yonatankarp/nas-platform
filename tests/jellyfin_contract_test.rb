#!/usr/bin/env ruby
# frozen_string_literal: true

# Behaviour of the Jellyfin contract's two programs (jellyfin-static.rb and
# jellyfin-runtime.rb) and their wrapper, in four layers: static rows pinning
# exact diagnostics per platform, the Docker-free seed-fixture-only runtime mode,
# wrapper rows, and self-read rows for the runtime sentinels the static half
# reads from source. --self-test plants regressions and proves the rows detect them.

require "digest"
require "fileutils"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"
require "yaml"
require_relative "case_pool_support"
require_relative "contract_test_support"

include ContractTestSupport

ROOT = File.expand_path("..", __dir__)
CONTRACT = File.join(ROOT, "tests", "contracts", "jellyfin.sh")
STATIC_PROGRAM = File.join(ROOT, "tests", "contracts", "jellyfin-static.rb")
RUNTIME_PROGRAM = File.join(ROOT, "tests", "contracts", "jellyfin-runtime.rb")

# The static program needs yaml and digest preloaded, as the wrapper does.
STATIC_COMMAND = [RbConfig.ruby, "-ryaml", "-rdigest"].freeze

# Exactly what the two halves read out of the inspected tree, the runtime source
# included (the static half's sentinels read it).
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

# Deliberately absent: jellyfin.sh and jellyfin-static.rb. Carrying them would
# shadow #251 (a sibling resolved from $repo_dir).

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

# Every substitution asserts its match count, so a no-op plant cannot pass (#263).
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

# Finds a task by name anywhere in the role, so rows survive stage splits.
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
# One row per assertion family, not per refuse() site. The mac and integration
# rows exist because only the override branch differs by platform.

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
    # A scalar: Compose accepts it, but the check must be a real command list.
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
    # Compose appends sequences, so only the !override tag replaces the device;
    # hence the assertion reads the override's TEXT.
    name: "the mac override resetting devices without an explicit tag",
    platform: "mac",
    break: lambda { |root|
      edit_text(root, "services/jellyfin/compose.mac.yml", "devices: !override", "devices:")
    },
    expects: "mac override must reset devices with an explicit tag"
  },
  {
    # Mac-override rows edit TEXT: re-dumping YAML drops the !override tags.
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
    expects: "mac override may not redefine image"
  },
  {
    # Only the mac override republishes a port.
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
    # Collections is Jellyfin's own automatic library; declaring it fights the app.
    name: "Collections declared as a managed library",
    break: lambda { |root|
      edit_yaml(root, "roles/jellyfin/defaults/main.yml", aliases: false) do |document|
        document.fetch("jellyfin_libraries") <<
          { "name" => "Collections", "collection_type" => "boxsets", "path" => "/media/Collections" }
      end
    },
    # The exact-list assertion fires first; a self-test covers the dedicated refusal.
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
    name: "date added taken from the file timestamp",
    break: lambda { |root|
      edit_yaml(root, "roles/jellyfin/defaults/main.yml", aliases: false) do |document|
        document.fetch("jellyfin_metadata_configuration")["UseFileCreationTimeForDateAdded"] = true
      end
    },
    expects: "date added must be the scan time, not the file timestamp"
  },
  {
    # A task name surviving only inside a comment is not a task.
    name: "a required task surviving only as a comment",
    break: lambda { |root|
      rename_role_task(root, "Verify exact Jellyfin owned state",
                       "Verify exact Jellyfin owned state, renamed")
    },
    expects: "missing Verify exact Jellyfin owned state"
  },
  {
    # Moved, not renamed, so only the ordering check can refuse it.
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
    # The merge remains, so only the read clause can refuse this.
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
    # The read remains and only the merge is gone: a POST would replace the whole
    # configuration with one key.
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
    # A source-text count: no_log has no observable in a static contract.
    name: "the Open Subtitles secret redaction floor lowered",
    break: lambda { |root|
      # Floor five, file carries 39: every one must go. The count is stated so a
      # drifted fixture breaks the row rather than no-ops.
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
  },
  # Where the QSV proof runs, and that it can fail (#535). The first row rebuilds
  # the pre-fix tree, where deploy.yml included the probe.
  {
    name: "the QSV proof restored to the convergence path",
    break: lambda { |root|
      edit_text(root, "roles/jellyfin/tasks/deploy.yml",
                "# The container health check passes as soon as /health answers",
                "- name: Prove Jellyfin QSV during convergence\n" \
                "  ansible.builtin.include_tasks: qsv_probe.yml\n\n" \
                "# The container health check passes as soon as /health answers")
    },
    expects: "QSV proof runs during convergence"
  },
  {
    name: "the QSV proof dropped from verification",
    break: lambda { |root|
      edit_text(root, "roles/jellyfin/tasks/verify.yml", "    file: qsv_probe.yml\n",
                "    file: scheduled_tasks.yml\n")
    },
    expects: "QSV proof is not included exactly once from verification"
  },
  {
    # `never` alone runs when any carried tag (the role's jellyfin tag) is requested.
    name: "the QSV proof's converge tag gate dropped",
    break: lambda { |root|
      edit_text(root, "roles/jellyfin/tasks/verify.yml",
                "  tags: [never, platform_verify_jellyfin]\n  ansible.builtin.include_tasks:",
                "  tags: [platform_verify_jellyfin]\n  ansible.builtin.include_tasks:")
    },
    expects: "QSV proof is not withheld from the converge by tag"
  },
  {
    name: "the QSV proof's run-tag gate dropped",
    break: lambda { |root|
      edit_text(root, "roles/jellyfin/tasks/verify.yml",
                "    - \"'platform_verify_jellyfin' in ansible_run_tags\"\n", "")
    },
    expects: "QSV proof is not withheld from the converge by run tag"
  },
  {
    name: "the QSV proof tolerating a nonzero exit",
    break: lambda { |root|
      edit_text(root, "roles/jellyfin/tasks/qsv_probe.yml",
                "  failed_when: jellyfin_qsv_probe.rc | default(1) | int != 0",
                "  failed_when: false")
    },
    expects: "QSV proof tolerates a nonzero exit"
  },
  {
    # default(0) would read a module refusal (no rc) as a passing probe.
    name: "the QSV proof defaulting an absent exit code to success",
    break: lambda { |root|
      edit_text(root, "roles/jellyfin/tasks/qsv_probe.yml",
                "  failed_when: jellyfin_qsv_probe.rc | default(1) | int != 0",
                "  failed_when: jellyfin_qsv_probe.rc | default(0) | int != 0")
    },
    expects: "QSV proof tolerates a nonzero exit"
  }
].freeze

# Requires tests/policy_support.rb from the inspected tree, not the checkout.
def run_static(program, root, platform, contract_repo_dir: root)
  Open3.capture3(
    { "PLATFORM_CONTRACT_REPO_DIR" => contract_repo_dir },
    *STATIC_COMMAND, program, root, platform
  )
end

def static_failures(program = STATIC_PROGRAM, rows = STATIC_ROWS)
  in_parallel_case_results(rows) do |row|
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
# The sentinels the static half reads from the runtime SOURCE; each row plants
# the defect in the inspected tree's copy. `was_vacuous` rows could not fail
# before #147, when both halves shared one file.
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

# The sixth sentinel has no row, deliberately: its literal also matches the def's
# own signature, so it is vacuous. Anchoring it to a call site is the fix, and
# belongs to its own change.

def self_read_failures(program = STATIC_PROGRAM, rows = SELF_READ_ROWS)
  in_parallel_case_results(rows) do |row|
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

# The source is read from the INSPECTED tree: breaking the checkout's copy must
# change nothing, breaking the inspected copy must refuse.
def self_read_root_failures(program = STATIC_PROGRAM)
  failures = []
  Dir.mktmpdir("nas-platform-jellyfin-selfroot.") do |raw|
    root = File.realpath(raw)
    build_fixture_repository(root)
    # A sentinel only the inspected copy has; refusal proves which tree was read.
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
# seed-fixture-only runs seed_fixture and exits before the vault read; the
# fixture's refusals are what tests/integration.sh depends on.

# What the runtime derives when PLATFORM_JELLYFIN_MEDIA_ROOT is unset.
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

      # 0o644 masked by the process umask, which belongs to the environment; under
      # umask 0o077 the self-test aborts loudly with "was accepted".
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
      # Seeded by a first run, so the bytes are the program's own.
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
  in_parallel_case_results(rows) do |row|
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

# The runtime argv/env ABI: a missing PLATFORM_* is a named KeyError, and the
# mode comes off ARGV[0].
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
# The wrapper resolves both programs from its own checkout, so a copy of the
# three files into a throwaway tests/contracts/ is a whole working contract.

def with_contract_copy(static: File.read(STATIC_PROGRAM), runtime: File.read(RUNTIME_PROGRAM),
                       wrapper: File.read(CONTRACT), &block)
  with_contract_sandbox("jellyfin", wrapper, { "static" => static, "runtime" => runtime }, &block)
end

def broken_fixture_repository
  Dir.mktmpdir("nas-platform-jellyfin-broken.") do |raw|
    root = File.realpath(raw)
    build_fixture_repository(root)
    compose_service(root) { |spec| spec["restart"] = "always" }
    yield root
  end
end

def wrapper_static_mode_failures(contract, failures)
  stdout, stderr, status = Open3.capture3(
    { "PLATFORM_CONTRACT_REPO_DIR" => ROOT }, contract, "--platform", "nas", "static"
  )
  failures << "wrapper: static mode failed: #{(stdout + stderr).strip}" unless status.success?
  failures << "wrapper: static mode did not report the property it proved" unless
    stdout.include?("Jellyfin static contract passed (nas)")

  # The platform argument must reach the static program.
  %w[mac integration].each do |platform|
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => ROOT }, contract, "--platform", platform, "static"
    )
    failures << "wrapper: --platform #{platform} failed: #{(stdout + stderr).strip}" unless
      status.success?
    failures << "wrapper: --platform #{platform} did not reach the static program" unless
      stdout.include?("Jellyfin static contract passed (#{platform})")
  end
  # PLATFORM_KIND is the same argument off the environment (the integration lane).
  stdout, _stderr, _status = Open3.capture3(
    { "PLATFORM_CONTRACT_REPO_DIR" => ROOT, "PLATFORM_KIND" => "integration" },
    contract, "static"
  )
  failures << "wrapper: PLATFORM_KIND did not reach the static program" unless
    stdout.include?("Jellyfin static contract passed (integration)")
end

def wrapper_refusal_failures(contract, failures)
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
end

def wrapper_inspected_tree_failures(contract, copy_root, failures)
  # The inspected tree is broken, the wrapper's own checkout is not.
  broken_fixture_repository do |broken|
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => broken }, contract, "static"
    )
    failures << "wrapper: static mode passed against a broken repository" if status.success?
    failures << "wrapper: static mode did not report the broken repository" unless
      (stdout + stderr).include?("restart policy differs")
  end

  # Breaking the copy's compose.yml while pointing at this repository changes nothing.
  compose_service(copy_root) { |spec| spec["restart"] = "always" }
  stdout, stderr, status = Open3.capture3(
    { "PLATFORM_CONTRACT_REPO_DIR" => ROOT }, contract, "static"
  )
  failures << "wrapper: a broken checkout was read instead of the named tree: " \
              "#{(stdout + stderr).strip}" unless status.success?
end

# The branch every deployment takes: PLATFORM_CONTRACT_REPO_DIR unset.
def wrapper_default_repository_failures(failures)
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
end

# The runtime half is reached with the mode; seed-fixture-only needs no Docker.
def wrapper_runtime_mode_failures(wrapper_source, failures)
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

      # The vault refusal proves the mode reached the runtime half; `static` exits
      # earlier.
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
end

# The three `:?` refusals, each named; static mode reaches none. Only
# `<NAME>: parameter` is asserted: bash and dash word the rest differently.
def wrapper_environment_failures(wrapper_source, failures)
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
        # `:?`, not `:-`: an unset root must stop the wrapper before the runtime
        # half starts against an empty path.
        failures << "wrapper: #{name} unset still reached the runtime half: " \
                    "#{output.strip.inspect}" if
          output.include?("encrypted vault could not be read") ||
          output.include?("Jellyfin video fixture prepared before deployment")
      end
      # Static mode needs none of them, so it runs without a sandbox.
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => ROOT }, contract, "static"
      )
      failures << "wrapper: static mode demanded the runtime environment: " \
                  "#{(stdout + stderr).strip.inspect}" unless status.success?
    end
  end
end

# Impostor programs at each sibling path of the inspected tree: running one is
# the defect, visible as a sentinel.
def wrapper_sentinel_failures(wrapper_source, failures)
  with_contract_copy(wrapper: wrapper_source) do |contract|
    Dir.mktmpdir("nas-platform-jellyfin-sentinel.") do |raw|
      inspected = File.realpath(raw)
      build_fixture_repository(inspected)
      # No program reads jellyfin-static.rb out of the inspected tree.
      File.write(File.join(inspected, "tests", "contracts", "jellyfin-static.rb"),
                 %(warn "IMPOSTOR jellyfin-static.rb ran"\nexit 3\n))
      # The static half reads this path as text for its sentinels, so keep the
      # real bytes and prepend the sentinel.
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
end

# policy_support must come from the inspected tree: its absence is a LoadError
# naming that path, not a fallback to the checkout.
def wrapper_policy_support_failures(wrapper_source, failures)
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
end

def wrapper_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(wrapper: wrapper_source) do |contract, copy_root|
    wrapper_static_mode_failures(contract, failures)
    wrapper_refusal_failures(contract, failures)
    wrapper_inspected_tree_failures(contract, copy_root, failures)
  end
  wrapper_default_repository_failures(failures)
  wrapper_runtime_mode_failures(wrapper_source, failures)
  wrapper_environment_failures(wrapper_source, failures)
  wrapper_sentinel_failures(wrapper_source, failures)
  wrapper_policy_support_failures(wrapper_source, failures)
  failures
end

# Neither real program reads stdin, so the redirect is observable only here.
def stdin_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  # The static invocation, which runs for every mode.
  with_contract_copy(static: STDIN_PROBE, wrapper: wrapper_source) do |contract|
    failures.concat(stdin_probe_failures(contract, %w[static], { "PLATFORM_CONTRACT_REPO_DIR" => ROOT },
                                         subject: "the static program"))
  end

  # The runtime invocation is `exec`ed, so its redirect needs its own row.
  with_contract_copy(runtime: STDIN_PROBE, wrapper: wrapper_source) do |contract|
    with_runtime_sandbox do |_root, environment, _media|
      failures.concat(stdin_probe_failures(contract, %w[seed-fixture-only],
                                           environment.merge("PLATFORM_CONTRACT_REPO_DIR" => ROOT),
                                           subject: "the runtime program", status: false))
    end
  end
  failures
end

# --- planted regressions ---------------------------------------------------
# Each entry removes one guard and names the rows that must catch it.

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
    # Without the allowance the image row reaches the dedicated image refusal;
    # the changed sentence is the regression.
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
    # The cascade reaches the dedicated Collections refusal, which also proves
    # that refusal is reachable.
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
    label: "the scan-time date added check",
    program: :static,
    from: '  defaults.dig("jellyfin_metadata_configuration", "UseFileCreationTimeForDateAdded") == false',
    to: "  true",
    rows: ["date added taken from the file timestamp"]
  },
  {
    # Two `refuse("missing ...")` sweeps exist, so the anchor carries its `each`.
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
    # The whole condition: weakening only the predicate leaves `[].any?` false.
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
    # The #147 repoint: restoring the wrapper path refuses every repository.
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
    # The byte comparison also refuses, so only the sentence changes; the guard
    # still matters for a symlink to a byte-identical copy.
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
    # 0o600: the umask would mask a widening mode back to 0o644, planting nothing.
    label: "the fixture's create mode",
    program: :runtime,
    from: "    FIXTURE_PATH.open(File::WRONLY | File::CREAT | File::EXCL, 0o644) do |file|",
    to: "    FIXTURE_PATH.open(File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|",
    rows: ["an absent fixture is seeded"],
    detects: "that 0o644 masks to"
  }
].freeze

def with_mutant(mutation)
  canonical = mutation.fetch(:program) == :static ? STATIC_PROGRAM : RUNTIME_PROGRAM
  Dir.mktmpdir("nas-platform-jellyfin-mutant.") do |directory|
    path = File.join(directory, File.basename(canonical))
    File.write(path, plant(File.read(canonical), mutation))
    yield path
  end
end

ALL_STATIC_ROWS = (STATIC_ROWS + SELF_READ_ROWS).freeze

if ARGV.include?("--self-test")
  in_parallel_case_results(PROGRAM_MUTATIONS) do |mutation|
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
      # `detects:` documents a recorded cascade; it is not an escape hatch.
      detects = mutation.fetch(:detects, "was accepted")
      unless caught.all? { |failure| failure.include?(detects) }
        abort "self-test failed: removing #{mutation.fetch(:label)} was caught by the wrong " \
              "assertion: #{caught.join(' | ')}"
      end
    end
    []
  end

  # Neither real program reads stdin, so dropping `</dev/null` needs a program
  # that does. The third drains the caller's stdin before the runtime exec.
  planted_redirects = 0
  [
    ["  \"$repo_dir\" \"$platform\" </dev/null\n", "  \"$repo_dir\" \"$platform\"\n"],
    ["  \"$mode\" \"$@\" </dev/null\n", "  \"$mode\" \"$@\"\n"],
    ["\nexec ruby ", "\ncat >/dev/null\nexec ruby "]
  ].each do |from, to|
    pristine = File.read(CONTRACT)
    abort "self-test could not plant a dropped stdin redirect: #{from.inspect}" unless
      pristine.scan(from).length == 1

    leaked = stdin_failures(wrapper_source: pristine.sub(from, to))
    abort "self-test failed: a dropped stdin redirect was accepted" if leaked.empty?
    planted_redirects += 1
  end

  # `:-` for `:?` is the realistic weakening; proves the portable rows can fail.
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

  # #251/#259: resolving a program from the inspected tree, and the inverse.
  # Three sites; only the first two move.
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

  # The static half's self-read root must stay bound to the inspected tree.
  misrooted_self_read = File.read(STATIC_PROGRAM).sub(
    'contract = File.read(File.join(root, "tests", "contracts", "jellyfin-runtime.rb"))',
    'contract = File.read(File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), ' \
    '"tests", "contracts", "jellyfin-runtime.rb"))'
  )
  planted_self_reads = 0
  Dir.mktmpdir("nas-platform-jellyfin-selfmutant.") do |directory|
    path = File.join(directory, "jellyfin-static.rb")
    File.write(path, misrooted_self_read)
    # The two trees are the same in real runs, so keep them apart deliberately.
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
