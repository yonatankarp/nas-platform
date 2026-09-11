#!/usr/bin/env ruby
# frozen_string_literal: true

# Two properties about the release a role reads, and the second exists because
# the first forced a deferral.
#
# THE DEFECT (#547). A role that reads a file under platform_current_dir is
# reading the INSTALLED release. Activating a new release is a command task, so
# check mode skips it -- roles/deployment_bundle/tasks/target.yml relaxes its own
# release requirement for exactly that reason -- and `current` therefore still
# names the PREVIOUS release during a review. For a service this platform has
# never converged, that release has no services/<name>/ at all, and the read
# dies on a file that is simply not there.
#
# Found by an operator running `--check --diff` against the real NAS, which is
# the reading CI structurally cannot do: the integration lane runs its check
# phase after two live converges, so the release is always assembled by then.
# The run died at task 1366 of an otherwise complete review with
# `File not found: /volume1/Docker/nas-platform/current/services/vaultwarden/compose.yml`.
#
# THE WINDOW IS NARROW AND REAL. It opens when a new service's release is merged
# and closes at that release's first live converge -- once per service, on the
# one review an operator is told to run before applying anything. That is also
# why the four readers in UNGUARDED_RELEASE_READS below have never triggered it:
# every release currently on the NAS already carries arr, bindery and the two
# shared roles' subjects, so their reads always find something.
#
# WHY A LEDGER RATHER THAN A RULE. Requiring every one of those four to be
# guarded would fail the gate on four roles this change does not touch, for a
# latent defect none of them has yet hit. A check that cries wolf gets deleted,
# which is worse than no check. So the unguarded set is pinned exactly, in both
# directions: a fifth appearing fails, and one of these being fixed without
# updating the list fails too. It is a ledger of known latent readers rather
# than a clean bill of health, and it is what a future change that decides to
# fix them will edit.

require "yaml"

require_relative "policy_support"

include PolicySupport
include TestScaffold

ROOT = ENV.fetch("PLATFORM_RELEASE_READ_ROOT", File.expand_path("..", __dir__))

# Modules that OPEN the path and therefore fail when it is absent. `stat` is
# deliberately not among them: reporting `exists: false` is the whole point of
# it, and it is what a guarded read is guarded by.
RELEASE_READERS = {
  "ansible.builtin.slurp" => %w[path src],
  "ansible.builtin.include_vars" => %w[file]
}.freeze

# Every unguarded read of the installed release that exists today, by file. Each
# is latent rather than broken: the services these reach are in every release
# the NAS has, so the read always finds its file. Fixing one means giving it the
# stat-and-three-states shape roles/vaultwarden/tasks/deploy.yml now carries, and
# removing its line here.
UNGUARDED_RELEASE_READS = [
  "roles/arr/tasks/configarr.yml",
  "roles/bindery/tasks/pre_upgrade_backup.yml",
  "roles/container_cpu/tasks/inspect.yml",
  "roles/image_downgrade_guard/tasks/main.yml",
  # #567 added a slurp of the deployed Immich compose.yml, to derive the
  # restore preflight's expected versions from the pins rather than from a
  # literal that goes stale on the next image bump. It is latent for the same
  # reason as the four above and no other: Immich is in every release this NAS
  # has, so the read always finds its file. The window the header describes --
  # a new service's first review before its first live converge -- closed for
  # Immich long ago. Fixing it means the stat-and-three-states shape
  # roles/vaultwarden/tasks/deploy.yml carries, and removing this line.
  "roles/immich/tasks/main.yml"
].freeze

# The reads that must STAY guarded. Stated rather than derived, because "no
# unguarded reads appeared" is satisfied just as well by the read being deleted.
GUARDED_RELEASE_READS = [
  "roles/vaultwarden/tasks/deploy.yml",
  "roles/vaultwarden/tasks/verify.yml"
].freeze

# The keys that must never reach a deployed Vaultwarden, checked here in the
# repository as well as on the target.
#
# THIS IS THE HALF THAT COVERS THE DEFERRAL. roles/vaultwarden sweeps the
# INSTALLED release for these and, on a review where the release is not there to
# read, now reports instead of sweeping. That is a real narrowing of the runtime
# guard, so the same property is asserted here against the repository -- which
# is always readable, runs on every pull request, and stops the keys reaching a
# release at all. The two are complementary rather than duplicated: this one
# cannot see what is actually installed on a target, and the runtime one cannot
# run before the release exists.
#
# ADMIN_TOKEN puts a login on /admin; DISABLE_ADMIN_TOKEN opens the panel with
# no login at all -- measured against the pinned image at 140 KB of live
# unauthenticated panel -- and a service-level env_file could carry either where
# neither guard would see it. Anything saved in that panel writes a config.json
# that outranks every value the role renders.
FORBIDDEN_COMPOSE_KEYS = %w[ADMIN_TOKEN DISABLE_ADMIN_TOKEN].freeze
VAULTWARDEN_COMPOSE_GLOB = File.join("services", "vaultwarden", "compose*.yml")

def release_reads(root)
  Dir[File.join(root, "roles", "*", "tasks", "**", "*.yml")].sort.flat_map do |path|
    document = begin
      YAML.safe_load_file(path, aliases: true)
    rescue Psych::Exception
      nil
    end
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

        # Guarded means an earlier task in the same file stats the same path, so
        # the read can be skipped when it is absent. Same file, because that is
        # where the fix belongs and a stat two files away proves nothing about
        # the order they run in.
        guarded = stats.any? { |(stat_index, stat_path)| stat_index < index && stat_path == target }
        { "file" => relative, "name" => task["name"].to_s, "guarded" => guarded }
      end
    end
  end
end

# Compose accepts `environment:` as a mapping or as a sequence of NAME=VALUE
# strings, and the platform overrides carry Compose's own `!override` tag, which
# from_yaml refuses. Both are handled exactly as roles/vaultwarden does, so the
# two guards cannot disagree about what a document declares.
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
  reads = release_reads(root)
  problems = []
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
  # The third direction, and the one both lists were open in until it was
  # planted: a guarded read simply dropped from the pin left every comparison
  # above satisfied and reported success. It is the same hole
  # CREDENTIAL_FREE_SERVICES had -- a set difference in one direction says
  # nothing about a name that left the set entirely.
  (guarded - GUARDED_RELEASE_READS).each do |file|
    problems << "#{file} stats the release path before opening it, which is the shape this check " \
                "exists to keep, but it is named in neither list. Add it to " \
                "GUARDED_RELEASE_READS so removing that guard later is a red check rather than a " \
                "silent regression -- and if it was moved off UNGUARDED_RELEASE_READS, take it " \
                "out of there in the same edit"
  end
  # A derivation that found nothing satisfies every comparison above. The number
  # is today's real count rather than a comfortable floor, for the reason
  # tests/deployment_gate_coverage_test.rb states about its own: a floor below
  # the truth buys nothing.
  expected_reads = UNGUARDED_RELEASE_READS.length + GUARDED_RELEASE_READS.length
  if reads.map { |read| read.fetch("file") }.uniq.length < expected_reads
    problems << "the sweep found #{reads.length} reads of platform_current_dir across " \
                "#{reads.map { |read| read.fetch('file') }.uniq.length} files and the two lists " \
                "name #{expected_reads}; the derivation is broken rather than the roles"
  end
  problems + forbidden_key_problems(root)
end

# --- self-test ---------------------------------------------------------------
#
# Folded into every run: the sweep is static and costs under a second, and a
# guard that proves itself on every run is one fewer manifest line to keep true.
# Each plant is a defect a reader could plausibly introduce, with the property it
# must break.
PLANTS = [
  # The stat and the slurp name the same path today; this points the stat
  # somewhere else, which is how the guard drifts apart in practice rather than
  # by anyone deleting it. String#sub takes the first occurrence, and the stat
  # is the earlier of the two.
  { "name" => "the deploy sweep's stat drifts off the path it guards",
    "file" => "roles/vaultwarden/tasks/deploy.yml",
    "from" => "  ansible.builtin.stat:\n    path: >-\n" \
              "      {{ platform_current_dir }}/services/vaultwarden/{{ item }}\n",
    "to" => "  ansible.builtin.stat:\n    path: >-\n" \
            "      {{ platform_current_dir }}/services/vaultwarden/elsewhere\n",
    "expect" => "no longer stats the release path" },
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
