#!/usr/bin/env ruby

require "json"
require "open3"
require "yaml"

ROOT = File.expand_path("..", __dir__)

def check(failures, condition, message)
  failures << message unless condition
end

def strict_yaml(relative_path)
  path = File.join(ROOT, relative_path)
  source = File.read(path)
  stream = Psych.parse_stream(source)
  raise "#{relative_path} must contain exactly one YAML document" unless
    stream.children.length == 1

  duplicates = []
  walk = lambda do |node|
    if node.is_a?(Psych::Nodes::Mapping)
      seen = {}
      node.children.each_slice(2) do |key, value|
        if key.is_a?(Psych::Nodes::Scalar)
          duplicates << key.value if seen[key.value]
          seen[key.value] = true
        end
        walk.call(value)
      end
    elsif node.respond_to?(:children) && node.children
      node.children.each { |child| walk.call(child) }
    end
  end
  walk.call(stream)
  raise "#{relative_path} contains duplicate keys: #{duplicates.uniq.join(', ')}" unless
    duplicates.empty?

  YAML.safe_load(source, aliases: false)
end

def compose_yaml(relative_path, failures)
  path = File.join(ROOT, relative_path)
  unless File.file?(path)
    failures << "#{relative_path} must exist"
    return {}
  end

  YAML.safe_load_file(path, aliases: true)
rescue Psych::Exception => e
  failures << "#{relative_path} must be valid Compose YAML: #{e.message.lines.first.strip}"
  {}
end

def effective_compose(relative, environment, profile: nil)
  command = ["docker", "compose", "-f", relative]
  command.concat(["--profile", profile]) if profile
  command.concat(["config", "--format", "json"])
  stdout, stderr, status = Open3.capture3(
    environment.merge("COMPOSE_PROFILES" => nil), *command, chdir: ROOT
  )
  raise "#{relative} effective Compose failed: #{stderr.lines.first&.strip}" unless status.success?

  JSON.parse(stdout)
end

failures = []
catalog = strict_yaml("config/media-acquisition.yml")
manifest = strict_yaml("services/manifest.yml")
all_vars = strict_yaml("inventory/group_vars/all/main.yml")

expected_status = {
  "arr" => "implemented",
  "downloaders" => "implemented",
  "bindery" => "planned",
  "kapowarr" => "planned",
  "pinchflat" => "planned",
  "trailarr" => "planned",
  "seerr" => "planned"
}

expected_status.each do |name, status|
  check(failures, catalog.dig("projects", name, "status") == status,
        "#{name} catalog status must be #{status}")
  manifest_entry = manifest.fetch("services").find { |entry| entry["name"] == name }
  check(failures, manifest_entry&.fetch("status") == status,
        "#{name} manifest status must be #{status}")
end

expected_safe_defaults = {
  "media_acquisition_adopt_existing_libraries" => false,
  "media_arr_automatic_monitoring_enabled" => false,
  "media_arr_automatic_rename_enabled" => false,
  "media_bazarr_handoff_accepted" => false,
  "media_arr_indexers" => [],
  "media_bazarr_languages" => [],
  "media_bazarr_providers" => []
}
expected_safe_defaults.each do |name, value|
  check(failures, all_vars[name] == value,
        "#{name} must default to #{value.inspect}")
end

# Usenet is enabled on the NAS, where Phase 1 was accepted. Every other
# transport on every host stays inert until its own handoff.
{ "nas_hosts" => { "media_usenet_enabled" => true, "media_torrent_enabled" => false },
  "mac_hosts" => { "media_usenet_enabled" => false, "media_torrent_enabled" => false } }
  .each do |host_group, flags|
  vars = strict_yaml("inventory/group_vars/#{host_group}/main.yml")
  flags.each do |flag, expected|
    check(failures, vars[flag] == expected,
          "#{host_group} #{flag} must remain literal #{expected}")
  end
end

arr_compose = compose_yaml("services/arr/compose.yml", failures)
downloaders_compose = compose_yaml("services/downloaders/compose.yml", failures)
check(failures, !File.exist?(File.join(ROOT, "services/arr/compose.jobs.yml")),
      "services/arr/compose.jobs.yml must be absent")
# Read off the parsed services rather than the file's lines: a user declared in
# a comment is not a user any container runs as, and the negative used to reject
# a comment recording that the literal must never come back.
downloaders_users = Array(downloaders_compose["services"])
                    .to_h { |service, definition| [service, definition["user"]] }
check(failures,
      downloaders_users["unpackerr"] == "${NAS_UID:?}:${NAS_GID:?}",
      "Unpackerr source must derive its user from NAS_UID and NAS_GID")
check(failures, downloaders_users.values.none? { |user| user.to_s.include?("1000:100") },
      "downloaders Compose must not contain the hard-coded 1000:100 user")
effective_downloaders = effective_compose("services/downloaders/compose.yml", {
  "NAS_UID" => "2345",
  "NAS_GID" => "3456",
  "TZ" => "UTC",
  "PLATFORM_CONTAINER_CPUSET" => "0",
  "PLATFORM_MEDIA_NETWORK" => "fixture-media",
  "SABNZBD_CONFIG_PATH" => "/tmp/sabnzbd",
  "MEDIA_ACQUISITION_PATH" => "/tmp/media",
  "BOOKS_ACQUISITION_PATH" => "/tmp/books",
  "SABNZBD_API_KEY" => "fixture",
  "RADARR_API_KEY" => "fixture",
  "SONARR_API_KEY" => "fixture"
})
check(failures, effective_downloaders.dig("services", "unpackerr", "user") == "2345:3456",
      "effective Unpackerr user must resolve from NAS_UID and NAS_GID")

arr_environment = {
  "NAS_UID" => "2345",
  "NAS_GID" => "3456",
  "TZ" => "UTC",
  "PLATFORM_CONTAINER_CPUSET" => "0",
  "PLATFORM_MEDIA_NETWORK" => "fixture-media",
  "MEDIA_ROOT" => "/tmp/media",
  "RADARR_CONFIG_PATH" => "/tmp/radarr",
  "SONARR_CONFIG_PATH" => "/tmp/sonarr",
  "PROWLARR_CONFIG_PATH" => "/tmp/prowlarr",
  "BAZARR_CONFIG_PATH" => "/tmp/bazarr",
  "CONFIGARR_CONFIG_PATH" => "/tmp/configarr.yml",
  "CONFIGARR_SECRETS_PATH" => "/tmp/configarr-secrets.yml",
  "CONFIGARR_REPOS_PATH" => "/tmp/configarr-repos"
}
effective_arr_without_jobs = effective_compose("services/arr/compose.yml", arr_environment)
check(failures, !effective_arr_without_jobs.dig("services", "configarr"),
      "effective Configarr must remain absent without the jobs profile")
effective_arr = effective_compose("services/arr/compose.yml", arr_environment, profile: "jobs")
check(failures, effective_arr.dig("services", "configarr"),
      "effective Configarr must be present with the jobs profile")
check(failures, effective_arr.dig("services", "configarr", "user") == "2345:3456",
      "effective Configarr user must resolve from NAS_UID and NAS_GID")

arr_services = arr_compose.fetch("services", {})
downloader_services = downloaders_compose.fetch("services", {})
check(failures, arr_services.keys.sort == %w[bazarr configarr prowlarr radarr sonarr],
      "arr canonical service set must include long-running and profiled services")
check(failures, downloader_services.keys.sort == %w[sabnzbd unpackerr],
      "Phase 1 downloader service set must be exact")
check(failures,
      arr_services.select { |_name, definition| definition["profiles"] == ["jobs"] }.keys == ["configarr"],
      "Configarr must be the only profiled job service")
check(failures, downloader_services.dig("unpackerr", "user") == "${NAS_UID:?}:${NAS_GID:?}",
      "Unpackerr must run as the NAS_UID/NAS_GID identity")

expected_cpus = {
  "radarr" => 1.0, "sonarr" => 1.0, "prowlarr" => 0.5, "bazarr" => 1.0,
  "configarr" => 0.5, "sabnzbd" => 2.0, "unpackerr" => 1.0
}
(arr_services.merge(downloader_services)).each do |name, definition|
  image = definition["image"]
  check(failures,
        image.is_a?(String) && image.match?(/:[A-Za-z0-9][A-Za-z0-9_.-]*@sha256:[0-9a-f]{64}\z/),
        "#{name} image must carry a readable tag and sha256 digest")
  check(failures, definition["cpuset"] == "${PLATFORM_CONTAINER_CPUSET:?}",
        "#{name} must require the platform CPU set")
  check(failures, definition["cpus"] == expected_cpus[name],
        "#{name} CPU ceiling must be #{expected_cpus[name]}")
  check(failures, definition.dig("logging", "driver") == "json-file" &&
                  definition.dig("logging", "options", "max-size") == "10m" &&
                  definition.dig("logging", "options", "max-file") == "3",
        "#{name} logging must be bounded")
  next if name == "configarr"

  check(failures, definition["restart"] == "unless-stopped",
        "#{name} must restart unless stopped")
  check(failures, definition.dig("labels", "dev.dozzle.name") == name,
        "#{name} must have its Dozzle display name")
  check(failures, definition["healthcheck"].is_a?(Hash) &&
                  Array(definition.dig("healthcheck", "test")).length >= 2,
        "#{name} must have a meaningful healthcheck")
end

%w[radarr sonarr prowlarr bazarr].each do |name|
  check(failures, Array(arr_services.dig(name, "networks")).include?("media-control"),
        "#{name} must join media-control")
end
check(failures, arr_compose.dig("networks", "media-control") == {
        "external" => true, "name" => "${PLATFORM_MEDIA_NETWORK:?}"
      }, "arr must use the external media-control network")
check(failures, downloaders_compose.dig("networks", "media-control") == {
        "external" => true, "name" => "${PLATFORM_MEDIA_NETWORK:?}"
      }, "downloaders must use the external media-control network")

%w[radarr sonarr bazarr].each do |name|
  check(failures,
        Array(arr_services.dig(name, "volumes")).include?("${MEDIA_ROOT:?}/Media:/data/media"),
        "#{name} must see the full Media share at /data/media")
end
check(failures,
      Array(downloader_services.dig("sabnzbd", "volumes")).sort == [
        "${BOOKS_ACQUISITION_PATH:?}:/data/books/.acquisition",
        "${MEDIA_ACQUISITION_PATH:?}:/data/media/.acquisition",
        "${SABNZBD_CONFIG_PATH:?}:/config"
      ].sort,
      "SABnzbd mounts must be limited to config and acquisition parents")
check(failures,
      Array(downloader_services.dig("unpackerr", "volumes")).sort == [
        "${BOOKS_ACQUISITION_PATH:?}:/data/books/.acquisition",
        "${MEDIA_ACQUISITION_PATH:?}:/data/media/.acquisition"
      ].sort,
      "Unpackerr mounts must match the acquisition parents")
check(failures, !downloader_services.fetch("unpackerr", {}).key?("ports"),
      "Unpackerr must publish no ports")

configarr = arr_services.fetch("configarr", {})
check(failures, configarr["profiles"] == ["jobs"],
      "Configarr must stay behind the jobs profile")
check(failures, configarr["user"] == "${NAS_UID:?}:${NAS_GID:?}",
      "Configarr must derive its user from NAS_UID and NAS_GID")
check(failures, configarr["cpuset"] == "${PLATFORM_CONTAINER_CPUSET:?}" &&
                configarr["cpus"] == 0.5,
      "Configarr must use its exact CPU policy")
check(failures, !configarr.key?("restart"), "Configarr must not restart")
check(failures, !configarr.key?("ports"), "Configarr must publish no ports")
check(failures, !configarr.key?("healthcheck"), "Configarr must define no healthcheck")
check(failures, configarr["networks"] == ["media-control"],
      "Configarr must join only media-control")
check(failures, configarr.dig("logging", "driver") == "json-file" &&
                configarr.dig("logging", "options") == {
                  "max-size" => "10m", "max-file" => "3"
                }, "Configarr logging must be bounded")

%w[
  services/arr/compose.mac.yml services/arr/compose.integration.yml
  services/downloaders/compose.mac.yml services/downloaders/compose.integration.yml
].each do |relative_path|
  check(failures, File.file?(File.join(ROOT, relative_path)), "#{relative_path} must exist")
end

operator_guide_path = File.join(ROOT, "docs", "media-acquisition-phase1.md")
operator_guide = File.file?(operator_guide_path) ? File.read(operator_guide_path) : ""
check(failures, !operator_guide.empty?, "Phase 1 operator guide must exist")
{
  /media_usenet_enabled: true.*inventory\/group_vars\/nas_hosts/m =>
    "guide must name the inventory value that activates a target",
  /ansible-vault edit inventory\/group_vars\/all\/vault\.yml/ =>
    "guide must put provider and preference choices in the vault",
  /never enter the repository/i =>
    "guide must say why committing the encrypted vault is safe",
  /media_acquisition_adopt_existing_libraries=true.*one convergence/im =>
    "guide must bound the adoption override to one convergence",
  /match.*Movies.*Series.*before.*rename.*monitor/im =>
    "guide must review existing libraries before enabling rename or monitoring",
  /one movie.*one episode.*required-language.*sidecar/im =>
    "guide must require movie, episode, and subtitle-sidecar proof",
  /media_bazarr_handoff_accepted.*Open Subtitles/im =>
    "guide must record the Bazarr handoff before Open Subtitles removal",
  /stop Radarr and Sonarr.*before.*legacy writer/im =>
    "guide must stop acquisition writers before restoring a legacy writer"
}.each do |pattern, message|
  check(failures, operator_guide.match?(pattern), message)
end
%w[provider\ connectivity content\ acquisition NAS\ ACL\ correctness Open\ Subtitles\ retirement].each do |claim|
  check(failures, operator_guide.match?(/does not claim.*#{claim}/im),
        "guide must disclaim #{claim.tr('\\', '')}")
end

if failures.empty?
  puts "media acquisition phase 1: activation contract holds"
else
  warn failures.join("\n")
  exit 1
end
