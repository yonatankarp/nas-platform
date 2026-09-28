#!/usr/bin/env ruby
# A file this platform renders into a container's state tree must be openable by
# the container that reads it (#548). Docker Desktop does not enforce bind-mount
# ownership, so only a Linux host sees this defect. The subject is derived from
# the Compose files (non-root containers only), and this is a file of its own so
# policy mutations do not drift tests/policy_manifest_test.rb's declared sets.

# Explicitly: permitted_classes names Date, which some psych versions do not load.
require "date"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

require_relative "policy_support"

include TestScaffold

# Overridable so --self-test can run against a planted copy of the tree.
ROOT = ENV.fetch("PLATFORM_RENDERED_OWNERSHIP_ROOT", File.expand_path("..", __dir__))

# The platform identity reaches a container directly as `user:` or via a
# root entrypoint re-executing as PUID/PGID; both count.
PLATFORM_IDENTITY = "${NAS_UID:?}:${NAS_GID:?}"
PLATFORM_UID_ENVIRONMENT = "${NAS_UID:?}"

# Pinned both ways so a derived subject list cannot quietly empty. vaultwarden
# (#547) is listed but renders nothing into its state tree.
EXPECTED_IDENTITY_SERVICES = %w[
  arr audiobookshelf bindery downloaders dozzle jellyfin kapowarr komga
  paperless-ngx pinchflat seerr trailarr vaultwarden
].freeze
IDENTITY_FLOOR = 13
# Exact floor, counted off this sweep's summary line; only the self-test's
# negative-control row lowers it, by exactly the subject it removed.
SUBJECT_FLOOR = Integer(ENV.fetch("PLATFORM_RENDERED_OWNERSHIP_SUBJECT_FLOOR", "5"))

WRITING_MODULES = %w[ansible.builtin.template ansible.builtin.copy].freeze

# --- self-test ---------------------------------------------------------------
# Each row plants one defect in a throwaway tree and requires the sweep to name
# it (or stay silent, for the negative control). roles/trailarr renders exactly
# one restricted file; services/vaultwarden's identity is a single `user:` key.
SELF_TEST_TREES = %w[services roles].freeze

SELF_TEST_ROWS = [
  {
    name: "the defect this file exists for: a rendered configuration with no owner",
    plant: lambda { |root|
      path = File.join(root, "roles/trailarr/tasks/reconcile_env.yml")
      source = File.read(path)
      File.write(path, source.sub(/^    owner: "\{\{ nas_uid \}\}"\n    group: "\{\{ nas_gid \}\}"\n/, ""))
    },
    expects: "declares neither owner nor group"
  },
  {
    name: "an owner declared without a group",
    plant: lambda { |root|
      path = File.join(root, "roles/trailarr/tasks/reconcile_env.yml")
      source = File.read(path)
      File.write(path, source.sub(/^    group: "\{\{ nas_gid \}\}"\n/, ""))
    },
    expects: '["owner"]'
  },
  {
    name: "a stack that stopped running under the platform identity",
    plant: lambda { |root|
      path = File.join(root, "services/vaultwarden/compose.yml")
      source = File.read(path)
      File.write(path, source.sub(/^    user: .*\n/, ""))
    },
    expects: "no longer reads as running a container under the shared numeric identity"
  },
  {
    # #596, planted in a file that contributes no subject, so the count and floor
    # stay satisfied and only the parse refusal can catch it.
    name: "a task file that could not be parsed, whose contribution was zero",
    plant: lambda { |root|
      path = File.join(root, "roles/trailarr/tasks/reconcile_connections.yml")
      File.write(path, "#{File.read(path)}\n- bad: \"unclosed\n")
    },
    expects: '["roles/trailarr/tasks/reconcile_connections.yml"] could not be parsed'
  },
  {
    # The negative control: a world-readable file needs no owner.
    name: "a world-readable file, which needs no owner and must not be reported",
    plant: lambda { |root|
      path = File.join(root, "roles/trailarr/tasks/reconcile_env.yml")
      source = File.read(path)
      source = source.sub(/^    owner: "\{\{ nas_uid \}\}"\n    group: "\{\{ nas_gid \}\}"\n/, "")
      # Anchored on the destination, so a second restricted file cannot make this
      # row widen the wrong task.
      File.write(path, source.sub(%r{(trailarr_config_host_path \}\}/\.env"\n    mode: )"0600"}, '\\1"0644"'))
    },
    subject_floor: (SUBJECT_FLOOR - 1).to_s,
    expects: nil
  }
].freeze

if ARGV.include?("--self-test")
  program = File.expand_path(__FILE__)
  repository = File.expand_path("..", __dir__)
  self_test_failures = []
  SELF_TEST_ROWS.each do |row|
    Dir.mktmpdir("nas-platform-rendered-ownership.") do |raw|
      sandbox = File.realpath(raw)
      SELF_TEST_TREES.each { |tree| FileUtils.cp_r(File.join(repository, tree), sandbox) }
      row.fetch(:plant).call(sandbox)
      environment = { "PLATFORM_RENDERED_OWNERSHIP_ROOT" => sandbox }
      floor = row[:subject_floor]
      environment["PLATFORM_RENDERED_OWNERSHIP_SUBJECT_FLOOR"] = floor if floor
      stdout, stderr, status = Open3.capture3(environment, RbConfig.ruby, program)
      output = stdout + stderr
      if row.fetch(:expects).nil?
        self_test_failures << "#{row.fetch(:name)}: was reported anyway: #{output.strip}" unless
          status.success?
        next
      end
      if status.success?
        self_test_failures << "#{row.fetch(:name)}: was accepted"
        next
      end
      self_test_failures << "#{row.fetch(:name)}: refused for the wrong reason: #{output.strip}" unless
        output.include?(row.fetch(:expects))
    end
  end

  unless self_test_failures.empty?
    self_test_failures.each { |failure| warn "FAIL #{failure}" }
    abort "#{self_test_failures.length} rendered file ownership self-test failure(s)"
  end
  puts "rendered file ownership: self-test detects #{SELF_TEST_ROWS.count { |row| row.fetch(:expects) }} " \
       "planted defects and leaves a world-readable file alone"
  exit
end

failures = []

manifest = begin
  YAML.safe_load_file(File.join(ROOT, "services", "manifest.yml"))
rescue Errno::ENOENT, Psych::Exception
  nil
end
entries = manifest.is_a?(Hash) && manifest["services"].is_a?(Array) ? manifest["services"] : []
roles = entries.each_with_object({}) do |entry, collected|
  next unless entry.is_a?(Hash) && entry["name"].is_a?(String) && entry["role"].is_a?(String)

  collected[entry["name"]] = entry["role"]
end
implemented = PolicySupport.implemented_services(ROOT)

def compose_containers(root, service)
  document = YAML.safe_load_file(File.join(root, "services", service, "compose.yml"), aliases: true)
  document.is_a?(Hash) && document["services"].is_a?(Hash) ? document["services"] : {}
rescue Errno::ENOENT, Psych::Exception
  {}
end

# Each env name's right-hand side from env.j2, Jinja whitespace normalised.
def env_assignments(root, role)
  template = File.join(root, "roles", role, "templates", "env.j2")
  return {} unless File.file?(template)

  File.readlines(template, chomp: true).each_with_object({}) do |line, collected|
    name, value = line.split("=", 2)
    next unless name.to_s.match?(/\A[A-Z][A-Z0-9_]*\z/) && value

    collected[name] = value.gsub(/\{\{\s*(.*?)\s*\}\}/) { "{{ #{Regexp.last_match(1)} }}" }
  end
end

# A container the platform identity reaches: numeric `user:`, or a uid variable
# (PUID, USERMAP_UID, USER_ID, ...) derived by asking env.j2 whether the value is
# rendered from nas_uid rather than by listing spellings.
def identity_container?(spec, assignments)
  return false unless spec.is_a?(Hash)
  return true if spec["user"].to_s == PLATFORM_IDENTITY
  return false unless spec["environment"].is_a?(Hash)

  spec["environment"].each_value.any? do |value|
    name = value.to_s[/\A\$\{([A-Z0-9_]+)/, 1]
    name && assignments.fetch(name, "").include?("nas_uid")
  end
end

# The host paths identity containers bind-mount, compared as PREFIXES: a file
# inside a mounted directory, not one merely sharing a variable with it.
def mounted_paths(root, service, role)
  assignments = env_assignments(root, role)
  compose_containers(root, service).flat_map do |_name, spec|
    next [] unless identity_container?(spec, assignments)

    Array(spec["volumes"]).filter_map do |mount|
      name = mount.to_s.split(":").first.to_s[/\A\$\{([A-Z0-9_]+)/, 1]
      name && assignments[name]
    end
  end.uniq
end

identity_services = implemented.select do |service|
  role = roles[service]
  next false if role.nil?

  assignments = env_assignments(ROOT, role)
  compose_containers(ROOT, service).any? { |_name, spec| identity_container?(spec, assignments) }
end
check_floor(failures, identity_services.length, IDENTITY_FLOOR,
            "services running a container under the platform identity")
missing = EXPECTED_IDENTITY_SERVICES - identity_services
check(failures, missing.empty?,
      "#{missing.inspect} no longer reads as running a container under the shared numeric " \
      "identity. Either the `user:` key moved or this sweep's selector stopped matching it, and " \
      "both make every property below hold vacuously for that service")
unexpected = identity_services - EXPECTED_IDENTITY_SERVICES
check(failures, unexpected.empty?,
      "#{unexpected.inspect} now runs a container as the shared numeric identity and is not in " \
      "this sweep's pinned list. A stack that stops running as root is in scope for the rule " \
      "below the moment it does; add it here rather than leaving it unswept")

# A mode denying read to `other`. An unparseable mode is a subject, not skipped.
def restricted_mode?(mode)
  text = mode.to_s.strip
  return true unless text.match?(/\A0?[0-7]{3,4}\z/)

  (Integer(text, 8) & 0o004).zero?
end

subjects = 0
# A task file that could not be parsed is not one that writes nothing (#596):
# its paths are recorded and refused, whatever the subject count.
unreadable_task_files = []
identity_services.sort.each do |service|
  role = roles[service]
  next if role.nil?

  mounted = mounted_paths(ROOT, service, role)
  next if mounted.empty?

  Dir[File.join(ROOT, "roles", role, "tasks", "**", "*.yml")].sort.each do |path|
    document = begin
      YAML.safe_load_file(path, aliases: true, permitted_classes: [Date, Time])
    rescue Psych::Exception
      unreadable_task_files << path.delete_prefix("#{ROOT}/")
      nil
    end
    # An empty stage file loads as nil and legitimately declares nothing.
    next unless document.is_a?(Array)

    relative = path.delete_prefix("#{ROOT}/")
    PolicySupport.flatten_tasks(document).each do |task|
      WRITING_MODULES.each do |module_name|
        options = task[module_name]
        next unless options.is_a?(Hash)

        destination = options["dest"].to_s
        next if destination.empty?
        normalized = destination.gsub(/\{\{\s*(.*?)\s*\}\}/) { "{{ #{Regexp.last_match(1)} }}" }
        next unless mounted.any? { |path| normalized.start_with?(path) }
        next unless options.key?("mode") && restricted_mode?(options["mode"])

        subjects += 1
        declared = %w[owner group].select { |key| options.key?(key) }
        next if declared.length == 2

        check(failures, false,
              "#{relative}: \"#{task['name'] || 'an unnamed task'}\" writes #{destination} at " \
              "mode #{options['mode'].inspect}, which denies read to anyone but the owner and " \
              "the group, and declares #{declared.empty? ? 'neither owner nor group' : declared.inspect}. " \
              "#{service} runs a container as #{PLATFORM_IDENTITY}, so on Linux that container " \
              "cannot open the file and dies before its health check ever runs. Declare " \
              "owner: \"{{ nas_uid }}\" and group: \"{{ nas_gid }}\" -- Docker Desktop for Mac " \
              "does not enforce bind-mount ownership, so no amount of local converging will show " \
              "you this")
      end
    end
  end
end
check(failures, unreadable_task_files.uniq.empty?,
      "#{unreadable_task_files.uniq.sort.inspect} could not be parsed, so nothing in it was " \
      "swept for a restricted-mode write and the count below is over the files that survived " \
      "rather than over the roles. A file that renders nothing at 0600 and a file nothing could " \
      "be read from are different states, and only the first is a reason to assert nothing. Fix " \
      "the file and re-run: SUBJECT_FLOOR guards the loss of a counted subject, not the loss of " \
      "a file whose contribution was zero before it acquired a violation")
check_floor(failures, subjects, SUBJECT_FLOOR,
            "restricted-mode files rendered into the state trees of numeric-identity services")

report(failures,
       "rendered file ownership: #{subjects} restricted-mode files across " \
       "#{identity_services.length} services that run a container under the platform identity " \
       "are all owned by it",
       "rendered file ownership violation(s)")
