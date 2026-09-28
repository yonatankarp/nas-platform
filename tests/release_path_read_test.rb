#!/usr/bin/env ruby
# frozen_string_literal: true

# Reads of the installed release (platform_current_dir): under --check `current`
# still names the previous release, which lacks a never-converged service (#547).
# Unguarded readers are pinned as a ledger both ways; the fixed ones must stay guarded.

# Explicitly: permitted_classes names Date, and the CI runner's psych does not load it.
require "date"
require "yaml"

require_relative "policy_support"

include PolicySupport
include TestScaffold

ROOT = ENV.fetch("PLATFORM_RELEASE_READ_ROOT", File.expand_path("..", __dir__))

# Modules that OPEN the path. `stat` is not among them: it is what guards a read.
RELEASE_READERS = {
  "ansible.builtin.slurp" => %w[path src],
  "ansible.builtin.include_vars" => %w[file]
}.freeze

# Latent unguarded reads, by file. Fixing one means the stat-and-three-states shape
# of roles/vaultwarden/tasks/deploy.yml and removing its line here.
UNGUARDED_RELEASE_READS = [
  "roles/arr/tasks/configarr.yml",
  "roles/bindery/tasks/pre_upgrade_backup.yml",
  "roles/container_cpu/tasks/inspect.yml",
  "roles/image_downgrade_guard/tasks/main.yml",
  # Reads the candidate through a lookup under --check (#858).
  "roles/pre_upgrade_backup/tasks/pending.yml"
].freeze

# The reads that must STAY guarded. Stated rather than derived, because "no
# unguarded reads appeared" is satisfied just as well by the read being deleted.
GUARDED_RELEASE_READS = [
  "roles/audiobookshelf/tasks/settings.yml",
  "roles/vaultwarden/tasks/deploy.yml",
  "roles/vaultwarden/tasks/verify.yml"
].freeze

# Keys that must never reach a deployed Vaultwarden, checked in the repository
# because the runtime sweep reports instead of sweeping when the release is absent.
# Either key opens or exposes /admin, whose config.json outranks the rendered .env.
FORBIDDEN_COMPOSE_KEYS = %w[ADMIN_TOKEN DISABLE_ADMIN_TOKEN].freeze
VAULTWARDEN_COMPOSE_GLOB = File.join("services", "vaultwarden", "compose*.yml")

# An unparseable task file is reported through +unreadable+, not skipped: the
# expected_reads floor cannot see an unparseable file acquiring a new read (#596).
def release_reads(root, unreadable)
  Dir[File.join(root, "roles", "*", "tasks", "**", "*.yml")].sort.flat_map do |path|
    document = begin
      YAML.safe_load_file(path, aliases: true, permitted_classes: [Date, Time])
    rescue Psych::Exception
      unreadable << path.delete_prefix("#{root}/")
      nil
    end
    # Something other than a list of tasks is a file with nothing here to read,
    # not a file that could not be read: an empty stage file loads as nil.
    next [] unless document.is_a?(Array)

    relative = path.delete_prefix("#{root}/")
    tasks = flatten_tasks(document)
    stats = tasks.each_with_index.filter_map do |task, index|
      options = task["ansible.builtin.stat"]
      [index, options["path"].to_s.gsub(/\s+/, " ").strip] if options.is_a?(Hash)
    end
    tasks.each_with_index.flat_map do |task, index|
      RELEASE_READERS.filter_map do |module_name, keys|
        options = task[module_name]
        next unless options.is_a?(Hash)

        target = keys.filter_map { |key| options[key] }.first.to_s.gsub(/\s+/, " ").strip
        next unless target.include?("platform_current_dir")

        # Guarded means an earlier task in the same file stats the same path; a stat
        # in another file proves nothing about run order.
        guarded = stats.any? { |(stat_index, stat_path)| stat_index < index && stat_path == target }
        { "file" => relative, "name" => task["name"].to_s, "guarded" => guarded }
      end
    end
  end
end

# Compose `environment:` may be a mapping or NAME=VALUE list, and overrides carry
# `!override`, which from_yaml refuses. Handled as roles/vaultwarden does.
def declared_keys(source)
  document = YAML.safe_load(source.gsub(" !override", "").gsub(" !reset", ""), aliases: true)
  services = document.is_a?(Hash) && document["services"].is_a?(Hash) ? document["services"].values : []
  services.select { |service| service.is_a?(Hash) }.flat_map do |service|
    environment = service["environment"]
    names = case environment
            when Hash then environment.keys
            when Array then environment.map { |entry| entry.to_s.split("=", 2).first }
            else []
            end
    names + (service.key?("env_file") ? ["env_file"] : [])
  end.map(&:to_s)
end

def forbidden_key_problems(root)
  paths = Dir[File.join(root, VAULTWARDEN_COMPOSE_GLOB)].sort
  problems = []
  if paths.empty?
    problems << "no #{VAULTWARDEN_COMPOSE_GLOB} was found, so this check has no subject and " \
                "would pass having read nothing"
    return problems
  end
  paths.each do |path|
    relative = path.delete_prefix("#{root}/")
    keys = begin
      declared_keys(File.read(path))
    rescue Psych::Exception => error
      problems << "#{relative} could not be parsed: #{error.message.lines.first.to_s.strip}"
      next
    end
    offending = keys.select do |key|
      FORBIDDEN_COMPOSE_KEYS.any? { |forbidden| key.casecmp?(forbidden) } || key == "env_file"
    end
    next if offending.empty?

    problems << "#{relative} declares #{offending.uniq.join(', ')}. ADMIN_TOKEN puts a login on " \
                "/admin and DISABLE_ADMIN_TOKEN opens the panel with no login at all, and a " \
                "service-level env_file could carry either unseen. Anything saved in that panel " \
                "writes a config.json that outranks every value roles/vaultwarden renders"
  end
  problems
end

def sweep_problems(root = ROOT)
  unreadable = []
  reads = release_reads(root, unreadable)
  problems = []
  unreadable.uniq.sort.each do |file|
    problems << "#{file} could not be parsed, so it was swept for nothing and every statement " \
                "below about which files read the installed release excludes it. A role task " \
                "file with no release read in it and a role task file nothing could be read " \
                "from are different states, and only the first is a reason to assert nothing. " \
                "The two ledgers cannot report this: they name the reads that must be there, " \
                "not the arrival of an unguarded one in a file this sweep could not open"
  end
  unguarded = reads.reject { |read| read.fetch("guarded") }.map { |read| read.fetch("file") }.uniq.sort
  guarded = reads.select { |read| read.fetch("guarded") }.map { |read| read.fetch("file") }.uniq.sort

  (unguarded - UNGUARDED_RELEASE_READS).each do |file|
    problems << "#{file} opens a path under platform_current_dir with no earlier stat of it. " \
                "Under --check the release is not installed, so `current` names the previous one " \
                "and the read fails on a service that release does not carry. Stat the path " \
                "first and distinguish three states the way roles/vaultwarden/tasks/deploy.yml " \
                "does: present sweeps, absent under check mode reports, absent on a live run " \
                "fails. If this read is knowingly left latent, add it to " \
                "UNGUARDED_RELEASE_READS with the reason"
  end
  (UNGUARDED_RELEASE_READS - unguarded).each do |file|
    problems << "#{file} is listed in UNGUARDED_RELEASE_READS but no longer reads the installed " \
                "release without a stat. If it was fixed, take the line out; a ledger entry that " \
                "outlives its subject hides the next reader that takes its place"
  end
  (GUARDED_RELEASE_READS - guarded).each do |file|
    problems << "#{file} no longer stats the release path before opening it, so the guard #547 " \
                "added has been removed or the stat and the read have drifted apart. The review " \
                "path is what breaks, and no lane can see it"
  end
  # The third direction: a guarded read dropped from the pin satisfies both
  # one-way differences above.
  (guarded - GUARDED_RELEASE_READS).each do |file|
    problems << "#{file} stats the release path before opening it, which is the shape this check " \
                "exists to keep, but it is named in neither list. Add it to " \
                "GUARDED_RELEASE_READS so removing that guard later is a red check rather than a " \
                "silent regression -- and if it was moved off UNGUARDED_RELEASE_READS, take it " \
                "out of there in the same edit"
  end
  # An empty derivation satisfies every comparison above; the count is exact.
  expected_reads = UNGUARDED_RELEASE_READS.length + GUARDED_RELEASE_READS.length
  if reads.map { |read| read.fetch("file") }.uniq.length < expected_reads
    problems << "the sweep found #{reads.length} reads of platform_current_dir across " \
                "#{reads.map { |read| read.fetch('file') }.uniq.length} files and the two lists " \
                "name #{expected_reads}; the derivation is broken rather than the roles"
  end
  problems + forbidden_key_problems(root)
end

# --- self-test ---------------------------------------------------------------
# Folded into every run; each plant is a plausible defect with the property it breaks.
PLANTS = [
  # String#sub takes the first occurrence, and the stat is the earlier of the two.
  { "name" => "the deploy sweep's stat drifts off the path it guards",
    "file" => "roles/vaultwarden/tasks/deploy.yml",
    "from" => "  ansible.builtin.stat:\n    path: >-\n" \
              "      {{ platform_current_dir }}/services/vaultwarden/{{ item }}\n",
    "to" => "  ansible.builtin.stat:\n    path: >-\n" \
            "      {{ platform_current_dir }}/services/vaultwarden/elsewhere\n",
    "expect" => "no longer stats the release path" },
  # Planted in a file with no release read (#596), so the ledgers and the
  # expected_reads floor stay satisfied and only the parse refusal can fail it.
  { "name" => "a role task file that could not be parsed at all",
    "file" => "roles/trailarr/tasks/reconcile_connections.yml",
    "from" => "---\n# A connection is the only part",
    "to" => "---\n- bad: \"unclosed\n# A connection is the only part",
    "expect" => "roles/trailarr/tasks/reconcile_connections.yml could not be parsed" },
  { "name" => "a forbidden key reaches the canonical compose file",
    "file" => "services/vaultwarden/compose.yml",
    "from" => "      DATA_FOLDER: /data\n",
    "to" => "      DATA_FOLDER: /data\n      DISABLE_ADMIN_TOKEN: \"true\"\n",
    "expect" => "opens the panel with no login" },
  { "name" => "a forbidden key reaches an override in Compose's sequence form",
    "file" => "services/vaultwarden/compose.mac.yml",
    "from" => "    ports: !override\n",
    "to" => "    environment:\n      - ADMIN_TOKEN=secret\n    ports: !override\n",
    "expect" => "ADMIN_TOKEN" }
].freeze

def self_test_problems
  require "fileutils"
  require "tmpdir"
  source_root = ROOT
  problems = []
  PLANTS.each do |plant|
    original = File.read(File.join(source_root, plant.fetch("file")))
    unless original.include?(plant.fetch("from"))
      problems << "the plant #{plant.fetch('name').inspect} no longer matches " \
                  "#{plant.fetch('file')}; re-anchor it rather than deleting it"
      next
    end
    Dir.mktmpdir("nas-platform-release-path-") do |directory|
      %w[roles services].each { |tree| FileUtils.cp_r(File.join(source_root, tree), directory) }
      File.write(File.join(directory, plant.fetch("file")),
                 original.sub(plant.fetch("from"), plant.fetch("to")), mode: "w", perm: 0o600)
      detected = sweep_problems(directory).any? { |problem| problem.include?(plant.fetch("expect")) }
      next if detected

      problems << "planting #{plant.fetch('name').inspect} was not detected, so this check " \
                  "reports clean without being able to find the defect it was written for"
    end
  end
  problems
end

failures = []
sweep_problems.each { |problem| check(failures, false, problem) }
self_test_problems.each { |problem| failures << problem }

report(failures,
       "release path reads: #{GUARDED_RELEASE_READS.length} guarded and " \
       "#{UNGUARDED_RELEASE_READS.length} known-latent reads of the installed release, no " \
       "forbidden key in any Vaultwarden Compose file, and #{PLANTS.length} planted defects " \
       "detected",
       "release path read violation(s)")
