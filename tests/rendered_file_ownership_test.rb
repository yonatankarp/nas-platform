#!/usr/bin/env ruby
# A file this platform renders into a container's state tree must be openable by
# the container that reads it.
#
# THE HOLE THIS CLOSES (#548). roles/adguard rendered AdGuardHome.yaml at mode
# 0600 and declared no owner, so the file belonged to whichever account ran
# Ansible -- root inside the CI controller container. The container runs as
# ${NAS_UID}:${NAS_GID}, could not open its own configuration, and exited
# immediately with `failed to parse configuration file err="open ...: permission
# denied"`. Docker reported `restarting exit=1` with an EMPTY health log,
# because a process that dies before it serves never reaches its health check.
#
# #577 REMOVED THAT SERVICE AND THIS FILE STAYS, which is the whole reason it was
# written as a sweep over every role rather than as a line in the adguard
# contract. AdGuard turned out to be the only role missing a convention arr,
# downloaders, pinchflat and trailarr already followed, so what this guards is
# the next service added and not the one that exposed it. Its self-test rows
# moved with the removal -- they are planted into roles/trailarr and
# services/vaultwarden now -- because a self-test whose plants no longer apply
# is a clean report that means nothing.
#
# THE REASON NOTHING LOCAL SAW IT, and the reason this is a sweep rather than a
# line in a contract: **Docker Desktop for Mac does not enforce bind-mount
# ownership.** Every uid inside a container reads every bind-mounted file there,
# so the property this file asserts does not exist on the machine most of this
# repository is written on. It exists on the NAS and on a CI runner. An
# empirical proof -- converge, converge again, read the diff -- cannot find this
# defect on a Mac however carefully it is run, which is exactly what happened:
# the image was started successfully here half a dozen times, idempotence was
# demonstrated byte for byte, and the lane still refused the container.
#
# WHY THE SUBJECT IS DERIVED AND NOT LISTED. The rule only bites where the
# container is NOT root, so the subject is every service whose Compose file gives
# a container the shared numeric identity. roles/beszel is the counter-example
# that proves it: it writes a 0600 keypair with no owner and is correct, because
# its hub container runs as root and therefore owns what Ansible wrote. Deriving
# the subject from the Compose files rather than naming it means beszel drops out
# by being root instead of by being excused, and a service that later gains a
# `user:` key is in scope the moment it does.
#
# WHY A FILE OF ITS OWN rather than a section of one of the eight scripts in
# POLICY_SCRIPTS: the same reason tests/container_health_wiring_test.rb and
# tests/deployment_gate_coverage_test.rb state for themselves. This reads
# services/manifest.yml, every services/*/compose.yml and every roles/*/tasks
# tree, and tests/policy_mutation_support.rb plants defects into several of
# those. Inside one of the eight, every such mutation would newly be detected by
# that script, the per-site declared sets in tests/policy_manifest_test.rb would
# drift, and `--audit` would fail. Outside them it cannot happen.
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

require_relative "policy_support"

include TestScaffold

# Overridable so that --self-test below can run this same program against a
# planted copy of the tree, which is what CLAUDE.md means by showing a checker
# a real defect before trusting its clean report.
ROOT = ENV.fetch("PLATFORM_RENDERED_OWNERSHIP_ROOT", File.expand_path("..", __dir__))

# The two ways the platform identity reaches a container, and both count. A
# service either takes it directly as a numeric `user:`, or -- the linuxserver.io
# family -- starts as root and re-executes as PUID/PGID through s6 or gosu. The
# second is not a weaker case: the process that finally opens the file is the
# unprivileged one either way, which is why roles/arr, roles/downloaders and
# roles/trailarr all declare owner on files their PUID containers read.
PLATFORM_IDENTITY = "${NAS_UID:?}:${NAS_GID:?}"
PLATFORM_UID_ENVIRONMENT = "${NAS_UID:?}"

# The stacks that run at least one container under the platform identity, pinned
# in both directions rather than only counted. A derived subject list that
# quietly empties passes every property below vacuously, and a floor alone cannot
# tell "Komga was removed" from "Komga stopped matching the selector".
#
# vaultwarden (#547) is on the list and contributes no subject, which is the
# state this list has to be able to express. Its container takes the platform
# identity directly, so it is in scope by the rule above; it simply renders
# nothing into its own state tree -- the only file the role writes is the
# runtime .env, and that is Compose's `--env-file`, read by the Docker CLI on
# the host rather than by anything inside the container. Being listed is what
# makes that a checked fact rather than an assumption, and what puts the role in
# scope the moment it does render into /data.
EXPECTED_IDENTITY_SERVICES = %w[
  arr audiobookshelf bindery downloaders dozzle jellyfin kapowarr komga
  ntfy paperless-ngx pinchflat seerr trailarr vaultwarden
].freeze
IDENTITY_FLOOR = 14
# Every rendered file the rule reaches today, counted off this sweep's own
# summary line rather than reasoned about. Held as a floor for the same reason
# every other list here is: a selector that stops matching reports success. It
# stood at 4 against a live 6 until #577 re-derived it, which is exactly the
# staleness a `>=` floor cannot report.
#
# Overridable for the same reason ROOT above is, and only by the self-test: the
# negative-control row widens one subject's mode, so the planted tree really
# does hold one subject fewer and an exact floor would fail that row for a
# reason that has nothing to do with what it asserts. The row lowers the floor
# by exactly the subject it removed rather than the floor being left slack for
# everybody -- slack is what let this number sit two below the tree. Derived
# from the constant rather than restated, so adding a subject cannot leave a
# second number behind that nothing bumps.
SUBJECT_FLOOR = Integer(ENV.fetch("PLATFORM_RENDERED_OWNERSHIP_SUBJECT_FLOOR", "5"))

WRITING_MODULES = %w[ansible.builtin.template ansible.builtin.copy].freeze

# --- self-test ---------------------------------------------------------------
#
# Each row plants exactly one thing in a throwaway copy of the tree and requires
# this sweep to name it -- or, for the negative control, to stay silent. The
# first row is the defect that actually broke the adguard integration lane,
# replanted into roles/trailarr once #577 removed the role it was found in, so
# this file's clean report means something rather than being asserted.
#
# WHY TWO SUBJECTS RATHER THAN ONE. Rows 1, 2 and 4 need a role that renders a
# restricted-mode file into a path one of its own identity containers mounts,
# and roles/trailarr is the cleanest: its reconcile_env.yml writes exactly one
# such file, so each substitution below is unambiguous. Row 3 needs a stack
# whose whole identity is one `user:` key, so that removing that key really does
# drop the service out of the selector -- services/trailarr takes the identity
# through PUID/PGID and services/dozzle declares `user:` on two containers, so
# neither would; services/vaultwarden is one container with one key and is the
# stack the pinned list above already explains carries no subject of its own.
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
    # The negative control, and the reason the mode test is not decoration: a
    # world-readable file needs no owner, because any uid can open it. Without
    # this row the sweep could be demanding ownership of everything and its
    # passing rows would say nothing about the condition it claims to apply.
    name: "a world-readable file, which needs no owner and must not be reported",
    plant: lambda { |root|
      path = File.join(root, "roles/trailarr/tasks/reconcile_env.yml")
      source = File.read(path)
      source = source.sub(/^    owner: "\{\{ nas_uid \}\}"\n    group: "\{\{ nas_gid \}\}"\n/, "")
      # Anchored on the destination rather than on the mode alone. The role
      # renders one restricted file today, so a bare substitution would be
      # correct by luck; anchoring means a second one arriving does not silently
      # widen the wrong task and make this row report the defect it removed.
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

# The right-hand side each environment name is rendered from, out of the role's
# own env.j2, with the whitespace inside a Jinja expression normalised so that
# two hand-written spellings of the same path compare equal.
def env_assignments(root, role)
  template = File.join(root, "roles", role, "templates", "env.j2")
  return {} unless File.file?(template)

  File.readlines(template, chomp: true).each_with_object({}) do |line, collected|
    name, value = line.split("=", 2)
    next unless name.to_s.match?(/\A[A-Z][A-Z0-9_]*\z/) && value

    collected[name] = value.gsub(/\{\{\s*(.*?)\s*\}\}/) { "{{ #{Regexp.last_match(1)} }}" }
  end
end

# A container the platform identity reaches, and both routes count. A service
# either takes it directly as a numeric `user:`, or -- the linuxserver.io family
# and Paperless -- starts as root and re-executes as the uid it was handed under
# a name of its own: PUID, USERMAP_UID, USER_ID. The second is not the weaker
# case, because the process that finally opens the file is the unprivileged one
# either way.
#
# That name is DERIVED rather than listed. Chasing spellings is how a list goes
# quietly out of date, so this asks the role's own env.j2 whether the value the
# container interpolates is rendered from nas_uid, which is true of every
# spelling at once and of the next one nobody has invented yet.
def identity_container?(spec, assignments)
  return false unless spec.is_a?(Hash)
  return true if spec["user"].to_s == PLATFORM_IDENTITY
  return false unless spec["environment"].is_a?(Hash)

  spec["environment"].each_value.any? do |value|
    name = value.to_s[/\A\$\{([A-Z0-9_]+)/, 1]
    name && assignments.fetch(name, "").include?("nas_uid")
  end
end

# The bind-mount sources of those containers, as the environment names Compose
# interpolates. This is what turns "a file the role renders" into "a file a
# container can actually see": a path no identity container mounts is a path no
# such container reads, whoever owns it.
# The host paths those containers bind-mount, as the path expressions env.j2
# renders. Compared as PREFIXES rather than by the variable they mention, which
# is the difference between "a file inside a mounted directory" and "a file that
# merely shares a variable with one": roles/arr mounts
# {{ platform_runtime_dir }}/services/arr/configarr-secrets.yml and renders its
# .env one directory up, and a variable-name comparison cannot tell those apart.
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

# A mode that denies read to `other`. Such a file is openable by its owner and
# its group and by nobody else, which is the whole of the hazard: a container
# running as an arbitrary uid is neither, unless Ansible was told to make it one.
# An unparseable mode is treated as a subject rather than skipped, because an
# unreadable declaration is exactly where this defect could hide next.
def restricted_mode?(mode)
  text = mode.to_s.strip
  return true unless text.match?(/\A0?[0-7]{3,4}\z/)

  (Integer(text, 8) & 0o004).zero?
end

subjects = 0
identity_services.sort.each do |service|
  role = roles[service]
  next if role.nil?

  mounted = mounted_paths(ROOT, service, role)
  next if mounted.empty?

  Dir[File.join(ROOT, "roles", role, "tasks", "**", "*.yml")].sort.each do |path|
    document = begin
      YAML.safe_load_file(path, aliases: true)
    rescue Psych::Exception
      nil
    end
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
check_floor(failures, subjects, SUBJECT_FLOOR,
            "restricted-mode files rendered into the state trees of numeric-identity services")

report(failures,
       "rendered file ownership: #{subjects} restricted-mode files across " \
       "#{identity_services.length} services that run a container under the platform identity " \
       "are all owned by it",
       "rendered file ownership violation(s)")
