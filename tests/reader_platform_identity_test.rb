#!/usr/bin/env ruby
# The reader services (Audiobookshelf, Jellyfin, Komga) must run as the
# platform identity, not a literal 1000:100: renders use a uid/gid the repo never
# mentions. Media stays NAS-owned and read-only; only state dirs match the identity.

require "json"
require "open3"
require "yaml"

require_relative "nas_storage_support"
require_relative "policy_support"

include TestScaffold

# Not 1000:100 and not equal to each other, so a uid/gid swap is caught.
PROOF_UID = "4242"
PROOF_GID = "4343"

READERS = {
  "audiobookshelf" => {
    "role" => "audiobookshelf",
    "media_target" => "/audiobooks",
    "state_paths" => [
      "{{ nas_docker_root }}/audiobookshelf/config",
      "{{ nas_docker_root }}/audiobookshelf/metadata",
      "{{ nas_docker_root }}/audiobookshelf/backups"
    ],
    "environment" => {
      "TZ" => "UTC",
      "PLATFORM_CONTAINER_CPUSET" => "0",
      "PLATFORM_MEDIA_NETWORK" => "fixture-media",
      "PLATFORM_PROJECT_NAME" => "fixture",
      "PLATFORM_DOCKER_ROOT" => "/tmp/fixture-docker",
      "AUDIOBOOKSHELF_HOST_PORT" => "13378",
      "AUDIOBOOKSHELF_CONFIG_PATH" => "/tmp/fixture-audiobookshelf-config",
      "AUDIOBOOKSHELF_METADATA_PATH" => "/tmp/fixture-audiobookshelf-metadata",
      "AUDIOBOOKSHELF_MEDIA_PATH" => "/tmp/fixture-audiobooks",
      "AUDIOBOOKSHELF_BACKUP_PATH" => "/tmp/fixture-audiobookshelf-backups"
    }
  },
  "jellyfin" => {
    "role" => "jellyfin",
    "media_target" => "/media",
    "state_paths" => [
      "{{ nas_docker_root }}/jellyfin/config",
      "{{ nas_docker_root }}/jellyfin/cache"
    ],
    "environment" => {
      "TZ" => "UTC",
      "PLATFORM_CONTAINER_CPUSET" => "0",
      "PLATFORM_MEDIA_NETWORK" => "fixture-media",
      "PLATFORM_PROJECT_NAME" => "fixture",
      "JELLYFIN_HOST_PORT" => "8096",
      "JELLYFIN_CONFIG_PATH" => "/tmp/fixture-jellyfin-config",
      "JELLYFIN_CACHE_PATH" => "/tmp/fixture-jellyfin-cache",
      "JELLYFIN_MEDIA_PATH" => "/tmp/fixture-media"
    }
  },
  "komga" => {
    "role" => "komga",
    "media_target" => "/data",
    "state_paths" => ["{{ nas_docker_root }}/komga/config"],
    "environment" => {
      "TZ" => "UTC",
      "PLATFORM_CONTAINER_CPUSET" => "0",
      "PLATFORM_PROJECT_NAME" => "fixture",
      "KOMGA_HOST_PORT" => "25600",
      "KOMGA_CONFIG_PATH" => "/tmp/fixture-komga-config",
      "KOMGA_LIBRARY_PATH" => "/tmp/fixture-books"
    }
  }
}.freeze

IDENTITY = "${NAS_UID:?}:${NAS_GID:?}"

def compose_strings(node)
  case node
  when Hash then node.flat_map { |key, value| [key.to_s] + compose_strings(value) }
  when Array then node.flat_map { |value| compose_strings(value) }
  when String then [node]
  else []
  end
end

failures = []

# The canonical file alone and beneath each platform override.
def compose_stacks(name)
  base = File.join("services", name, "compose.yml")
  stacks = { "canonical" => [base] }
  Dir.glob(File.join(ROOT, "services", name, "compose.*.yml")).sort.each do |absolute|
    kind = File.basename(absolute).sub(/\Acompose\./, "").sub(/\.yml\z/, "")
    stacks[kind] = [base, File.join("services", name, "compose.#{kind}.yml")]
  end
  stacks
end

def render(files, environment)
  command = ["docker", "compose"]
  files.each { |file| command.concat(["-f", file]) }
  command.concat(["config", "--format", "json"])
  stdout, stderr, status = Open3.capture3(
    environment.merge("COMPOSE_PROFILES" => nil), *command, chdir: ROOT
  )
  [stdout, stderr, status.success?]
end

def effective(files, environment)
  stdout, stderr, succeeded = render(files, environment)
  raise "#{files.join(' + ')} effective Compose failed: #{stderr.lines.first&.strip}" unless succeeded

  JSON.parse(stdout)
end

storage = NasStorage.entries(ROOT)

READERS.each do |name, reader|
  compose_path = File.join(ROOT, "services", name, "compose.yml")
  compose_document = YAML.safe_load_file(compose_path, aliases: true)
  declared_users = Array(compose_document["services"]).map { |_service, definition| definition["user"] }

  # Spelled the one way the platform spells it; read from parsed services, so a
  # comment cannot count.
  check(failures, declared_users.count(IDENTITY) == 1,
        "#{name} Compose must declare its user as #{IDENTITY} exactly once")
  check(failures, compose_strings(compose_document).none? { |value| value.include?("1000:100") },
        "#{name} Compose must not contain the hard-coded 1000:100 identity")

  environment_path = File.join(ROOT, "roles", reader.fetch("role"), "templates", "env.j2")
  assignments = File.readlines(environment_path).filter_map do |line|
    variable, _separator, value = line.strip.partition("=")
    [variable, value] if line.strip.match?(/\A[A-Z][A-Z0-9_]*=/)
  end
  { "NAS_UID" => "{{ nas_uid }}", "NAS_GID" => "{{ nas_gid }}" }.each do |variable, value|
    check(failures, assignments.count([variable, value]) == 1,
          "#{reader.fetch('role')} environment must assign #{variable}={{ nas_uid_or_gid }} " \
          "exactly once (expected #{variable}=#{value})")
  end

  base_environment = reader.fetch("environment")
  identity_environment = base_environment.merge("NAS_UID" => PROOF_UID, "NAS_GID" => PROOF_GID)

  compose_stacks(name).each do |kind, files|
    document = effective(files, identity_environment)
    service = document.fetch("services").fetch(name)
    check(failures, service["user"] == "#{PROOF_UID}:#{PROOF_GID}",
          "#{name} #{kind} effective user must resolve to the supplied platform identity, " \
          "got #{service['user'].inspect}")

    media = Array(service["volumes"]).find { |volume| volume["target"] == reader.fetch("media_target") }
    check(failures, media && media["read_only"] == true,
          "#{name} #{kind} must keep #{reader.fetch('media_target')} mounted read-only, " \
          "so adopting the identity cannot rewrite NAS-owned media")
  end

  # Prove the :? guard fails the render rather than trusting it.
  %w[NAS_UID NAS_GID].each do |variable|
    _stdout, _stderr, succeeded = render(
      ["services/#{name}/compose.yml"], identity_environment.merge(variable => nil)
    )
    check(failures, !succeeded,
          "#{name} Compose must refuse to render without #{variable}")
  end

  reader.fetch("state_paths").each do |path|
    entry = storage.find { |candidate| candidate["path"] == path }
    check(failures, entry && entry["owner"] == "{{ nas_uid }}" && entry["group"] == "{{ nas_gid }}",
          "#{name} state directory #{path} must be owned by the platform identity")
  end
end

media_entries = storage.select do |entry|
  entry.fetch("path").start_with?("{{ nas_media_root }}/Media", "{{ nas_media_root }}/Books")
end
check(failures, media_entries.length >= 7,
      "the reader media trees must still be declared in nas_storage")
media_entries.each do |entry|
  check(failures, !entry.key?("owner") && !entry.key?("group"),
        "#{entry.fetch('path')} must claim no ownership: the NAS owns the media files and " \
        "the readers adopt the platform identity instead of the files being rewritten")
end

report(failures, "reader platform identity: all properties hold",
       "reader platform identity violation(s)")
