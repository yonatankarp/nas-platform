#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "digest"
require "digest/md5"
require "json"
require "open3"
require "rbconfig"
require "socket"
require "tmpdir"
require "uri"
require "yaml"

ROOT = File.expand_path("..", __dir__)

def resolve_ansible_playbook(root: ROOT, path: ENV.fetch("PATH", ""))
  path.split(File::PATH_SEPARATOR).each do |directory|
    candidate = File.join(directory, "ansible-playbook")
    return candidate if File.executable?(candidate)
  end

  common_dir, status = Open3.capture2(
    "git", "rev-parse", "--git-common-dir", chdir: root
  )
  return "" unless status.success?

  common_dir = File.expand_path(common_dir.strip, root)
  File.join(File.dirname(common_dir), ".venv", "bin", "ansible-playbook")
end

ANSIBLE_PLAYBOOK = resolve_ansible_playbook.freeze
ARR_TASKS = File.join(ROOT, "roles", "arr", "tasks")
DOWNLOADER_TASKS = File.join(ROOT, "roles", "downloaders", "tasks")
CONFIGARR_SOURCE = File.join(ROOT, "roles", "arr", "files", "configarr", "config.yml")
CONFIGARR_QUALITY_DEFINITION_SOURCES = {
  "radarr" => File.join(
    ROOT, "roles", "arr", "files", "configarr", "quality-definition-movie.json"
  ),
  "sonarr" => File.join(
    ROOT, "roles", "arr", "files", "configarr", "quality-definition-series.json"
  )
}.freeze
CONFIGARR_QUALITY_DEFINITION_SHA256 = {
  "radarr" => "bca0755668a9f55fa512a7e5d2d0e8000ed4339ac4ccd996bb8be0efa6dbef3c",
  "sonarr" => "2e2c0fe9dcbf148d9282cee4ff76c1e56e096d10965aafaa12f39890a063782b"
}.freeze
PLAYBOOK_TIMEOUT_SECONDS = Float(ENV.fetch("ACQUISITION_PLAYBOOK_TIMEOUT", "30"))
PROCESS_TERM_GRACE_SECONDS = 1.0
SOCKET_DEADLINE_SECONDS = 2.0
CONFIGARR_MUTATION_PATTERN = ENV["ACQUISITION_CONFIGARR_MUTATION_PATTERN"]
PROFILE_TREE_ID_TARGETED_ONLY =
  ENV["ACQUISITION_PROFILE_TREE_ID_TARGETED_ONLY"] == "1"
COMPLETE_PROFILE_TREE_TARGETED_ONLY =
  ENV["ACQUISITION_COMPLETE_PROFILE_TREE_TARGETED_ONLY"] == "1"
API_BOUNDARY_TARGETED_ONLY =
  ENV["ACQUISITION_API_BOUNDARY_TARGETED_ONLY"] == "1"
OPAQUE_TARGETED_ONLY = ENV["ACQUISITION_OPAQUE_TARGETED_ONLY"] == "1" ||
                       !CONFIGARR_MUTATION_PATTERN.nil? ||
                       PROFILE_TREE_ID_TARGETED_ONLY ||
                       COMPLETE_PROFILE_TREE_TARGETED_ONLY ||
                       API_BOUNDARY_TARGETED_ONLY
SECRET_TASK_FILES = [
  [ARR_TASKS, "reconcile_prowlarr.yml"],
  [ARR_TASKS, "reconcile_prowlarr_application.yml"],
  [ARR_TASKS, "reconcile_servarr_download_client.yml"],
  [ARR_TASKS, "validate_servarr_download_clients.yml"],
  [ARR_TASKS, "reconcile_bazarr.yml"],
  [ARR_TASKS, "configarr.yml"],
  [ARR_TASKS, "verify.yml"],
  [DOWNLOADER_TASKS, "verify.yml"]
].freeze
NON_SECRET_TASK_NAMES = [
  "Reconcile each Prowlarr full-sync application",
  "Record a bounded Configarr execution summary"
].freeze
FINGERPRINT_RECORD_TASK_NAME = "Record verified Arr desired-input fingerprints"
FINGERPRINT_READER_TASK_NAME = "Atomically read private Arr desired-input fingerprints"
VERIFICATION_GATE_INIT_TASK_NAME = "Initialize Arr reconciliation verification gate"
VERIFICATION_GATE_SUCCESS_TASK_NAME = "Mark Arr reconciliation verification successful"
DOWNLOADER_GATE_INIT_TASK_NAME = "Initialize downloader relationship verification gate"
DOWNLOADER_GATE_SUCCESS_TASK_NAME = "Mark downloader relationship verification successful"
FINGERPRINT_STAT_RESULTS = "{{ arr_reconciliation_fingerprint_stats.results }}"
FINGERPRINT_FILE_SAFETY_PREDICATES = {
  "regular" => "not item.stat.exists or item.stat.isreg",
  "symlink" => "not item.stat.exists or not item.stat.islnk",
  "mode" => "not item.stat.exists or item.stat.mode == '0600'",
  "owner" => "not item.stat.exists or item.stat.uid | int == nas_uid | int",
  "group" => "not item.stat.exists or item.stat.gid | int == nas_gid | int"
}.freeze

FINGERPRINT_FILES = %w[
  .configarr-input.sha256
  .configarr-owned-state.sha256
  .configarr-opaque-context.sha256
  .prowlarr-applications-input.sha256
  .servarr-sabnzbd-input.sha256
  .prowlarr-indexers-input.sha256
  .bazarr-providers-input.sha256
].freeze
CONFIGARR_STATE_FINGERPRINT_FILE = ".configarr-owned-state.sha256"
CONFIGARR_OPAQUE_FINGERPRINT_FILE = ".configarr-opaque-context.sha256"
FINGERPRINT_FILE_BY_KIND = {
  application: ".prowlarr-applications-input.sha256",
  download_client: ".servarr-sabnzbd-input.sha256",
  download_client_production: ".servarr-sabnzbd-input.sha256",
  indexer: ".prowlarr-indexers-input.sha256",
  bazarr: ".bazarr-providers-input.sha256",
  configarr: ".configarr-input.sha256"
}.freeze
FINGERPRINT_KIND_BY_FILE = FINGERPRINT_FILE_BY_KIND.invert.freeze
FINGERPRINT_INPUT_BY_KIND = {
  application: "prowlarr_applications",
  download_client: "servarr_sabnzbd",
  download_client_production: "servarr_sabnzbd",
  indexer: "prowlarr_indexers",
  bazarr: "bazarr_providers",
  configarr: "configarr"
}.freeze
FINGERPRINT_BASELINE_CACHE = { "enabled" => false }
CONFIGARR_IMAGE = "ghcr.io/raydak-labs/configarr:1.28.0@sha256:" \
                  "008d8659ff35f63fbcc20b860b33ba7cc49e8d7458a6ec446810ec4d783ef017"
CONFIGARR_QUALITY_DEFINITION_DOCUMENTS =
  CONFIGARR_QUALITY_DEFINITION_SOURCES.transform_values do |path|
    JSON.parse(File.read(path))
  end.freeze

SECRETS = {
  "application" => "fixture-application-api-secret",
  "sab_api" => "fixture-sab-api-secret",
  "sab_username" => "fixture-sab-username-secret",
  "sab_password" => "fixture-sab-password-secret",
  "indexer" => "fixture-indexer-api-secret",
  "bazarr_admin" => "fixture-bazarr-admin-secret",
  "radarr" => "fixture-radarr-api-secret",
  "sonarr" => "fixture-sonarr-api-secret",
  "provider" => "fixture-provider-password-secret"
}.freeze
SECRET_SENTINELS = (SECRETS.values + [
  "fixture-prowlarr-control-key", "fixture-bazarr-control-key",
  "legacy-readable-value", "private-stale-application-secret",
  "private-stale-indexer-secret", "private-stale-provider-secret",
  "private-stale-apiKey", "private-stale-username", "private-stale-password",
  "private-stale-sonarr-apiKey", "private-stale-sonarr-username",
  "private-stale-sonarr-password", "private-stale-auth-password",
  "private-stale-radarr-apikey", "private-stale-sonarr-apikey",
  "fixture-radarr-admin-password", "fixture-sonarr-admin-password",
  "fixture-prowlarr-admin-password"
]).freeze

APPLICATION_DECLARATION = {
  "name" => "Radarr", "implementation" => "Radarr",
  "implementation_name" => "Radarr", "config_contract" => "RadarrSettings",
  "base_url" => "http://radarr:7878", "api_key" => SECRETS.fetch("application"),
  "sync_categories" => [2020, 2000], "tags" => [9, 3]
}.freeze
APPLICATION = {
  "id" => 11, "name" => "Radarr", "enable" => true, "syncLevel" => "fullSync",
  "implementation" => "Radarr", "implementationName" => "Radarr",
  "configContract" => "RadarrSettings", "tags" => [3, 9],
  "fields" => [
    { "name" => "prowlarrUrl", "value" => "http://prowlarr:9696" },
    { "name" => "baseUrl", "value" => "http://radarr:7878" },
    { "name" => "username", "value" => "" },
    { "name" => "password", "value" => "" },
    { "name" => "apiKey", "value" => SECRETS.fetch("application") },
    { "name" => "syncCategories", "value" => [2000, 2020] }
  ]
}.freeze

SONARR_APPLICATION_DECLARATION = {
  "name" => "Sonarr", "implementation" => "Sonarr",
  "implementation_name" => "Sonarr", "config_contract" => "SonarrSettings",
  "base_url" => "http://sonarr:8989", "api_key" => SECRETS.fetch("sonarr"),
  "sync_categories" => [5020, 5000], "tags" => [8, 2]
}.freeze
SONARR_APPLICATION = {
  "id" => 13, "name" => "Sonarr", "enable" => true, "syncLevel" => "fullSync",
  "implementation" => "Sonarr", "implementationName" => "Sonarr",
  "configContract" => "SonarrSettings", "tags" => [2, 8],
  "fields" => [
    { "name" => "prowlarrUrl", "value" => "http://prowlarr:9696" },
    { "name" => "baseUrl", "value" => "http://sonarr:8989" },
    { "name" => "username", "value" => "" },
    { "name" => "password", "value" => "" },
    { "name" => "apiKey", "value" => SECRETS.fetch("sonarr") },
    { "name" => "syncCategories", "value" => [5000, 5020] }
  ]
}.freeze

SERVARR_INSTANCE = {
  "name" => "radarr", "category" => "movies", "tags" => [5, 1],
  "api_key" => SECRETS.fetch("radarr"), "root_folder" => "/data/media/Movies",
  "rename_field" => "renameMovies", "admin_username" => "fixture-radarr-admin",
  "admin_password" => "fixture-radarr-admin-password"
}.freeze
SONARR_INSTANCE = {
  "name" => "sonarr", "category" => "series", "tags" => [6, 2],
  "api_key" => SECRETS.fetch("sonarr"), "root_folder" => "/data/media/Series",
  "rename_field" => "renameEpisodes", "admin_username" => "fixture-sonarr-admin",
  "admin_password" => "fixture-sonarr-admin-password"
}.freeze
DOWNLOAD_CLIENT = {
  "id" => 21, "name" => "SABnzbd", "enable" => true, "protocol" => "usenet",
  "priority" => 1, "removeCompletedDownloads" => true, "removeFailedDownloads" => true,
  "implementation" => "Sabnzbd", "implementationName" => "SABnzbd",
  "configContract" => "SabnzbdSettings", "tags" => [1, 5],
  "fields" => [
    { "name" => "host", "value" => "sabnzbd" },
    { "name" => "port", "value" => 8080 },
    { "name" => "useSsl", "value" => false },
    { "name" => "urlBase", "value" => "" },
    { "name" => "apiKey", "value" => SECRETS.fetch("sab_api") },
    { "name" => "username", "value" => SECRETS.fetch("sab_username") },
    { "name" => "password", "value" => SECRETS.fetch("sab_password") },
    { "name" => "movieCategory", "value" => "movies" }
  ]
}.freeze
SONARR_DOWNLOAD_CLIENT = Marshal.load(Marshal.dump(DOWNLOAD_CLIENT)).tap do |client|
  client["id"] = 22
  client["tags"] = [2, 6]
  category = client.fetch("fields").find { |field| field["name"] == "movieCategory" }
  category["name"] = "tvCategory"
  category["value"] = "series"
end.freeze
SABNZBD = {
  "config" => {
    "misc" => { "complete_dir" => "/data/complete", "download_dir" => "/data/incomplete" },
    "categories" => [
      { "name" => "movies", "dir" => "movies" },
      { "name" => "series", "dir" => "series" }
    ]
  }
}.freeze

INDEXER_DECLARATION = {
  "name" => "Fixture Indexer", "enable" => true, "priority" => 17,
  "implementation" => "Newznab", "implementation_name" => "Newznab",
  "config_contract" => "NewznabSettings", "tags" => [9, 3],
  "fields" => [
    { "name" => "baseUrl", "value" => "https://indexer.example.invalid" },
    { "name" => "apiPath", "value" => "/api" },
    { "name" => "categories", "value" => [5000, 2000] },
    { "name" => "orderedValues", "value" => ["first", { "nested" => 1 }, 2] },
    { "name" => "minimumSeeders", "value" => 0 },
    { "name" => "apiKey", "value" => SECRETS.fetch("indexer") }
  ]
}.freeze
INDEXER = {
  "id" => 31, "name" => "Fixture Indexer", "enable" => true, "priority" => 17,
  "implementation" => "Newznab", "implementationName" => "Newznab",
  "configContract" => "NewznabSettings", "tags" => [3, 9],
  "fields" => INDEXER_DECLARATION.fetch("fields")
}.freeze

BAZARR_PROVIDER = {
  "name" => "opensubtitlescom",
  "settings" => {
    "settings-opensubtitlescom-username" => "fixture-provider-user",
    "settings-opensubtitlescom-password" => SECRETS.fetch("provider"),
    "settings-opensubtitlescom-use_hash" => "true",
    "settings-opensubtitlescom-include_ai_translated" => "false",
    "settings-opensubtitlescom-include_machine_translated" => "false"
  }
}.freeze
BAZARR_TYPED_PROVIDER = {
  "name" => "animetosho",
  "settings" => {
    "settings-animetosho-search_threshold" => "6",
    "settings-animetosho-exclude" => []
  }
}.freeze
BAZARR = {
  "auth" => {
    "type" => "form", "username" => "fixture-bazarr-admin",
    "password" => SECRETS.fetch("bazarr_admin")
  },
  "general" => {
    "use_radarr" => true, "use_sonarr" => true,
    "path_mappings" => [], "path_mappings_movie" => [], "enabled_providers" => []
  },
  "radarr" => {
    "ip" => "radarr", "port" => 7878, "base_url" => "", "ssl" => false,
    "apikey" => SECRETS.fetch("radarr")
  },
  "sonarr" => {
    "ip" => "sonarr", "port" => 8989, "base_url" => "", "ssl" => false,
    "apikey" => SECRETS.fetch("sonarr")
  },
  "languages" => { "enabled" => %w[de en] },
  "providers" => {}
}.freeze
BAZARR_WITH_PROVIDER = Marshal.load(Marshal.dump(BAZARR)).tap do |settings|
  settings.fetch("general")["enabled_providers"] = [BAZARR_PROVIDER.fetch("name")]
  settings.fetch("providers")[BAZARR_PROVIDER.fetch("name")] = {
    "username" => "fixture-provider-user",
    "password" => SECRETS.fetch("provider"),
    "use_hash" => true,
    "include_ai_translated" => false,
    "include_machine_translated" => false
  }
end.freeze

configarr_yaml = File.read(CONFIGARR_SOURCE).gsub(/!secret\s+[A-Z_]+/, '"fixture-secret-reference"')
CONFIGARR_POLICY = YAML.safe_load(configarr_yaml, aliases: false).freeze
CONFIGARR_CUSTOM_FORMAT = CONFIGARR_POLICY.fetch("customFormatDefinitions").fetch(0)
CONFIGARR_PROFILE_NAME = "HD Bluray + WEB 1080p"
CONFIGARR_FORMAT_NAME = CONFIGARR_CUSTOM_FORMAT.fetch("name")

# Exact pinned TRaSH outputs used by Configarr v1.28.0. Raw-HD is intentionally
# absent from both pinned definitions so its nullable values remain verified
# server context rather than synthetic desired values.
# https://github.com/TRaSH-Guides/Guides/blob/cbfee0205cdcf2b492135edd00e059f3b7c84675/docs/json/radarr/quality-size/movie.json
# https://github.com/TRaSH-Guides/Guides/blob/cbfee0205cdcf2b492135edd00e059f3b7c84675/docs/json/sonarr/quality-size/series.json
quality_sizes = CONFIGARR_QUALITY_DEFINITION_DOCUMENTS.transform_values do |document|
  document.fetch("qualities").to_h do |quality|
    [quality.fetch("quality"), quality.values_at("min", "preferred", "max")]
  end
end.freeze
quality_metadata = [
  [7, "Bluray-1080p", 1080], [3, "WEBDL-1080p", 1080],
  [15, "WEBRip-1080p", 1080], [9, "HDTV-1080p", 1080],
  [10, "Raw-HD", 1080]
].freeze
quality_sources = {
  "radarr" => {
    "Bluray-1080p" => "bluray", "WEBDL-1080p" => "webdl",
    "WEBRip-1080p" => "webrip", "HDTV-1080p" => "tv", "Raw-HD" => "tv"
  },
  "sonarr" => {
    "Bluray-1080p" => "bluray", "WEBDL-1080p" => "web",
    "WEBRip-1080p" => "webRip", "HDTV-1080p" => "television",
    "Raw-HD" => "televisionRaw"
  }
}.freeze

quality_items = lambda do |profile, service_quality_definitions|
  definitions_by_name = service_quality_definitions.to_h do |definition|
    [definition.dig("quality", "name"), definition.fetch("quality")]
  end
  allowed = profile.fetch("qualities").map.with_index do |quality, index|
    if quality.key?("qualities")
      {
        "id" => 1000 + index, "name" => quality.fetch("name"), "allowed" => true,
        "items" => quality.fetch("qualities").reverse.map do |name|
          {
            "quality" => definitions_by_name.fetch(name).dup,
            "allowed" => true,
            "items" => []
          }
        end
      }
    else
      {
        "quality" => definitions_by_name.fetch(quality.fetch("name")).dup,
        "allowed" => true, "items" => []
      }
    end
  end
  selected_names = profile.fetch("qualities").flat_map do |quality|
    quality.fetch("qualities", [quality.fetch("name")])
  end
  disabled = service_quality_definitions.filter_map do |definition|
    quality = definition.fetch("quality")
    next if selected_names.include?(quality.fetch("name"))

    { "quality" => quality.dup, "allowed" => false, "items" => [] }
  end
  disabled + allowed.reverse
end

CONFIGARR = %w[radarr sonarr].each_with_index.to_h do |service, index|
  service_quality_definitions = quality_metadata.each_with_index.map do |(quality_id, name, resolution), qd_index|
    sizes = quality_sizes.fetch(service)[name] || [4, nil, nil]
    quality = {
      "id" => quality_id, "name" => name,
      "source" => quality_sources.fetch(service).fetch(name), "resolution" => resolution
    }
    quality["modifier"] = name == "Raw-HD" ? "rawhd" : "none" if service == "radarr"
    {
      "quality" => quality, "id" => 51 + qd_index, "title" => name,
      "weight" => qd_index + 1, "minSize" => sizes[0],
      "preferredSize" => sizes[1], "maxSize" => sizes[2]
    }
  end
  policy = CONFIGARR_POLICY.fetch(service).fetch("phase1")
  profile = policy.fetch("quality_profiles").find do |candidate|
    candidate.fetch("name") == CONFIGARR_PROFILE_NAME
  end
  format_assignment = policy.fetch("custom_formats").fetch(0)
  score = format_assignment.fetch("assign_scores_to").find do |assignment|
    assignment.fetch("name") == CONFIGARR_PROFILE_NAME
  end.fetch("score")
  naming = { "id" => 301 + index }.merge(policy.fetch("media_naming_api"))
  specification = CONFIGARR_CUSTOM_FORMAT.fetch("specifications").fetch(0)
  [service, {
    "qualityprofile" => [{
      "id" => 101 + index, "name" => profile.fetch("name"),
      "upgradeAllowed" => profile.dig("upgrade", "allowed"),
      "cutoff" => 7,
      "minFormatScore" => profile.fetch("min_format_score"),
      "cutoffFormatScore" => 1,
      "minUpgradeFormatScore" => 1,
      "items" => quality_items.call(profile, service_quality_definitions),
      "formatItems" => [
        { "format" => 201 + index, "name" => CONFIGARR_FORMAT_NAME, "score" => score },
        { "format" => 291 + index, "name" => "Unmanaged Format", "score" => 0 }
      ],
      "unmanagedProfileField" => "preserve-#{service}-profile"
    }.merge(service == "radarr" ? {
      "language" => { "id" => 1, "name" => "Original" }
    } : {}), {
      "id" => 111 + index, "name" => "Unmanaged HD", "upgradeAllowed" => false,
      "cutoff" => 4, "minFormatScore" => 0, "cutoffFormatScore" => 1,
      "minUpgradeFormatScore" => 1, "items" => [], "formatItems" => []
    }, {
      "id" => 121 + index, "name" => "Unmanaged UHD", "upgradeAllowed" => false,
      "cutoff" => 4, "minFormatScore" => 0, "cutoffFormatScore" => 1,
      "minUpgradeFormatScore" => 1, "items" => [], "formatItems" => []
    }],
    "qualitydefinition" => service_quality_definitions,
    "customformat" => [{
      "id" => 201 + index, "name" => CONFIGARR_FORMAT_NAME,
      "includeCustomFormatWhenRenaming" =>
        CONFIGARR_CUSTOM_FORMAT.fetch("includeCustomFormatWhenRenaming"),
      "specifications" => [{
        "name" => specification.fetch("name"),
        "implementation" => specification.fetch("implementation"),
        "negate" => specification.fetch("negate"),
        "required" => specification.fetch("required"),
        "fields" => [{ "name" => "value", "value" => specification.dig("fields", "value") }]
      }]
    }, {
      "id" => 291 + index, "name" => "Unmanaged Format",
      "includeCustomFormatWhenRenaming" => false, "specifications" => []
    }],
    "config/naming" => naming
  }]
end.freeze

def deep_copy(value)
  Marshal.load(Marshal.dump(value))
end

def task_slice(filename, first_name, last_name, root: ARR_TASKS)
  path = File.join(root, filename)
  tasks = YAML.safe_load_file(path, aliases: true)
  first_matches = tasks.each_index.select { |index| tasks[index]["name"] == first_name }
  last_matches = tasks.each_index.select { |index| tasks[index]["name"] == last_name }
  unless first_matches.length == 1 && last_matches.length == 1 && first_matches.first <= last_matches.first
    raise "#{filename} exact reconciliation task boundary is unavailable"
  end

  deep_copy(tasks[first_matches.first..last_matches.first])
end

def secret_task_sets
  sets = SECRET_TASK_FILES.to_h do |root, filename|
    path = File.join(root, filename)
    [path, YAML.safe_load_file(path, aliases: true)]
  end
  %w[reconciliation_fingerprints.yml record_reconciliation_fingerprints.yml].each do |filename|
    path = File.join(ARR_TASKS, filename)
    if File.file?(path)
      sets[path] = YAML.safe_load_file(path, aliases: true)
    end
  end
  sets
end

def secret_task_protected?(path, task)
  File.basename(path).include?("fingerprint") ||
    !NON_SECRET_TASK_NAMES.include?(task.fetch("name"))
end

def missing_secret_output_guards(task_sets)
  task_sets.flat_map do |path, tasks|
    tasks.filter_map do |task|
      File.join(File.basename(path), task.fetch("name")) if
        secret_task_protected?(path, task) && task.fetch("no_log", false) != true
    end
  end
end

def normalized_ansible_expression(value)
  value.to_s.delete("()").gsub(/\s+/, " ").strip
end

def fingerprint_record_contract_failures(tasks)
  task = tasks.find { |candidate| candidate["name"] == FINGERPRINT_RECORD_TASK_NAME }
  copy = task&.fetch("ansible.builtin.copy", nil)
  expected = {
    "copy.owner" => "{{ nas_uid }}",
    "copy.group" => "{{ nas_gid }}",
    "copy.mode" => "0600"
  }
  expected.filter_map do |label, value|
    label unless copy.is_a?(Hash) && copy[label.delete_prefix("copy.")] == value
  end
end

def fingerprint_loader_assertion_task(tasks)
  tasks.find do |candidate|
    assertion = candidate["ansible.builtin.assert"]
    Array(assertion&.fetch("that", nil)).any? do |condition|
      normalized_ansible_expression(condition).include?("item.stat.exists")
    end
  end
end

def fingerprint_loader_stat_task(tasks)
  tasks.find do |task|
    task["name"] == "Inspect private Arr desired-input fingerprint files" &&
      task["ansible.builtin.stat"].is_a?(Hash)
  end
end

def fingerprint_loader_contract_failures(tasks)
  stat_task = fingerprint_loader_stat_task(tasks)
  stat_options = stat_task&.fetch("ansible.builtin.stat", nil)
  task = fingerprint_loader_assertion_task(tasks)
  conditions = Array(task&.dig("ansible.builtin.assert", "that")).map do |condition|
    normalized_ansible_expression(condition)
  end
  failures = []
  %w[get_checksum get_mime get_attributes].each do |option|
    failures << "stat.#{option}" unless stat_options.is_a?(Hash) && stat_options[option] == false
  end
  failures << "assert.loop" unless
    normalized_ansible_expression(task&.fetch("loop", nil)) == FINGERPRINT_STAT_RESULTS
  FINGERPRINT_FILE_SAFETY_PREDICATES.each do |label, predicate|
    failures << "assert.#{label}" unless
      conditions.include?(normalized_ansible_expression(predicate))
  end
  failures
end

def fingerprint_atomic_reader_contract_failures(tasks)
  reader = tasks.find { |task| task["name"] == FINGERPRINT_READER_TASK_NAME }
  command = reader&.fetch("ansible.builtin.command", nil)
  argv = command&.fetch("argv", nil)
  script = Array(argv)[2].to_s
  failures = []
  failures << "reader.command" unless command.is_a?(Hash) && argv.is_a?(Array)
  failures << "reader.interpreter" unless Array(argv)[0].to_s.include?("ansible_facts")
  failures << "reader.no_slurp" if tasks.any? { |task| task.key?("ansible.builtin.slurp") }
  {
    "readonly" => "os.O_RDONLY",
    "nofollow" => "os.O_NOFOLLOW",
    "cloexec" => "os.O_CLOEXEC",
    "regular" => "stat.S_ISREG(before.st_mode)",
    "mode" => "stat.S_IMODE(before.st_mode) != 0o600",
    "uid" => "before.st_uid != expected_uid",
    "gid" => "before.st_gid != expected_gid",
    "size" => "before.st_size != 65",
    "bounded" => "os.read(fd, 65)",
    "extra" => "os.read(fd, 1)",
    "newline" => "content[64:] != b\"\\n\"",
    "lowercase" => "byte not in b\"0123456789abcdef\"",
    "fstat.before" => "before = os.fstat(fd)",
    "fstat.after" => "after = os.fstat(fd)",
    "identity" => "before_identity != after_identity",
    "stdout" => "sys.stdout.write(content[:64].decode(\"ascii\"))"
  }.each do |label, token|
    failures << "reader.#{label}" unless script.include?(token)
  end
  failures
end

def task_named(tasks, name)
  tasks.find { |task| task["name"] == name }
end

def verification_gate_contract_failures(main_tasks, verify_tasks)
  init = task_named(main_tasks, VERIFICATION_GATE_INIT_TASK_NAME)
  success_matches = verify_tasks.select do |task|
    task["name"] == VERIFICATION_GATE_SUCCESS_TASK_NAME
  end
  success = success_matches.first
  recorder = task_named(main_tasks, "Persist verified Arr desired-input fingerprints")
  reconciliation = task_named(main_tasks, "Reconcile each Servarr instance")
  verification = task_named(main_tasks, "Run Arr service verification")
  init_index = main_tasks.index(init)
  reconciliation_index = main_tasks.index(reconciliation)
  verification_index = main_tasks.index(verification)
  recorder_index = main_tasks.index(recorder)
  recorder_when = Array(recorder&.fetch("when", nil)).map { |condition| normalized_ansible_expression(condition) }
  failures = []
  failures << "gate.initialize" unless
    init_index && reconciliation_index && recorder_index &&
    init_index < reconciliation_index && init_index < recorder_index &&
    init&.dig("ansible.builtin.set_fact", "arr_reconciliation_verification_succeeded") == false &&
    init["changed_when"] == false
  failures << "gate.success" unless
    success_matches.length == 1 && verify_tasks.last.equal?(success) &&
    success&.dig("ansible.builtin.set_fact", "arr_reconciliation_verification_succeeded") == true &&
    success["changed_when"] == false && Array(success["tags"]).include?("platform_verify_arr")
  failures << "gate.recorder" unless
    verification_index && recorder_index && verification_index < recorder_index &&
    recorder_when.include?(
      normalized_ansible_expression("arr_reconciliation_verification_succeeded is sameas true")
    )
  failures
end

def check_fingerprint_record_contract(failures, label, tasks)
  fingerprint_record_contract_failures(tasks).each do |violation|
    failures << "#{label} fingerprint recorder violates #{violation}"
  end
  task = tasks.find { |candidate| candidate["name"] == FINGERPRINT_RECORD_TASK_NAME }
  return unless task&.fetch("ansible.builtin.copy", nil).is_a?(Hash)

  { "owner" => "wrong-owner", "group" => "wrong-group", "mode" => "0644" }.each do |field, wrong|
    contract_label = "copy.#{field}"
    removed = deep_copy(tasks)
    removed.find { |candidate| candidate["name"] == FINGERPRINT_RECORD_TASK_NAME }
           .fetch("ansible.builtin.copy").delete(field)
    failures << "#{label} fingerprint recorder #{field} removal mutation survived" unless
      fingerprint_record_contract_failures(removed).include?(contract_label)

    altered = deep_copy(tasks)
    altered.find { |candidate| candidate["name"] == FINGERPRINT_RECORD_TASK_NAME }
           .fetch("ansible.builtin.copy")[field] = wrong
    failures << "#{label} fingerprint recorder #{field} alteration mutation survived" unless
      fingerprint_record_contract_failures(altered).include?(contract_label)
  end
end

def check_fingerprint_loader_contract(failures, label, tasks)
  fingerprint_loader_contract_failures(tasks).each do |violation|
    failures << "#{label} fingerprint loader violates #{violation}"
  end
  task = fingerprint_loader_assertion_task(tasks)
  return unless task

  %w[get_checksum get_mime get_attributes].each do |option|
    removed = deep_copy(tasks)
    fingerprint_loader_stat_task(removed).fetch("ansible.builtin.stat").delete(option)
    failures << "#{label} fingerprint loader #{option} removal mutation survived" unless
      fingerprint_loader_contract_failures(removed).include?("stat.#{option}")

    altered = deep_copy(tasks)
    fingerprint_loader_stat_task(altered).fetch("ansible.builtin.stat")[option] = true
    failures << "#{label} fingerprint loader #{option} alteration mutation survived" unless
      fingerprint_loader_contract_failures(altered).include?("stat.#{option}")
  end

  loop_mutant = deep_copy(tasks)
  fingerprint_loader_assertion_task(loop_mutant)["loop"] = []
  failures << "#{label} fingerprint loader per-file loop mutation survived" unless
    fingerprint_loader_contract_failures(loop_mutant).include?("assert.loop")

  FINGERPRINT_FILE_SAFETY_PREDICATES.each do |predicate_label, predicate|
    contract_label = "assert.#{predicate_label}"
    removed = deep_copy(tasks)
    removed_conditions = fingerprint_loader_assertion_task(removed)
                         .fetch("ansible.builtin.assert").fetch("that")
    removed_conditions.reject! do |condition|
      normalized_ansible_expression(condition) == normalized_ansible_expression(predicate)
    end
    failures << "#{label} fingerprint loader #{predicate_label} removal mutation survived" unless
      fingerprint_loader_contract_failures(removed).include?(contract_label)

    altered = deep_copy(tasks)
    altered_conditions = fingerprint_loader_assertion_task(altered)
                         .fetch("ansible.builtin.assert").fetch("that")
    index = altered_conditions.index do |condition|
      normalized_ansible_expression(condition) == normalized_ansible_expression(predicate)
    end
    altered_conditions[index] = "#{predicate} and false" if index
    failures << "#{label} fingerprint loader #{predicate_label} alteration mutation survived" unless
      fingerprint_loader_contract_failures(altered).include?(contract_label)
  end

  fingerprint_atomic_reader_contract_failures(tasks).each do |violation|
    failures << "#{label} fingerprint loader violates #{violation}"
  end
  reader = task_named(tasks, FINGERPRINT_READER_TASK_NAME)
  return unless reader&.dig("ansible.builtin.command", "argv").is_a?(Array)

  {
    "readonly" => "os.O_RDONLY",
    "nofollow" => "os.O_NOFOLLOW",
    "regular" => "stat.S_ISREG(before.st_mode)",
    "mode" => "stat.S_IMODE(before.st_mode) != 0o600",
    "uid" => "before.st_uid != expected_uid",
    "gid" => "before.st_gid != expected_gid",
    "size" => "before.st_size != 65",
    "bounded" => "os.read(fd, 65)",
    "newline" => "content[64:] != b\"\\n\"",
    "lowercase" => "byte not in b\"0123456789abcdef\"",
    "fstat.before" => "before = os.fstat(fd)",
    "fstat.after" => "after = os.fstat(fd)",
    "identity" => "before_identity != after_identity",
    "stdout" => "sys.stdout.write(content[:64].decode(\"ascii\"))"
  }.each do |label_suffix, token|
    mutant = deep_copy(tasks)
    mutant_reader = task_named(mutant, FINGERPRINT_READER_TASK_NAME)
    mutant_script = mutant_reader.dig("ansible.builtin.command", "argv", 2)
    mutant_reader["ansible.builtin.command"]["argv"][2] = mutant_script.sub(token, "")
    failures << "#{label} fingerprint loader #{label_suffix} mutation survived" unless
      fingerprint_atomic_reader_contract_failures(mutant).include?("reader.#{label_suffix}")
  end
end

def check_verification_gate_contract(failures, main_tasks, verify_tasks)
  verification_gate_contract_failures(main_tasks, verify_tasks).each do |violation|
    failures << "Arr fingerprint recorder violates #{violation}"
  end
  return unless task_named(main_tasks, VERIFICATION_GATE_INIT_TASK_NAME) &&
                task_named(verify_tasks, VERIFICATION_GATE_SUCCESS_TASK_NAME)

  init_mutant = deep_copy(main_tasks)
  task_named(init_mutant, VERIFICATION_GATE_INIT_TASK_NAME)
    .fetch("ansible.builtin.set_fact")["arr_reconciliation_verification_succeeded"] = true
  failures << "Arr fingerprint recorder initialization mutation survived" unless
    verification_gate_contract_failures(init_mutant, verify_tasks).include?("gate.initialize")

  init_relocation_mutant = deep_copy(main_tasks)
  relocated_init = task_named(init_relocation_mutant, VERIFICATION_GATE_INIT_TASK_NAME)
  init_relocation_mutant.delete(relocated_init)
  reconciliation_index = init_relocation_mutant.index do |task|
    task["name"] == "Reconcile each Servarr instance"
  end
  init_relocation_mutant.insert(reconciliation_index + 1, relocated_init)
  failures << "Arr fingerprint recorder initialization-relocation mutation survived" unless
    verification_gate_contract_failures(init_relocation_mutant, verify_tasks).include?("gate.initialize")

  success_mutant = deep_copy(verify_tasks)
  task_named(success_mutant, VERIFICATION_GATE_SUCCESS_TASK_NAME)
    .fetch("ansible.builtin.set_fact")["arr_reconciliation_verification_succeeded"] = false
  failures << "Arr fingerprint recorder success mutation survived" unless
    verification_gate_contract_failures(main_tasks, success_mutant).include?("gate.success")

  removal_mutant = deep_copy(verify_tasks)
  removal_mutant.reject! { |task| task["name"] == VERIFICATION_GATE_SUCCESS_TASK_NAME }
  failures << "Arr fingerprint recorder success-removal mutation survived" unless
    verification_gate_contract_failures(main_tasks, removal_mutant).include?("gate.success")

  relocation_mutant = deep_copy(verify_tasks)
  relocated = relocation_mutant.pop
  relocation_mutant.unshift(relocated)
  failures << "Arr fingerprint recorder success-relocation mutation survived" unless
    verification_gate_contract_failures(main_tasks, relocation_mutant).include?("gate.success")

  recorder_mutant = deep_copy(main_tasks)
  recorder_when = task_named(recorder_mutant, "Persist verified Arr desired-input fingerprints")
                  .fetch("when")
  recorder_when.reject! do |condition|
    normalized_ansible_expression(condition) == normalized_ansible_expression(
      "arr_reconciliation_verification_succeeded is sameas true"
    )
  end
  failures << "Arr fingerprint recorder gate-removal mutation survived" unless
    verification_gate_contract_failures(recorder_mutant, verify_tasks).include?("gate.recorder")
end

def production_order_contract_failures(site, arr_main, arr_verify, downloader_main,
                                       downloader_verify, loader_tasks, recorder_tasks)
  failures = []
  site_roles = Array(site.first&.fetch("roles", nil))
  arr_role_index = site_roles.index { |role| role.fetch("role", nil) == "arr" }
  downloader_role_index = site_roles.index { |role| role.fetch("role", nil) == "downloaders" }
  failures << "site.role_order" unless
    arr_role_index && downloader_role_index && arr_role_index < downloader_role_index

  arr_client_read = task_named(arr_verify, "Read Servarr resources for verification")
  failures << "arr.verify.clients" if arr_client_read.to_s.include?("downloadclient")

  arr_subset = %w[
    configarr configarr_owned_state configarr_opaque_context
    prowlarr_applications prowlarr_indexers bazarr_providers
  ]
  arr_loader = task_named(arr_main, "Load private Arr desired-input fingerprints")
  arr_recorder = task_named(arr_main, "Persist verified Arr desired-input fingerprints")
  failures << "arr.loader.subset" unless
    Array(arr_loader&.dig("vars", "arr_reconciliation_fingerprint_subset")) == arr_subset
  failures << "arr.recorder.subset" unless
    Array(arr_recorder&.dig("vars", "arr_reconciliation_fingerprint_subset")) == arr_subset

  load = task_named(downloader_main, "Load private Servarr desired-input fingerprint")
  init = task_named(downloader_main, DOWNLOADER_GATE_INIT_TASK_NAME)
  reconcile = task_named(downloader_main, "Reconcile Arr download clients after SABnzbd startup")
  verify = task_named(downloader_main, "Run downloader service verification")
  record = task_named(downloader_main, "Persist verified Servarr desired-input fingerprint")
  indexes = [load, init, reconcile, verify, record].map { |task| downloader_main.index(task) }
  failures << "downloaders.order" unless indexes.none?(&:nil?) && indexes == indexes.sort
  failures << "downloaders.loader" unless
    load&.dig("ansible.builtin.include_role", "name") == "arr" &&
    load&.dig("ansible.builtin.include_role", "tasks_from") == "reconciliation_fingerprints" &&
    Array(load&.dig("vars", "arr_reconciliation_fingerprint_subset")) == ["servarr_sabnzbd"]
  failures << "downloaders.initialize" unless
    init&.dig("ansible.builtin.set_fact", "downloaders_relationship_verification_succeeded") == false &&
    init["changed_when"] == false
  record_when = Array(record&.fetch("when", nil)).map { |entry| normalized_ansible_expression(entry) }
  failures << "downloaders.recorder" unless
    record&.dig("ansible.builtin.include_role", "name") == "arr" &&
    record&.dig("ansible.builtin.include_role", "tasks_from") ==
      "record_reconciliation_fingerprints" &&
    Array(record&.dig("vars", "arr_reconciliation_fingerprint_subset")) ==
      ["servarr_sabnzbd"] &&
    record_when.include?(normalized_ansible_expression(
      "downloaders_relationship_verification_succeeded is sameas true"
    ))

  success_matches = downloader_verify.select do |task|
    task["name"] == DOWNLOADER_GATE_SUCCESS_TASK_NAME
  end
  success = success_matches.first
  failures << "downloaders.success" unless
    success_matches.length == 1 && downloader_verify.last.equal?(success) &&
    success&.dig("ansible.builtin.set_fact", "downloaders_relationship_verification_succeeded") ==
      true && success["changed_when"] == false &&
    Array(success["tags"]).include?("platform_verify_downloaders")

  stat_loop = fingerprint_loader_stat_task(loader_tasks)&.fetch("loop", nil).to_s
  failures << "loader.subset" unless stat_loop.include?("arr_reconciliation_fingerprint_subset")
  recorder_loop = task_named(recorder_tasks, FINGERPRINT_RECORD_TASK_NAME)&.fetch("loop", nil).to_s
  failures << "recorder.subset" unless
    recorder_loop.include?("arr_reconciliation_fingerprint_subset")
  failures
end

def reconciliation_tasks(kind)
  case kind
  when :application
    tasks = task_slice(
      "reconcile_prowlarr.yml", "Validate operator-owned Prowlarr application declarations",
      "Refuse duplicate Prowlarr application names before mutation"
    )
    include_task = task_named(
      YAML.safe_load_file(File.join(ARR_TASKS, "reconcile_prowlarr.yml"), aliases: true),
      "Reconcile each Prowlarr full-sync application"
    )
    include_task["ansible.builtin.include_tasks"] = File.join(
      ARR_TASKS, "reconcile_prowlarr_application.yml"
    )
    tasks + [include_task]
  when :indexer
    tasks = task_slice(
      "reconcile_prowlarr.yml", "Validate operator-owned Prowlarr indexer declarations",
      "Refuse ambiguous Prowlarr indexer names before mutation"
    )
    include_task = task_named(
      YAML.safe_load_file(File.join(ARR_TASKS, "reconcile_prowlarr.yml"), aliases: true),
      "Reconcile operator-owned Prowlarr indexers"
    )
    include_task["ansible.builtin.include_tasks"] = File.join(
      ARR_TASKS, "reconcile_prowlarr_indexer.yml"
    )
    tasks + [include_task]
  when :download_client
    tasks = task_slice(
      "reconcile_servarr_download_client.yml", "Read Servarr download clients",
      "Reconcile the owned Servarr SABnzbd client"
    )
    validation = task_named(tasks, "Validate every Servarr download client object")
    validation["ansible.builtin.include_tasks"] = File.join(
      ARR_TASKS, "validate_servarr_download_clients.yml"
    )
    tasks
  when :download_client_production
    tasks = YAML.safe_load_file(
      File.join(ARR_TASKS, "reconcile_download_clients.yml"), aliases: true
    )
    include_task = tasks.find do |task|
      task["name"] == "Reconcile each Servarr SABnzbd client after downloader startup"
    end
    include_task["ansible.builtin.include_tasks"] = File.join(
      ARR_TASKS, "reconcile_servarr_download_client.yml"
    )
    preflight = task_named(
      tasks, "Validate every Servarr download client object before shared mutation"
    )
    preflight["ansible.builtin.include_tasks"] = File.join(
      ARR_TASKS, "validate_servarr_download_clients.yml"
    )
    deep_copy(tasks)
  when :prowlarr_preflight
    tasks = YAML.safe_load_file(
      File.join(ARR_TASKS, "reconcile_prowlarr.yml"), aliases: true
    )
    {
      "Reconcile each Prowlarr full-sync application" =>
        File.join(ARR_TASKS, "reconcile_prowlarr_application.yml"),
      "Reconcile operator-owned Prowlarr indexers" =>
        File.join(ARR_TASKS, "reconcile_prowlarr_indexer.yml")
    }.each do |name, path|
      task_named(tasks, name)["ansible.builtin.include_tasks"] = path
    end
    deep_copy(tasks)
  when :bazarr
    task_slice(
      "reconcile_bazarr.yml", "Validate operator-owned Bazarr declarations",
      "Reconcile operator-owned Bazarr provider settings"
    )
  when :configarr
    task_slice(
      "configarr.yml", "Read Configarr-owned Arr resources before reconciliation",
      "Stage verified Configarr owned-state and opaque-context hashes"
    )
  else
    raise "unknown reconciliation fixture #{kind}"
  end
end

def verification_tasks(kind)
  case kind
  when :application
    task_slice(
      "verify.yml", "Read Prowlarr applications and indexers for verification",
      "Read Prowlarr applications and indexers for verification"
    ) + task_slice(
      "verify.yml", "Verify both Prowlarr applications use fullSync",
      "Verify both Prowlarr applications use fullSync"
    )
  when :indexer
    task_slice(
      "verify.yml", "Read Prowlarr applications and indexers for verification",
      "Read Prowlarr applications and indexers for verification"
    ) + task_slice(
      "verify.yml", "Verify operator-owned Prowlarr indexers exist exactly once",
      "Verify operator-owned Prowlarr indexers exist exactly once"
    )
  when :download_client, :download_client_production
    task_slice(
      "verify.yml", "Read SABnzbd configuration for verification",
      "Verify each Arr instance has one owned SABnzbd client", root: DOWNLOADER_TASKS
    )
  when :bazarr
    task_slice(
      "verify.yml", "Read Bazarr settings for verification",
      "Verify Bazarr authentication and identical-path connections"
    )
  when :configarr
    task_slice(
      "verify.yml", "Read Servarr resources for verification",
      "Stage independently verified Configarr state hashes"
    )
  else
    raise "unknown verification fixture #{kind}"
  end
end

def optional_task(filename, name, root: ARR_TASKS)
  tasks = YAML.safe_load_file(File.join(root, filename), aliases: true)
  matches = tasks.select { |task| task["name"] == name }
  matches.length == 1 ? deep_copy(matches) : []
end

def verification_gate_initialization_tasks
  tasks = YAML.safe_load_file(File.join(ARR_TASKS, "main.yml"), aliases: true)
  init_index = tasks.index { |task| task["name"] == VERIFICATION_GATE_INIT_TASK_NAME }
  reconciliation_index = tasks.index { |task| task["name"] == "Reconcile each Servarr instance" }
  return [] unless init_index && reconciliation_index && init_index < reconciliation_index

  [deep_copy(tasks.fetch(init_index))]
end

def downloader_verification_gate_initialization_tasks
  tasks = YAML.safe_load_file(File.join(DOWNLOADER_TASKS, "main.yml"), aliases: true)
  task = task_named(tasks, DOWNLOADER_GATE_INIT_TASK_NAME)
  task ? [deep_copy(task)] : []
end

def verification_success_tasks
  tasks = YAML.safe_load_file(File.join(ARR_TASKS, "verify.yml"), aliases: true)
  return [] unless tasks.last&.fetch("name", nil) == VERIFICATION_GATE_SUCCESS_TASK_NAME

  [deep_copy(tasks.last)]
end

def downloader_verification_success_tasks
  tasks = YAML.safe_load_file(File.join(DOWNLOADER_TASKS, "verify.yml"), aliases: true)
  return [] unless tasks.last&.fetch("name", nil) == DOWNLOADER_GATE_SUCCESS_TASK_NAME

  [deep_copy(tasks.last)]
end

def fingerprint_tasks_available?
  File.file?(File.join(ARR_TASKS, "reconciliation_fingerprints.yml")) &&
    File.file?(File.join(ARR_TASKS, "record_reconciliation_fingerprints.yml"))
end

def fingerprint_load_tasks
  tasks = YAML.safe_load_file(
    File.join(ARR_TASKS, "reconciliation_fingerprints.yml"), aliases: true
  )
  unless tasks.first&.fetch("name", nil) == "Compute private Arr desired-input fingerprints"
    raise "private Arr fingerprint loading boundary is unavailable"
  end

  deep_copy(tasks)
end

def fingerprint_record_tasks
  tasks = YAML.safe_load_file(
    File.join(ARR_TASKS, "record_reconciliation_fingerprints.yml"), aliases: true
  )
  unless tasks.any? { |task| task["name"] == "Record verified Arr desired-input fingerprints" }
    raise "verified Arr fingerprint recording boundary is unavailable"
  end

  deep_copy(tasks)
end

def selected_tasks(kind)
  return reconciliation_tasks(kind) if kind == :prowlarr_preflight

  if %i[download_client download_client_production].include?(kind)
    return fingerprint_load_tasks + downloader_verification_gate_initialization_tasks +
      reconciliation_tasks(kind) + verification_tasks(kind) +
      downloader_verification_success_tasks + fingerprint_record_tasks
  end

  owned_tasks = verification_gate_initialization_tasks + reconciliation_tasks(kind) +
    verification_tasks(kind) + verification_success_tasks
  return owned_tasks unless fingerprint_tasks_available?

  fingerprint_load_tasks + owned_tasks + fingerprint_record_tasks
end

def tag_filtered_fingerprint_tasks
  tasks = fingerprint_load_tasks + verification_gate_initialization_tasks +
    optional_task("main.yml", "Run Arr service verification") +
    optional_task("main.yml", "Persist verified Arr desired-input fingerprints")
  tasks.each do |task|
    task["tags"] = (Array(task["tags"]) + ["arr"]).uniq
  end
  recorder = task_named(tasks, "Persist verified Arr desired-input fingerprints")
  include_file = recorder.fetch("ansible.builtin.include_tasks")
  recorder["ansible.builtin.include_tasks"] = {
    "file" => include_file,
    "apply" => { "tags" => ["arr"] }
  }
  tasks
end

def tag_filtered_downloader_relationship_tasks
  main_tasks = YAML.safe_load_file(File.join(DOWNLOADER_TASKS, "main.yml"), aliases: true)
  names = [
    "Load private Servarr desired-input fingerprint",
    DOWNLOADER_GATE_INIT_TASK_NAME,
    "Reconcile Arr download clients after SABnzbd startup",
    "Run downloader service verification",
    "Persist verified Servarr desired-input fingerprint"
  ]
  tasks = names.map { |name| deep_copy(task_named(main_tasks, name)) }
  raise "downloader production-order tag boundary is unavailable" if tasks.any?(&:nil?)

  tasks.each do |task|
    task["tags"] = (Array(task["tags"]) + ["downloaders"]).uniq
    if (include_role = task["ansible.builtin.include_role"])
      include_role["apply"] = { "tags" => ["downloaders"] }
    elsif (include_tasks = task["ansible.builtin.include_tasks"])
      include_tasks = { "file" => include_tasks } if include_tasks.is_a?(String)
      include_tasks["apply"] ||= {}
      include_tasks["apply"]["tags"] = (
        Array(include_tasks.dig("apply", "tags")) + ["downloaders"]
      ).uniq
      task["ansible.builtin.include_tasks"] = include_tasks
    end
  end
  tasks
end

def arr_verify_only_tasks
  main = YAML.safe_load_file(File.join(ARR_TASKS, "main.yml"), aliases: true)
  verify = YAML.safe_load_file(File.join(ARR_TASKS, "verify.yml"), aliases: true)
  loader = deep_copy(task_named(main, "Load private Arr desired-input fingerprints"))
  loader["ansible.builtin.include_tasks"]["file"] = File.join(
    ARR_TASKS, "reconciliation_fingerprints.yml"
  )
  recorder = deep_copy(task_named(main, "Persist verified Arr desired-input fingerprints"))
  recorder["ansible.builtin.include_tasks"] = File.join(
    ARR_TASKS, "record_reconciliation_fingerprints.yml"
  )
  [loader, deep_copy(task_named(
    verify, "Require current opaque Arr desired-input fingerprints in verify-only runs"
  ))] + verification_tasks(:indexer) + [recorder]
end

def configarr_verify_only_tasks
  main = YAML.safe_load_file(File.join(ARR_TASKS, "main.yml"), aliases: true)
  verify = YAML.safe_load_file(File.join(ARR_TASKS, "verify.yml"), aliases: true)
  loader = deep_copy(task_named(main, "Load private Arr desired-input fingerprints"))
  loader["ansible.builtin.include_tasks"]["file"] = File.join(
    ARR_TASKS, "reconciliation_fingerprints.yml"
  )
  [loader, deep_copy(task_named(
    verify, "Require current opaque Arr desired-input fingerprints in verify-only runs"
  ))] + verification_tasks(:configarr)
end

def downloader_verify_only_tasks
  main = YAML.safe_load_file(File.join(DOWNLOADER_TASKS, "main.yml"), aliases: true)
  verify = YAML.safe_load_file(File.join(DOWNLOADER_TASKS, "verify.yml"), aliases: true)
  [
    deep_copy(task_named(main, "Load private Servarr desired-input fingerprint")),
    deep_copy(task_named(
      verify, "Require current opaque Servarr desired-input fingerprint in verify-only runs"
    ))
  ] + verification_tasks(:download_client_production) +
    downloader_verification_success_tasks +
    [deep_copy(task_named(main, "Persist verified Servarr desired-input fingerprint"))]
end

def fields_hash(object)
  Array(object&.fetch("fields", nil)).to_h { |field| [field.fetch("name"), field["value"]] }
end

def normalized_list(value)
  Array(value).sort_by(&:to_s)
end

def application_projection(object)
  fields = fields_hash(object)
  {
    "name" => object&.fetch("name", nil), "enable" => object&.fetch("enable", nil),
    "syncLevel" => object&.fetch("syncLevel", nil),
    "implementation" => object&.fetch("implementation", nil),
    "implementationName" => object&.fetch("implementationName", nil),
    "configContract" => object&.fetch("configContract", nil),
    "tags" => normalized_list(object&.fetch("tags", [])),
    "fields" => {
      "prowlarrUrl" => fields["prowlarrUrl"], "baseUrl" => fields["baseUrl"],
      "username" => fields["username"], "password" => fields["password"],
      "apiKey" => fields["apiKey"],
      "syncCategories" => normalized_list(fields["syncCategories"])
    }
  }
end

def download_client_projection(object)
  fields = fields_hash(object)
  {
    "name" => object&.fetch("name", nil), "enable" => object&.fetch("enable", nil),
    "protocol" => object&.fetch("protocol", nil), "priority" => object&.fetch("priority", nil),
    "removeCompletedDownloads" => object&.fetch("removeCompletedDownloads", nil),
    "removeFailedDownloads" => object&.fetch("removeFailedDownloads", nil),
    "implementation" => object&.fetch("implementation", nil),
    "implementationName" => object&.fetch("implementationName", nil),
    "configContract" => object&.fetch("configContract", nil),
    "tags" => normalized_list(object&.fetch("tags", [])),
    "fields" => {
      "host" => fields["host"], "port" => fields["port"]&.to_i,
      "useSsl" => fields["useSsl"], "urlBase" => fields["urlBase"],
      "apiKey" => fields["apiKey"], "username" => fields["username"],
      "password" => fields["password"],
      "movieCategory" => fields["movieCategory"].to_s,
      "tvCategory" => fields["tvCategory"].to_s
    }
  }
end

def indexer_projection(object)
  fields = fields_hash(object)
  declared_fields = INDEXER_DECLARATION.fetch("fields").to_h do |field|
    name = field.fetch("name")
    value = fields[name]
    [name, name == "categories" ? normalized_list(value) : value]
  end
  {
    "name" => object&.fetch("name", nil), "enable" => object&.fetch("enable", nil),
    "priority" => object&.fetch("priority", nil),
    "implementation" => object&.fetch("implementation", nil),
    "implementationName" => object&.fetch("implementationName", nil),
    "configContract" => object&.fetch("configContract", nil),
    "tags" => normalized_list(object&.fetch("tags", [])), "fields" => declared_fields
  }
end

def bazarr_projection(settings, provider_declarations = [])
  provider_names = provider_declarations.map { |provider| provider.fetch("name") }
  declared_providers = provider_declarations.to_h do |provider|
    name = provider.fetch("name")
    prefix = "settings-#{name}-"
    keys = provider.fetch("settings").keys.map { |key| key.delete_prefix(prefix) }
    current = settings.fetch("providers", {}).fetch(name, {})
    [name, current.slice(*keys)]
  end
  {
    "auth" => settings.fetch("auth").slice("type", "username", "password"),
    "general" => settings.fetch("general").slice(
      "use_radarr", "use_sonarr", "path_mappings", "path_mappings_movie"
    ).merge(
      "enabled_providers" => normalized_list(
        Array(settings.dig("general", "enabled_providers")).select do |name|
          provider_names.include?(name)
        end
      )
    ),
    "radarr" => settings.fetch("radarr").slice("ip", "port", "base_url", "ssl", "apikey"),
    "sonarr" => settings.fetch("sonarr").slice("ip", "port", "base_url", "ssl", "apikey"),
    "languages" => normalized_list(settings.dig("languages", "enabled")),
    "providers" => declared_providers.sort.to_h
  }
end

def quality_item_projection(item)
  if item["quality"].is_a?(Hash)
    {
      "kind" => "quality", "name" => item.dig("quality", "name"),
      "allowed" => item["allowed"]
    }
  else
    {
      "kind" => "group", "name" => item["name"], "allowed" => item["allowed"],
      "items" => Array(item["items"]).map { |child| quality_item_projection(child) }
    }
  end
end

def quality_item_tree_projection(items, label)
  identities = []
  numeric_ids = {}
  names = {}
  node_count = 0
  walk = lambda do |item, path, depth|
    raise "#{label} exceeds maximum depth 16" if depth > 16

    node_count += 1
    raise "#{label} exceeds maximum node count 512" if node_count > 512

    quality = item["quality"]
    if item.key?("quality") && !quality.nil? && !quality.is_a?(Hash)
      raise "#{label} item quality must be a mapping when present"
    end
    identity = quality.is_a?(Hash) ? quality : item
    kind = quality.is_a?(Hash) ? "quality" : "group"
    name = identity.fetch("name")
    identifier = identity.fetch("id")
    # Radarr and Sonarr number the built-in "Unknown" quality 0 and start
    # generated quality groups at 1000, so a quality may legitimately be 0
    # while a group may not.
    minimum_identifier = kind == "quality" ? 0 : 1
    unless identifier.is_a?(Integer) && identifier >= minimum_identifier
      raise "#{label} #{kind} #{name.inspect} ID must be " \
            "#{kind == 'quality' ? 'a non-negative' : 'a positive'} integer"
    end
    raise "#{label} contains duplicate numeric identities" if numeric_ids.key?(identifier)
    raise "#{label} contains duplicate named identities" if names.key?(name)

    numeric_ids[identifier] = name
    names[name] = identifier
    identity_path = path + ["#{kind}:#{name}"]
    identities << {
      "path" => identity_path, "kind" => kind, "name" => name, "id" => identifier
    }
    Array(item["items"]).each do |child|
      walk.call(child, identity_path, depth + 1)
    end
  end
  Array(items).each { |item| walk.call(item, [], 1) }
  {
    "items" => Array(items).map { |item| quality_item_projection(item) },
    "item_identities" => identities.sort_by { |item| item.fetch("path") }
  }
end

def quality_definition_projection(definition, service)
  quality_fields = %w[id name source resolution]
  quality_fields << "modifier" if service == "radarr"
  {
    "id" => definition["id"],
    "quality" => definition.fetch("quality").slice(*quality_fields),
    "title" => definition["title"],
    "weight" => definition["weight"], "minSize" => definition["minSize"],
    "preferredSize" => definition["preferredSize"], "maxSize" => definition["maxSize"]
  }
end

def quality_item_identities(items)
  Array(items).each_with_object({}) do |item, identities|
    identity = item["quality"].is_a?(Hash) ? item.fetch("quality") : item
    identities[identity.fetch("id")] = identity.fetch("name")
    identities.merge!(quality_item_identities(item.fetch("items", [])))
  end
end

def configarr_projection(settings)
  %w[radarr sonarr].to_h do |service|
    resources = settings.fetch(service)
    profiles = resources.fetch("qualityprofile")
    profile_matches = profiles.select { |profile| profile["name"] == CONFIGARR_PROFILE_NAME }
    profile = profile_matches.first if profile_matches.length == 1
    formats = resources.fetch("customformat")
    format_matches = formats.select { |format| format["name"] == CONFIGARR_FORMAT_NAME }
    custom_format = format_matches.first if format_matches.length == 1
    specifications = Array(custom_format&.fetch("specifications", nil)).map do |specification|
      {
        "name" => specification["name"],
        "implementation" => specification["implementation"],
        "negate" => specification["negate"],
        "required" => specification["required"],
        "fields" => fields_hash(specification).sort.to_h
      }
    end.sort_by { |specification| [specification["name"].to_s, specification["implementation"].to_s] }
    format_assignments = Array(profile&.fetch("formatItems", nil)).map do |format_item|
      {
        "format" => format_item["format"],
        "name" => format_item["name"], "score" => format_item["score"]
      }
    end.sort_by { |format_item| format_item.fetch("name").to_s }
    score_matches = format_assignments.select do |format_item|
      format_item["name"] == CONFIGARR_FORMAT_NAME
    end
    profile_tree = quality_item_tree_projection(
      profile&.fetch("items", []), "Configarr #{service} quality items"
    )
    cutoff_identity = quality_item_identities(profile&.fetch("items", [])).fetch(
      profile&.fetch("cutoff", nil), nil
    )
    naming_fields = service == "radarr" ?
      %w[renameMovies standardMovieFormat movieFolderFormat] :
      %w[renameEpisodes standardEpisodeFormat dailyEpisodeFormat animeEpisodeFormat
         seriesFolderFormat seasonFolderFormat]
    [service, {
      "quality_profile_identity_count" => profile_matches.length,
      "quality_profile_id" => profile&.fetch("id", nil),
      "quality_profile" => profile && {
        "name" => profile&.fetch("name", nil),
        "upgradeAllowed" => profile&.fetch("upgradeAllowed", nil),
        "cutoff" => cutoff_identity,
        "minFormatScore" => profile&.fetch("minFormatScore", nil),
        "cutoffFormatScore" => profile&.fetch("cutoffFormatScore", nil),
        "minUpgradeFormatScore" => profile&.fetch("minUpgradeFormatScore", nil),
        "items" => profile_tree.fetch("items"),
        "item_identities" => profile_tree.fetch("item_identities"),
        "format_assignment_identity_count" => score_matches.length,
        "format_assignments" => format_assignments
      },
      "quality_definitions" => resources.fetch("qualitydefinition")
        .map { |definition| quality_definition_projection(definition, service) }
        .sort_by { |definition| definition.dig("quality", "name").to_s },
      "custom_format_identity_count" => format_matches.length,
      "custom_format_id" => custom_format&.fetch("id", nil),
      "custom_format" => custom_format && {
        "name" => custom_format&.fetch("name", nil),
        "includeCustomFormatWhenRenaming" =>
          custom_format&.fetch("includeCustomFormatWhenRenaming", nil),
        "specifications" => specifications
      },
      "naming" => resources.fetch("config/naming").slice(*naming_fields)
    }]
  end
end

def configarr_expected_with_server_ids(settings, desired)
  expected = deep_copy(desired)
  %w[radarr sonarr].each do |service|
    current_profile = settings.fetch(service).fetch("qualityprofile").find do |profile|
      profile["name"] == CONFIGARR_PROFILE_NAME
    end
    current_format = settings.fetch(service).fetch("customformat").find do |format|
      format["name"] == CONFIGARR_FORMAT_NAME
    end
    [current_profile, current_format].each do |resource|
      raise "Configarr #{service} strict generated identity is unavailable" unless
        resource && resource["id"].is_a?(Integer)
    end
    %w[qualityprofile customformat].each do |resource_name|
      identifiers = settings.fetch(service).fetch(resource_name).map { |item| item["id"] }
      raise "Configarr #{service} generated identities are ambiguous" unless
        identifiers.all? { |identifier| identifier.is_a?(Integer) } &&
        identifiers.uniq.length == identifiers.length
    end
    expected_profile = expected.fetch(service).fetch("qualityprofile").find do |profile|
      profile["name"] == CONFIGARR_PROFILE_NAME
    end
    expected_format = expected.fetch(service).fetch("customformat").find do |format|
      format["name"] == CONFIGARR_FORMAT_NAME
    end
    expected_profile["id"] = current_profile.fetch("id")
    expected_format["id"] = current_format.fetch("id")
    expected_assignment = expected_profile.fetch("formatItems").find do |assignment|
      assignment["name"] == CONFIGARR_FORMAT_NAME
    end
    expected_assignment["format"] = current_format.fetch("id")
    # reset_unmatched_scores is enabled in the pinned Configarr policy. The
    # resulting score relationship therefore owns one assignment for every
    # current custom-format identity, with zero for every unmatched format.
    expected_profile["formatItems"] = settings.fetch(service).fetch("customformat").map do |format|
      if format["name"] == CONFIGARR_FORMAT_NAME
        deep_copy(expected_assignment)
      else
        { "format" => format.fetch("id"), "name" => format.fetch("name"), "score" => 0 }
      end
    end
  end
  expected
end

def configarr_quality_definition_invariants(settings)
  source_current = {}
  source_desired = {}
  opaque_context = {}
  %w[radarr sonarr].each do |service|
    source_by_name = CONFIGARR_QUALITY_DEFINITION_DOCUMENTS.fetch(service)
      .fetch("qualities").to_h { |item| [item.fetch("quality"), item] }
    source_current[service] = []
    source_desired[service] = []
    opaque_context[service] = []
    settings.fetch(service).fetch("qualitydefinition").each do |definition|
      projected = quality_definition_projection(definition, service)
      name = projected.dig("quality", "name")
      opaque = projected.slice("id", "quality", "title", "weight")
      source = source_by_name[name]
      if source
        source_current[service] << {
          "quality" => name,
          "minSize" => projected.fetch("minSize"),
          "preferredSize" => projected.fetch("preferredSize"),
          "maxSize" => projected.fetch("maxSize")
        }
        source_desired[service] << {
          "quality" => name,
          "minSize" => source.fetch("min"),
          "preferredSize" => source.fetch("preferred"),
          "maxSize" => source.fetch("max")
        }
      else
        opaque.merge!(projected.slice("minSize", "preferredSize", "maxSize"))
      end
      opaque_context[service] << opaque
    end
    source_current[service].sort_by! { |item| item.fetch("quality") }
    source_desired[service].sort_by! { |item| item.fetch("quality") }
    opaque_context[service].sort_by! do |item|
      [item.dig("quality", "name").to_s, item.fetch("id")]
    end
  end
  {
    "source_current" => source_current,
    "source_desired" => source_desired,
    "opaque_context" => opaque_context
  }
end

def configarr_opaque_fingerprint(settings)
  projection = configarr_quality_definition_invariants(settings).fetch("opaque_context")
  Digest::SHA256.hexdigest(ansible_json(projection))
end

def set_field!(object, name, value)
  field = object.fetch("fields").find { |candidate| candidate["name"] == name }
  raise "fixture field #{name} is unavailable" unless field

  field["value"] = value
end

def remove_field!(object, name)
  before = object.fetch("fields").length
  object.fetch("fields").reject! { |field| field["name"] == name }
  raise "fixture field #{name} is unavailable" if object.fetch("fields").length == before
end

class AcquisitionApi
  attr_reader :port, :requests, :state, :error, :unexpected_requests

  class SocketDeadlineExceeded < StandardError; end

  def initialize(state, fail_configarr: false, partial_configarr: false, fail_client_service: nil,
                 corrupt_client_verification: false, mask_bazarr_provider_secrets: false,
                 fail_custom_format_service: nil, malformed_custom_format_service: nil)
    @state = state
    @fail_configarr = fail_configarr
    @partial_configarr = partial_configarr
    @fail_client_service = fail_client_service
    @corrupt_client_verification = corrupt_client_verification
    @mask_bazarr_provider_secrets = mask_bazarr_provider_secrets
    @fail_custom_format_service = fail_custom_format_service
    @malformed_custom_format_service = malformed_custom_format_service
    @client_get_counts = Hash.new(0)
    @requests = []
    @unexpected_requests = []
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr.fetch(1)
    @stopped = false
    @clients = []
    @clients_mutex = Mutex.new
    @thread = Thread.new { serve }
  end

  def close
    @stopped = true
    @server.close unless @server.closed?
    @clients_mutex.synchronize do
      @clients.each do |client|
        begin
          client.close unless client.closed?
        rescue IOError, Errno::EBADF
          nil
        end
      end
    end
    return if @thread&.join(SOCKET_DEADLINE_SECONDS)

    @thread.kill
    @thread.join(SOCKET_DEADLINE_SECONDS)
    @error ||= SocketDeadlineExceeded.new("fixture server thread did not stop")
  rescue IOError, Errno::EBADF
    unless @thread&.join(SOCKET_DEADLINE_SECONDS)
      @thread&.kill
      @thread&.join(SOCKET_DEADLINE_SECONDS)
      @error ||= SocketDeadlineExceeded.new("fixture server thread did not stop")
    end
  end

  def apply_configarr
    desired_state = @state.fetch("configarr_desired")
    %w[radarr sonarr].each do |service|
      resources = @state.fetch("configarr").fetch(service)
      desired = desired_state.fetch(service)
      profile = resources.fetch("qualityprofile").find do |item|
        item["name"] == CONFIGARR_PROFILE_NAME
      end
      if profile && profile.fetch("formatItems").none? { |item| item["name"] == CONFIGARR_FORMAT_NAME }
        # Configarr v1.28.0 spreads an absent item and submits only {score};
        # pinned Servarr rejects the resulting profile body.
        return false
      end

      desired_format = desired.fetch("customformat").find do |item|
        item["name"] == CONFIGARR_FORMAT_NAME
      end
      format = resources.fetch("customformat").find do |item|
        item["name"] == CONFIGARR_FORMAT_NAME
      end
      if format
        format_id = format.fetch("id")
        format.replace(deep_copy(desired_format).merge("id" => format_id))
      else
        format = deep_copy(desired_format)
        format["id"] = resources.fetch("customformat").map { |item| item.fetch("id", 0) }.max + 1
        resources.fetch("customformat") << format
      end

      desired_definitions = desired.fetch("qualitydefinition").to_h do |definition|
        [definition.dig("quality", "name"), definition]
      end
      resources.fetch("qualitydefinition").each do |definition|
        name = definition.dig("quality", "name")
        next unless quality_sizes_for(service).key?(name)

        expected = desired_definitions.fetch(name)
        %w[minSize preferredSize maxSize].each { |field| definition[field] = expected[field] }
      end

      resources.fetch("config/naming").merge!(desired.fetch("config/naming").reject do |field, _value|
        field == "id"
      end)

      desired_profile = desired.fetch("qualityprofile").find do |item|
        item["name"] == CONFIGARR_PROFILE_NAME
      end
      if profile.nil?
        profile = deep_copy(desired_profile)
        profile["id"] = resources.fetch("qualityprofile").map { |item| item.fetch("id", 0) }.max + 1
        current_formats = resources.fetch("customformat").to_h { |item| [item.fetch("name"), item] }
        profile.fetch("formatItems").each do |item|
          item["format"] = current_formats.fetch(item.fetch("name")).fetch("id")
        end
        resources.fetch("qualityprofile") << profile
        next
      end

      if profile_quality_shape(profile.fetch("items")) !=
         profile_quality_shape(desired_profile.fetch("items"))
        profile["items"] = deep_copy(desired_profile.fetch("items"))
      end
      %w[upgradeAllowed cutoff minFormatScore cutoffFormatScore minUpgradeFormatScore].each do |field|
        profile[field] = desired_profile.fetch(field)
      end
      profile.fetch("formatItems").each do |item|
        item["score"] = item["name"] == CONFIGARR_FORMAT_NAME ? 10 : 0
      end
    end
    true
  end

  def quality_sizes_for(service)
    # Keep the fake tied to the exact pinned source constants used to build the
    # expected response rather than replacing entire resources synthetically.
    CONFIGARR.fetch(service).fetch("qualitydefinition").filter_map do |definition|
      name = definition.dig("quality", "name")
      [name, true] unless name == "Raw-HD"
    end.to_h
  end

  def profile_quality_shape(items)
    items.map do |item|
      if item["quality"].is_a?(Hash)
        ["quality", item.dig("quality", "name")]
      else
        ["group", item["name"], profile_quality_shape(item.fetch("items"))]
      end
    end
  end

  def update_configarr_profile(service, id, body)
    profile = JSON.parse(body)
    raise "fixture profile body id differs" unless profile.fetch("id") == id

    formats = @state.dig("configarr", service, "customformat")
    expected_ids = formats.map { |item| item.fetch("id") }.sort
    actual_ids = profile.fetch("formatItems").map { |item| item.fetch("format") }.sort
    raise "fixture profile body does not preserve every custom format" unless actual_ids == expected_ids

    profiles = @state.dig("configarr", service, "qualityprofile")
    index = profiles.index { |item| item.fetch("id") == id }
    raise "fixture profile repair target is unavailable" unless index
    existing = profiles.fetch(index)
    %w[unmanagedProfileField language].each do |field|
      next unless existing.key?(field)
      raise "fixture profile repair changed unrelated field #{field}" unless
        profile[field] == existing[field]
    end

    profiles[index] = profile
  end

  def accepted_client_count
    @clients_mutex.synchronize { @clients.length }
  end

  private

  def serve
    until @stopped
      next unless IO.select([@server], nil, nil, 0.05)

      client = @server.accept
      @clients_mutex.synchronize { @clients << client }
      begin
        handle(client)
      ensure
        @clients_mutex.synchronize { @clients.delete(client) }
        client.close unless client.closed?
      end
    end
  rescue IOError, Errno::EBADF
    nil
  rescue StandardError => caught
    @error = caught unless @stopped
  end

  def handle(client)
    method, target, body = read_request(client)
    request = { "method" => method, "target" => target, "body" => body }
    @requests << request

    case [method, target]
    when ["GET", "/api/v1/config/host"]
      send_json(client, 200, @state.fetch("prowlarr_host", {
        "id" => 1,
        "authenticationMethod" => "forms",
        "authenticationRequired" => "enabled",
        "username" => "fixture-prowlarr-admin",
        "launchBrowser" => false
      }))
    when ["PUT", "/api/v1/config/host/1"]
      @state["prowlarr_host"] = JSON.parse(body)
      send_json(client, 200, @state.fetch("prowlarr_host"))
    when ["GET", "/api/v1/applications"]
      send_json(client, 200, @state.fetch("applications", []).map { |item| public_item(item, :application) })
    when ["POST", "/api/v1/applications"]
      item = create_item("applications", body)
      send_json(client, 201, public_item(item, :application))
    when ["GET", "/api/v1/indexer"]
      send_json(client, 200, @state.fetch("indexers", []).map { |item| public_item(item, :indexer) })
    when ["POST", "/api/v1/indexer"]
      item = create_item("indexers", body)
      send_json(client, 201, public_item(item, :indexer))
    when ["GET", "/api/v3/downloadclient"]
      send_json(client, 200, @state.fetch("download_clients", []).map { |item| public_item(item, :client) })
    when ["POST", "/api/v3/downloadclient"]
      item = create_item("download_clients", body)
      send_json(client, 201, public_item(item, :client))
    when ["GET", "/api/system/settings"]
      send_json(client, 200, public_bazarr)
    when ["GET", "/api/system/languages"]
      send_json(client, 200, public_bazarr_languages)
    when ["POST", "/api/system/settings"]
      request["form"] = URI.decode_www_form(body)
      apply_bazarr(request.fetch("form"))
      send_empty(client, 204)
    when ["POST", "/_fixture/configarr/apply"]
      if @fail_configarr
        send_json(client, 500, { "error" => "fixture Configarr failure" })
      elsif @partial_configarr
        send_empty(client, 204)
      else
        if apply_configarr
          send_empty(client, 204)
        else
          send_json(client, 500, { "error" => "pinned Configarr profile update failed" })
        end
      end
    else
      if method == "PUT" && target.match?(%r{\A/api/v1/applications/\d+\z})
        item = update_item("applications", target, body)
        send_json(client, 200, public_item(item, :application))
      elsif method == "PUT" && target.match?(%r{\A/api/v1/indexer/\d+\z})
        item = update_item("indexers", target, body)
        send_json(client, 200, public_item(item, :indexer))
      elsif method == "PUT" && target.match?(%r{\A/api/v3/downloadclient/\d+\z})
        item = update_item("download_clients", target, body)
        send_json(client, 200, public_item(item, :client))
      elsif method == "GET" && target.start_with?("/sabnzbd/api?")
        query = URI.decode_www_form(target.split("?", 2).last).to_h
        unless query.slice("mode", "output") == { "mode" => "get_config", "output" => "json" }
          raise "fixture SABnzbd verification query differs"
        end
        send_json(client, 200, @state.fetch("sabnzbd", SABNZBD))
      elsif method == "GET" && (match = target.match(
        %r{\A/(radarr|sonarr)/api/v3/downloadclient\z}
      ))
        service = match[1]
        collection = "#{service}_download_clients"
        fallback = service == "radarr" ? DOWNLOAD_CLIENT : SONARR_DOWNLOAD_CLIENT
        items = @state.fetch(collection, [fallback])
        @client_get_counts[service] += 1
        if @corrupt_client_verification && @client_get_counts[service] >= 2
          items = deep_copy(items)
          items.first["enable"] = false if items.first
        end
        send_json(client, 200, items.map { |item| public_item(item, :client) })
      elsif method == "GET" && (match = target.match(
        %r{\A/(radarr|sonarr)/api/v3/(config/host|rootfolder)\z}
      ))
        response = if match[2] == "config/host"
                     { "authenticationMethod" => "Forms", "authenticationRequired" => "Enabled" }
                   else
                     instance = match[1] == "radarr" ? SERVARR_INSTANCE : SONARR_INSTANCE
                     [{ "path" => instance.fetch("root_folder") }]
                   end
        send_json(client, 200, response)
      elsif method == "GET" && (match = target.match(
        %r{\A/(radarr|sonarr)/api/v3/(qualityprofile|qualitydefinition|customformat|config/naming)\z}
      ))
        send_json(client, 200, @state.fetch("configarr").fetch(match[1]).fetch(match[2]))
      elsif method == "POST" && (match = target.match(
        %r{\A/(radarr|sonarr)/api/v3/downloadclient\z}
      ))
        if @fail_client_service == match[1]
          send_json(client, 500, { "error" => "fixture client write failure" })
          return
        end
        item = create_item("#{match[1]}_download_clients", body)
        send_json(client, 201, public_item(item, :client))
      elsif method == "POST" && (match = target.match(
        %r{\A/(radarr|sonarr)/api/v3/customformat\z}
      ))
        if @fail_custom_format_service == match[1]
          send_json(client, 500, { "error" => "fixture custom-format create failure" })
          return
        end
        item = JSON.parse(body)
        formats = @state.dig("configarr", match[1], "customformat")
        raise "fixture duplicate custom-format create" if formats.any? { |entry| entry["name"] == item["name"] }
        expected = @state.dig("configarr_desired", match[1], "customformat").find do |entry|
          entry["name"] == CONFIGARR_FORMAT_NAME
        end.reject { |field, _value| field == "id" }
        raise "fixture custom-format create body differs" unless item == expected

        item["id"] = if @malformed_custom_format_service == match[1]
                       formats.first&.fetch("id", nil)
                     else
                       formats.map { |entry| entry.fetch("id", 0) }.max.to_i + 1
                     end
        formats << item
        send_json(client, 201, item)
      elsif method == "PUT" && (match = target.match(
        %r{\A/(radarr|sonarr)/api/v3/downloadclient/\d+\z}
      ))
        if @fail_client_service == match[1]
          send_json(client, 500, { "error" => "fixture client write failure" })
          return
        end
        item = update_item("#{match[1]}_download_clients", target, body)
        send_json(client, 200, public_item(item, :client))
      elsif method == "PUT" && (match = target.match(
        %r{\A/(radarr|sonarr)/api/v3/qualityprofile/(\d+)\z}
      ))
        update_configarr_profile(match[1], match[2].to_i, body)
        send_empty(client, 202)
      else
        @unexpected_requests << [method, target]
        send_json(client, 400, { "error" => "unexpected fixture request" })
      end
    end
  end

  def read_request(client)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SOCKET_DEADLINE_SECONDS
    bytes = +""
    until (boundary = bytes.index("\r\n\r\n") || bytes.index("\n\n"))
      bytes << read_chunk(client, deadline)
      raise "fixture request headers are too large" if bytes.bytesize > 64 * 1024
    end
    separator_length = bytes[boundary, 4] == "\r\n\r\n" ? 4 : 2
    header_bytes = bytes.byteslice(0, boundary)
    body = bytes.byteslice(boundary + separator_length..) || +""
    lines = header_bytes.split(/\r?\n/)
    method, target, = lines.shift.to_s.split(" ", 3)
    headers = lines.to_h do |line|
      key, value = line.split(":", 2)
      [key.to_s.downcase, value.to_s.strip]
    end
    length = Integer(headers.fetch("content-length", "0"), 10)
    raise "fixture request body is too large" if length > 1024 * 1024

    body << read_chunk(client, deadline) while body.bytesize < length
    [method, target, body.byteslice(0, length)]
  end

  def read_chunk(client, deadline)
    remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raise SocketDeadlineExceeded, "fixture client read exceeded deadline" if remaining <= 0
    unless IO.select([client], nil, nil, remaining)
      raise SocketDeadlineExceeded, "fixture client read exceeded deadline"
    end

    chunk = client.read_nonblock(16 * 1024, exception: false)
    raise EOFError, "fixture client closed an incomplete request" if chunk.nil?
    return read_chunk(client, deadline) if chunk == :wait_readable

    chunk
  end

  def write_response(client, bytes)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SOCKET_DEADLINE_SECONDS
    offset = 0
    while offset < bytes.bytesize
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise SocketDeadlineExceeded, "fixture client write exceeded deadline" if remaining <= 0
      unless IO.select(nil, [client], nil, remaining)
        raise SocketDeadlineExceeded, "fixture client write exceeded deadline"
      end

      written = client.write_nonblock(bytes.byteslice(offset..), exception: false)
      next if written == :wait_writable

      offset += written
    end
  end

  def create_item(collection, body)
    item = JSON.parse(body)
    next_id = @state.fetch(collection, []).map { |entry| entry.fetch("id", 0).to_i }.max.to_i + 1
    item["id"] ||= next_id
    @state[collection] ||= []
    @state.fetch(collection) << item
    item
  end

  def update_item(collection, target, body)
    id = target.split("/").last.to_i
    item = JSON.parse(body)
    item["id"] = id
    index = @state.fetch(collection).index { |entry| entry.fetch("id").to_i == id }
    raise "fixture update target is unavailable" unless index

    @state.fetch(collection)[index] = item
  end

  def public_item(item, kind)
    copy = deep_copy(item)
    secret_names = case kind
                   when :application then copy.fetch("fields", []).filter_map do |field|
                     field["name"] if field["name"].to_s.match?(/(?:api.?key|password|token|secret)/i)
                   end
                   when :client then %w[apiKey username password]
                   when :indexer then copy.fetch("fields", []).filter_map do |field|
                     field["name"] if field["name"].to_s.match?(/(?:api.?key|password|token|secret)/i)
                   end
                   end
    copy.fetch("fields", []).each do |field|
      field["value"] = "********" if secret_names.include?(field["name"]) && !field["value"].to_s.empty?
    end
    copy
  end

  def public_bazarr
    copy = deep_copy(@state.fetch("bazarr"))
    copy.dig("auth")["password"] = Digest::MD5.hexdigest(copy.dig("auth", "password")) if
      copy.dig("auth").key?("password")
    copy.delete("languages")
    providers = copy.delete("providers") || {}
    providers.each do |provider_name, settings|
      settings.each_key do |name|
        if @mask_bazarr_provider_secrets && name.match?(/(?:api.?key|password|token|secret)/i)
          settings[name] = "********"
        end
      end
      copy[provider_name] = settings
    end
    copy
  end

  def public_bazarr_languages
    enabled = Array(@state.dig("bazarr", "languages", "enabled"))
    (enabled | %w[de en fr]).sort.map do |code|
      { "name" => "Fixture #{code}", "code2" => code, "code3" => "#{code}x",
        "enabled" => enabled.include?(code) }
    end
  end

  def apply_bazarr(pairs)
    values = pairs.group_by(&:first).transform_values do |entries|
      entries.length == 1 ? entries.first.last : entries.map(&:last)
    end
    if values.key?("settings-auth-type")
      apply_bazarr_connections(values)
    else
      apply_bazarr_provider(values)
    end
  end

  def apply_bazarr_connections(values)
    settings = @state.fetch("bazarr")
    settings["auth"] = {
      "type" => values.fetch("settings-auth-type"),
      "username" => values.fetch("settings-auth-username"),
      "password" => values.fetch("settings-auth-password")
    }
    settings["general"] = {
      "use_radarr" => boolean(values.fetch("settings-general-use_radarr")),
      "use_sonarr" => boolean(values.fetch("settings-general-use_sonarr")),
      "path_mappings" => list_value(values.fetch("settings-general-path_mappings")),
      "path_mappings_movie" => list_value(values.fetch("settings-general-path_mappings_movie")),
      "enabled_providers" => list_value(values.fetch("settings-general-enabled_providers"))
    }
    %w[radarr sonarr].each do |service|
      settings[service] = {
        "ip" => values.fetch("settings-#{service}-ip"),
        "port" => values.fetch("settings-#{service}-port").to_i,
        "base_url" => values.fetch("settings-#{service}-base_url"),
        "ssl" => boolean(values.fetch("settings-#{service}-ssl")),
        "apikey" => values.fetch("settings-#{service}-apikey")
      }
    end
    settings["languages"] = {
      "enabled" => list_value(values.fetch("languages-enabled"))
    }
  end

  def apply_bazarr_provider(values)
    provider_names = @state.fetch("bazarr").dig("general", "enabled_providers")
    name = provider_names.find do |candidate|
      values.keys.any? { |key| key.start_with?("settings-#{candidate}-") }
    end
    raise "fixture provider payload has no declared owner" unless name

    prefix = "settings-#{name}-"
    submitted = values.to_h do |key, value|
      setting = key.delete_prefix(prefix)
      normalized = if %w[exclude].include?(setting)
                     list_value(value)
                   elsif %w[use_hash include_ai_translated include_machine_translated].include?(setting)
                     boolean(value)
                   elsif value.is_a?(String) && value.match?(/\A[+-]?\d+\z/) &&
                         !%w[password f_password hashed_password].include?(setting)
                     value.to_i
                   else
                     value
                   end
      [setting, normalized]
    end
    current = @state.fetch("bazarr").fetch("providers").fetch(name, {})
    @state.fetch("bazarr").fetch("providers")[name] = current.merge(submitted)
  end

  def boolean(value)
    value.to_s == "true"
  end

  def list_value(value)
    values = Array(value).flat_map do |entry|
      stripped = entry.to_s.strip
      if stripped.start_with?("[") && stripped.end_with?("]")
        stripped[1..-2].split(",").map do |part|
          part.strip.delete_prefix("'").delete_suffix("'").delete_prefix('"').delete_suffix('"')
        end
      else
        stripped
      end
    end
    values.reject { |entry| entry == "null" || entry.empty? }
  end

  def send_json(client, status, value)
    body = JSON.generate(value)
    send_response(client, status, body, "application/json")
  end

  def send_empty(client, status)
    send_response(client, status, "", "text/plain")
  end

  def send_response(client, status, body, content_type)
    reason = {
      200 => "OK", 201 => "Created", 202 => "Accepted", 204 => "No Content",
      400 => "Bad Request", 500 => "Internal Server Error"
    }.fetch(status)
    write_response(
      client,
      "HTTP/1.1 #{status} #{reason}\r\nContent-Type: #{content_type}\r\n" \
      "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
    )
  end
end

def normalized_form_list(value)
  Array(value).flat_map do |entry|
    stripped = entry.to_s.strip
    if stripped.start_with?("[") && stripped.end_with?("]")
      stripped[1..-2].split(",").map do |part|
        part.strip.delete_prefix("'").delete_suffix("'").delete_prefix('"').delete_suffix('"')
      end
    else
      stripped
    end
  end.reject { |entry| entry == "null" || entry.empty? }
end

def decoded_form(request)
  request.fetch("form").group_by(&:first).transform_values do |entries|
    entries.length == 1 ? entries.first.last : entries.map(&:last)
  end
end

def canonical_bazarr_connection_body?(request, providers)
  form = decoded_form(request)
  expected_scalars = {
    "settings-auth-type" => "form",
    "settings-auth-username" => "fixture-bazarr-admin",
    "settings-auth-password" => SECRETS.fetch("bazarr_admin"),
    "settings-general-use_radarr" => "true", "settings-general-use_sonarr" => "true",
    "settings-radarr-ip" => "radarr", "settings-radarr-port" => "7878",
    "settings-radarr-base_url" => "", "settings-radarr-ssl" => "false",
    "settings-radarr-apikey" => SECRETS.fetch("radarr"),
    "settings-sonarr-ip" => "sonarr", "settings-sonarr-port" => "8989",
    "settings-sonarr-base_url" => "", "settings-sonarr-ssl" => "false",
    "settings-sonarr-apikey" => SECRETS.fetch("sonarr")
  }
  list_keys = %w[
    settings-general-path_mappings settings-general-path_mappings_movie
    languages-enabled settings-general-enabled_providers
  ]
  return false unless form.keys.sort == (expected_scalars.keys + list_keys).sort
  return false unless expected_scalars.all? { |key, value| form[key] == value }

  normalized_form_list(form.fetch("settings-general-path_mappings")).empty? &&
    normalized_form_list(form.fetch("settings-general-path_mappings_movie")).empty? &&
    normalized_form_list(form.fetch("languages-enabled")).sort == %w[de en] &&
    normalized_form_list(form.fetch("settings-general-enabled_providers")).sort == providers.sort
end

def canonical_bazarr_provider_body?(request)
  decoded_form(request) == BAZARR_PROVIDER.fetch("settings")
end

def canonical_bazarr_complete_write_set?(requests, providers)
  connection_requests = requests.select do |request|
    canonical_bazarr_connection_body?(request, providers.map { |provider| provider.fetch("name") })
  end
  provider_requests = requests.select { |request| canonical_bazarr_provider_body?(request) }
  connection_requests.length == 1 && provider_requests.length == providers.length &&
    requests.length == connection_requests.length + provider_requests.length
end

def canonical_application_secret_writes?(requests)
  expected_by_name = [APPLICATION, SONARR_APPLICATION].to_h do |application|
    [application.fetch("name"), application]
  end
  bodies = requests.map { |request| JSON.parse(request.fetch("body")) }
  return false unless bodies.map { |body| body["name"] }.sort == expected_by_name.keys.sort

  bodies.all? do |body|
    expected = expected_by_name.fetch(body.fetch("name"))
    body.keys.sort == expected.keys.sort &&
      fields_hash(body).keys.sort == fields_hash(expected).keys.sort &&
      application_projection(body) == application_projection(expected) &&
      fields_hash(body).fetch("apiKey") == fields_hash(expected).fetch("apiKey")
  end
rescue JSON::ParserError, KeyError
  false
end

def canonical_production_client_writes?(requests)
  expected_by_service = {
    "radarr" => DOWNLOAD_CLIENT, "sonarr" => SONARR_DOWNLOAD_CLIENT
  }
  return false unless requests.length == expected_by_service.length

  requests.all? do |request|
    service = request.fetch("target")[%r{\A/(radarr|sonarr)/api/v3/downloadclient}, 1]
    next false unless service

    body = JSON.parse(request.fetch("body"))
    expected = expected_by_service.fetch(service)
    body.keys.reject { |key| key == "id" }.sort ==
      expected.keys.reject { |key| key == "id" }.sort &&
      fields_hash(body).keys.sort == fields_hash(expected).keys.sort &&
      download_client_projection(body) == download_client_projection(expected) &&
      %w[apiKey username password].all? do |field|
        fields_hash(body).fetch(field) == fields_hash(expected).fetch(field)
      end
  end
rescue JSON::ParserError, KeyError
  false
end

def base_variables(port)
  variables = {
    "arr_prowlarr_api" => "http://127.0.0.1:#{port}/api/v1",
    "arr_prowlarr_internal_url" => "http://prowlarr:9696",
    "arr_prowlarr_application_sync_level" => "fullSync",
    "arr_prowlarr_applications" => [
      deep_copy(APPLICATION_DECLARATION), deep_copy(SONARR_APPLICATION_DECLARATION)
    ],
    "vault_arr_prowlarr_api_key" => "fixture-prowlarr-control-key",
    "vault_arr_prowlarr_admin_username" => "fixture-prowlarr-admin",
    "vault_arr_prowlarr_admin_password" => "fixture-prowlarr-admin-password",
    "media_arr_indexers" => [deep_copy(INDEXER_DECLARATION)],
    "arr_servarr_instance" => deep_copy(SERVARR_INSTANCE).merge(
      "api" => "http://127.0.0.1:#{port}/api/v3"
    ),
    "arr_sabnzbd_client_name" => "SABnzbd", "arr_sabnzbd_host" => "sabnzbd",
    "arr_sabnzbd_port" => 8080,
    "vault_downloaders_sabnzbd_api_key" => SECRETS.fetch("sab_api"),
    "vault_downloaders_sabnzbd_admin_username" => SECRETS.fetch("sab_username"),
    "vault_downloaders_sabnzbd_admin_password" => SECRETS.fetch("sab_password"),
    "downloaders_sabnzbd_api" => "http://127.0.0.1:#{port}/sabnzbd/api",
    "downloaders_sabnzbd_categories" => { "movies" => "movies", "series" => "series" },
    "downloaders_sabnzbd_owned_misc" => {
      "complete_dir" => "/data/complete", "download_dir" => "/data/incomplete"
    },
    "arr_bazarr_api" => "http://127.0.0.1:#{port}/api",
    "vault_arr_bazarr_api_key" => "fixture-bazarr-control-key",
    "vault_arr_bazarr_admin_username" => "fixture-bazarr-admin",
    "vault_arr_bazarr_admin_password" => SECRETS.fetch("bazarr_admin"),
    "vault_arr_radarr_api_key" => SECRETS.fetch("radarr"),
    "vault_arr_sonarr_api_key" => SECRETS.fetch("sonarr"),
    "media_bazarr_languages" => %w[en de], "media_bazarr_providers" => [],
    "media_arr_automatic_rename_enabled" => false,
    "media_usenet_enabled" => true,
    "platform_runtime_dir" => nil, "role_path" => File.join(ROOT, "roles", "arr"),
    "nas_uid" => Process.uid, "nas_gid" => Process.gid,
    "arr_installed_reconciliation_fingerprints" => {
      "prowlarr_applications" => "same", "servarr_sabnzbd" => "same",
      "prowlarr_indexers" => "same", "bazarr_providers" => "same", "configarr" => "same"
    },
    "arr_desired_reconciliation_fingerprints" => {
      "prowlarr_applications" => "same", "servarr_sabnzbd" => "same",
      "prowlarr_indexers" => "same", "bazarr_providers" => "same", "configarr" => "same"
    }
  }
  variables["arr_servarr_instances"] = [deep_copy(variables.fetch("arr_servarr_instance"))]
  variables
end

def write_fake_configarr_module(collection_root)
  module_directory = File.join(
    collection_root, "ansible_collections", "community", "docker", "plugins", "modules"
  )
  FileUtils.mkdir_p(module_directory)
  File.write(
    File.join(module_directory, "docker_compose_v2_run.py"),
    <<~PYTHON,
      #!/usr/bin/python
      import os
      import urllib.error
      import urllib.request
      from ansible.module_utils.basic import AnsibleModule

      module = AnsibleModule(argument_spec={
          "project_src": {"type": "str"}, "project_name": {"type": "str"},
          "files": {"type": "list"}, "env_files": {"type": "list"},
          "profiles": {"type": "list"}, "service": {"type": "str"},
          "cleanup": {"type": "bool"}, "no_deps": {"type": "bool"},
          "detach": {"type": "bool"}, "service_ports": {"type": "bool"},
          "interactive": {"type": "bool"}, "tty": {"type": "bool"},
      }, supports_check_mode=True)
      request = urllib.request.Request(
          os.environ["ACQUISITION_FIXTURE_APPLY_URL"], data=b"", method="POST"
      )
      try:
          with urllib.request.urlopen(request, timeout=10):
              pass
          module.exit_json(
              changed=False, rc=0, stdout="fixture Configarr applied", stderr="",
              stdout_lines=["fixture Configarr applied"], stderr_lines=[]
          )
      except urllib.error.HTTPError:
          module.exit_json(
              changed=False, rc=1, stdout="", stderr="fixture Configarr failed",
              stdout_lines=[], stderr_lines=["fixture Configarr failed"]
          )
    PYTHON
    mode: "w", perm: 0o700
  )
end

def write_playbook(path, variables, tasks)
  File.write(
    path,
    YAML.dump([{
      "hosts" => "localhost", "gather_facts" => false,
      "vars" => variables, "tasks" => tasks
    }]),
    mode: "w", perm: 0o600
  )
end

def write_event_callback(root)
  callback_directory = File.join(root, "callback_plugins")
  FileUtils.mkdir_p(callback_directory)
  File.write(
    File.join(callback_directory, "acquisition_fixture_events.py"),
    <<~PYTHON,
      import json
      import os
      from ansible.plugins.callback import CallbackBase

      class CallbackModule(CallbackBase):
          CALLBACK_VERSION = 2.0
          CALLBACK_TYPE = "aggregate"
          CALLBACK_NAME = "acquisition_fixture_events"
          CALLBACK_NEEDS_ENABLED = True

          def _record(self, event, result):
              payload = {
                  "event": event,
                  "task": result.task.name,
                  "changed": bool(result.result.get("changed", False)),
              }
              with open(os.environ["ACQUISITION_FIXTURE_EVENT_LOG"], "a", encoding="utf-8") as log:
                  log.write(json.dumps(payload) + "\\n")

          def v2_runner_on_ok(self, result):
              self._record("ok", result)

          def v2_runner_on_failed(self, result, ignore_errors=False):
              self._record("failed", result)

          def v2_runner_on_unreachable(self, result):
              self._record("unreachable", result)

          def v2_runner_on_skipped(self, result):
              self._record("skipped", result)
    PYTHON
    mode: "w", perm: 0o600
  )
  callback_directory
end

def capture_process(env, *argv, chdir:, timeout:)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  timed_out = false
  stdin, stdout, stderr, wait_thread = Open3.popen3(
    env, *argv, chdir: chdir, pgroup: true
  )
  stdin.close
  stdout_thread = Thread.new do
    stdout.read
  rescue IOError
    ""
  end
  stderr_thread = Thread.new do
    stderr.read
  rescue IOError
    ""
  end
  reaped = wait_thread.join(timeout)
  unless reaped
    timed_out = true
    begin
      Process.kill("TERM", -wait_thread.pid)
    rescue Errno::ESRCH
      nil
    end
    reaped = wait_thread.join(PROCESS_TERM_GRACE_SECONDS)
    unless reaped
      begin
        Process.kill("KILL", -wait_thread.pid)
      rescue Errno::ESRCH
        nil
      end
      reaped = wait_thread.join(PROCESS_TERM_GRACE_SECONDS)
    end
  end
  unless reaped
    stdout.close unless stdout.closed?
    stderr.close unless stderr.closed?
  end
  readers = [stdout_thread, stderr_thread]
  readers.each do |reader|
    next if reader.join(PROCESS_TERM_GRACE_SECONDS)

    begin
      Process.kill("KILL", -wait_thread.pid)
    rescue Errno::ESRCH
      nil
    end
    reader.kill
    reader.join(PROCESS_TERM_GRACE_SECONDS)
  end
  {
    "stdout" => (stdout_thread.value.to_s unless stdout_thread.alive?).to_s,
    "stderr" => (stderr_thread.value.to_s unless stderr_thread.alive?).to_s,
    "status" => (wait_thread.value if reaped), "timed_out" => timed_out,
    "reaped" => !reaped.nil?,
    "elapsed" => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  }
ensure
  stdin&.close unless stdin&.closed?
  stdout&.close unless stdout&.closed?
  stderr&.close unless stderr&.closed?
end

def run_playbook(path, env, *arguments)
  event_log = env.fetch("ACQUISITION_FIXTURE_EVENT_LOG")
  File.write(event_log, "", mode: "w", perm: 0o600)
  process = capture_process(
    env, ANSIBLE_PLAYBOOK, "-i", "localhost,", "-c", "local", path, *arguments,
    chdir: ROOT, timeout: PLAYBOOK_TIMEOUT_SECONDS
  )
  events = File.readlines(event_log, chomp: true).map { |line| JSON.parse(line) }
  process.merge(
    "changed" => process.fetch("stdout").scan(/changed=(\d+)/).flatten.last&.to_i,
    "task_events" => events,
    "harness_error" => if process.fetch("timed_out") || !process.fetch("reaped")
                         "Ansible playbook exceeded #{PLAYBOOK_TIMEOUT_SECONDS}s deadline"
                       end
  )
end

def fingerprint_snapshot(runtime)
  directory = File.join(runtime, "services", "arr")
  FINGERPRINT_FILES.to_h do |filename|
    path = File.join(directory, filename)
    stat = File.lstat(path) if File.exist?(path) || File.symlink?(path)
    value = if stat
              type = if stat.symlink?
                       "symlink"
                     elsif stat.file?
                       "regular"
                     elsif stat.directory?
                       "directory"
                     else
                       "other"
                     end
              {
                "type" => type, "mode" => stat.mode & 0o7777,
                "uid" => stat.uid, "gid" => stat.gid,
                "content" => (File.binread(path) if type == "regular")
              }
            end
    [filename, value]
  end
end

def fingerprint_change_count(before, after)
  FINGERPRINT_FILES.count { |filename| before[filename] != after[filename] }
end

def ansible_json(value)
  case value
  when Hash
    "{" + value.map { |key, item| "#{JSON.generate(key.to_s)}: #{ansible_json(item)}" }.join(", ") + "}"
  when Array
    "[" + value.map { |item| ansible_json(item) }.join(", ") + "]"
  when String
    JSON.generate(value)
  when true then "true"
  when false then "false"
  when nil then "null"
  else value.to_s
  end
end

def desired_fingerprint_values(variables)
  {
    "prowlarr_applications" => variables.fetch("arr_prowlarr_applications"),
    "servarr_sabnzbd" => {
      "instances" => variables.fetch("arr_servarr_instances"),
      "name" => variables.fetch("arr_sabnzbd_client_name"),
      "host" => variables.fetch("arr_sabnzbd_host"),
      "port" => variables.fetch("arr_sabnzbd_port"),
      "api_key" => variables.fetch("vault_downloaders_sabnzbd_api_key"),
      "username" => variables.fetch("vault_downloaders_sabnzbd_admin_username"),
      "password" => variables.fetch("vault_downloaders_sabnzbd_admin_password")
    },
    "prowlarr_indexers" => variables.fetch("media_arr_indexers"),
    "bazarr_providers" => {
      "providers" => variables.fetch("media_bazarr_providers"),
      "languages" => variables.fetch("media_bazarr_languages"),
      "auth" => {
        "type" => "form",
        "username" => variables.fetch("vault_arr_bazarr_admin_username"),
        "password" => variables.fetch("vault_arr_bazarr_admin_password")
      },
      "radarr" => {
        "enabled" => true, "host" => "radarr", "port" => 7878,
        "base_url" => "", "ssl" => false,
        "api_key" => variables.fetch("vault_arr_radarr_api_key")
      },
      "sonarr" => {
        "enabled" => true, "host" => "sonarr", "port" => 8989,
        "base_url" => "", "ssl" => false,
        "api_key" => variables.fetch("vault_arr_sonarr_api_key")
      },
      "path_mappings" => [], "path_mappings_movie" => []
    },
    "configarr" => {
      # Ansible's file lookup strips trailing whitespace by default.
      "config" => File.read(CONFIGARR_SOURCE).rstrip,
      "quality_definitions" => CONFIGARR_QUALITY_DEFINITION_SOURCES.transform_values do |path|
        File.read(path).rstrip
      end,
      "radarr_api_key" => variables.fetch("vault_arr_radarr_api_key"),
      "sonarr_api_key" => variables.fetch("vault_arr_sonarr_api_key"),
      "image" => CONFIGARR_IMAGE
    }
  }.transform_values { |value| Digest::SHA256.hexdigest(ansible_json(value)) }
end

def configarr_state_fingerprint(settings)
  Digest::SHA256.hexdigest(ansible_json(configarr_projection(settings)))
end

def seed_fingerprint_baseline(runtime, variables, kind:, state:)
  directory = File.join(runtime, "services", "arr")
  desired = desired_fingerprint_values(variables)
  FINGERPRINT_FILE_BY_KIND.each do |kind, filename|
    File.write(
      File.join(directory, filename), "#{desired.fetch(FINGERPRINT_INPUT_BY_KIND.fetch(kind))}\n",
      mode: "w", perm: 0o600
    )
  end
  return unless kind == :configarr

  verified_state = state.fetch("configarr_desired", state.fetch("configarr"))
  File.write(
    File.join(directory, CONFIGARR_STATE_FINGERPRINT_FILE),
    "#{configarr_state_fingerprint(verified_state)}\n", mode: "w", perm: 0o600
  )
  File.write(
    File.join(directory, CONFIGARR_OPAQUE_FINGERPRINT_FILE),
    "#{configarr_opaque_fingerprint(verified_state)}\n", mode: "w", perm: 0o600
  )
end

def reconciliation_phase(result)
  events = result.fetch("task_events")
  recorder_task = fingerprint_tasks_available? ? FINGERPRINT_RECORD_TASK_NAME : nil
  recorder_index = recorder_task && events.index { |event| event.fetch("task") == recorder_task }
  phase_events = recorder_index ? events.take(recorder_index) : events
  result.merge(
    "reconciliation_changed" => phase_events.count do |event|
      event.fetch("event") == "ok" && event.fetch("changed")
    end,
    "recorder_started" => !recorder_index.nil?
  )
end

def run_tasks(kind, api, extra_variables = {}, runtime: nil, prepare_fingerprints: true,
              task_mutator: nil)
  Dir.mktmpdir("media-acquisition-reconciliation-") do |directory|
    runtime ||= File.join(directory, "runtime")
    FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
    variables = base_variables(api.port).merge(extra_variables)
    if (fixture_servarr_instance = variables.delete("fixture_servarr_instance"))
      variables["arr_servarr_instance"] = fixture_servarr_instance.merge(
        "api" => "http://127.0.0.1:#{api.port}/api/v3"
      )
    end
    variables["arr_servarr_instances"] = [deep_copy(variables.fetch("arr_servarr_instance"))]
    variables["arr_reconciliation_fingerprint_subset"] =
      if %i[download_client download_client_production].include?(kind)
        ["servarr_sabnzbd"]
      elsif kind == :configarr
        %w[configarr configarr_owned_state configarr_opaque_context
           prowlarr_applications prowlarr_indexers bazarr_providers]
      else
        %w[configarr prowlarr_applications prowlarr_indexers bazarr_providers]
      end
    if kind == :download_client_production
      variables["arr_servarr_instances"] = [SERVARR_INSTANCE, SONARR_INSTANCE].map do |instance|
        deep_copy(instance).merge(
          "api" => "http://127.0.0.1:#{api.port}/#{instance.fetch('name')}/api/v3"
        )
      end
    end
    variables["platform_runtime_dir"] = runtime
    callback_directory = write_event_callback(directory)
    env = {
      "ANSIBLE_NOCOLOR" => "1",
      "ANSIBLE_CALLBACK_PLUGINS" => callback_directory,
      "ANSIBLE_CALLBACKS_ENABLED" => "acquisition_fixture_events",
      "ACQUISITION_FIXTURE_EVENT_LOG" => File.join(directory, "ansible-events.jsonl")
    }
    if kind == :configarr
      collection_root = File.join(directory, "collections")
      write_fake_configarr_module(collection_root)
      env["ANSIBLE_COLLECTIONS_PATH"] = [
        collection_root, File.expand_path("~/.ansible/collections"), "/usr/share/ansible/collections"
      ].join(File::PATH_SEPARATOR)
      env["ACQUISITION_FIXTURE_APPLY_URL"] = "http://127.0.0.1:#{api.port}/_fixture/configarr/apply"
      variables.merge!(
        "platform_current_dir" => ROOT, "platform_runtime_dir" => runtime,
        "platform_service_compose_files" => { "arr" => ["compose.yml"] },
        "arr_compose_project_name" => "fixture-arr",
        "arr_servarr_instances" => [SERVARR_INSTANCE, SONARR_INSTANCE].map do |instance|
          deep_copy(instance).merge(
            "api" => "http://127.0.0.1:#{api.port}/#{instance.fetch('name')}/api/v3"
          )
        end
      )
    end
    if fingerprint_tasks_available? && prepare_fingerprints &&
       FINGERPRINT_BASELINE_CACHE.fetch("enabled")
      seed_fingerprint_baseline(runtime, variables, kind: kind, state: api.state)
    end
    fingerprints_before_play = fingerprint_snapshot(runtime)
    playbook = File.join(directory, "playbook.yml")
    tasks = selected_tasks(kind)
    task_mutator&.call(tasks)
    write_playbook(playbook, variables, tasks)
    result = reconciliation_phase(run_playbook(playbook, env))
    fingerprints_after_play = fingerprint_snapshot(runtime)
    expected_fingerprints = desired_fingerprint_values(variables)
    if kind == :configarr && api.state.key?("configarr")
      expected_state = api.state.fetch("configarr_desired", api.state.fetch("configarr"))
      expected_fingerprints["configarr_owned_state"] =
        configarr_state_fingerprint(expected_state)
      expected_fingerprints["configarr_opaque_context"] =
        configarr_opaque_fingerprint(expected_state)
    end
    result.merge(
      "fingerprints_before" => fingerprints_before_play,
      "fingerprints" => fingerprints_after_play,
      "expected_fingerprints" => expected_fingerprints,
      "fingerprint_changes" => fingerprint_change_count(
        fingerprints_before_play, fingerprints_after_play
      )
    )
  end
end

def with_api(state, fail_configarr: false, partial_configarr: false, fail_client_service: nil,
             corrupt_client_verification: false, mask_bazarr_provider_secrets: false,
             fail_custom_format_service: nil, malformed_custom_format_service: nil)
  api = AcquisitionApi.new(
    state,
    fail_configarr: fail_configarr,
    partial_configarr: partial_configarr,
    fail_client_service: fail_client_service,
    corrupt_client_verification: corrupt_client_verification,
    mask_bazarr_provider_secrets: mask_bazarr_provider_secrets,
    fail_custom_format_service: fail_custom_format_service,
    malformed_custom_format_service: malformed_custom_format_service
  )
  yield api
ensure
  api&.close
end

def redact_secrets(value)
  SECRET_SENTINELS.reduce(value.to_s) do |redacted, secret|
    redacted.gsub(secret, "[REDACTED]")
  end
end

def sanitized_tail(result)
  output = redact_secrets(result.values_at("stdout", "stderr").join("\n"))
  output.lines.last(12).join.strip
end

def harness_problem(result, api)
  return result.fetch("harness_error") if result["harness_error"]
  return "fixture server raised #{api.error.class}" if api.error
  return "Ansible task event callback produced no events" if result.fetch("task_events", []).empty?
  unless api.unexpected_requests.empty?
    method, target = api.unexpected_requests.first
    return "fixture route is missing for #{method} #{redact_secrets(target)}"
  end

  output = result.values_at("stdout", "stderr").join("\n")
  patterns = [
    /couldn't resolve module\/action/i, /Could not find or access/i,
    /conflicting action statements/i, /Syntax Error/i, /the playbook: .* could not be found/i,
    /No such file or directory.*ansible-playbook/i
  ]
  if patterns.any? { |pattern| output.match?(pattern) }
    return "Ansible extraction or interpreter error: #{sanitized_tail(result)}"
  end

  nil
end

def verification_observed?(kind, requests)
  get_targets = requests.select { |request| request["method"] == "GET" }
                        .map { |request| request["target"] }
  case kind
  when :application
    get_targets.count("/api/v1/applications") >= 2 && get_targets.include?("/api/v1/indexer")
  when :indexer
    get_targets.count("/api/v1/indexer") >= 2 && get_targets.include?("/api/v1/applications")
  when :download_client
    get_targets.count("/api/v3/downloadclient") >= 2 &&
      get_targets.any? { |target| target.start_with?("/sabnzbd/api?") }
  when :download_client_production
    %w[radarr sonarr].all? do |service|
      get_targets.count("/#{service}/api/v3/downloadclient") >= 2
    end && get_targets.any? { |target| target.start_with?("/sabnzbd/api?") }
  when :bazarr
    get_targets.count("/api/system/settings") >= 2 &&
      get_targets.count("/api/system/languages") >= 2
  when :configarr
    %w[radarr sonarr].all? do |service|
      %w[config/host rootfolder qualityprofile qualitydefinition customformat config/naming].all? do |resource|
        get_targets.include?("/#{service}/api/v3/#{resource}")
      end
    end
  end
end

def check_sanity(failures, label, result, api, kind: nil)
  output = result.values_at("stdout", "stderr").join("\n")
  if SECRET_SENTINELS.any? { |secret| output.include?(secret) }
    failures << "secret redaction failed during #{label}"
  end
  problem = harness_problem(result, api)
  failures << "HARNESS #{label}: #{problem}" if problem
  if problem.nil? && kind && result.fetch("status").success? &&
     !verification_observed?(kind, api.requests)
    failures << "HARNESS #{label}: production post-read verification did not execute"
    return false
  end
  problem.nil?
end

def mutation_requests(api, matcher)
  api.requests.select do |request|
    %w[POST PUT PATCH DELETE].include?(request.fetch("method")) && matcher.call(request)
  end
end

def exercise_mutations(failures, relationship:, kind:, baseline:, mutations:, variables: {},
                       write_matcher:, projection:, desired:, current:, preserved: nil)
  mutations.each do |field, mutate|
    state = deep_copy(baseline)
    mutate.call(state)
    with_api(state) do |api|
      result = run_tasks(kind, api, variables)
      sane = check_sanity(failures, "#{relationship} #{field}", result, api, kind: kind)
      next unless sane

      unless result.fetch("status").success?
        failures << "#{relationship} failed while reconciling owned field #{field}"
        next
      end
      writes = mutation_requests(api, write_matcher)
      unless writes.length == 1
        failures << "#{relationship} owned field #{field} did not produce exactly one applicable write"
      end
      unless result.fetch("reconciliation_changed") == 1
        failures << "#{relationship} owned field #{field} reported " \
                    "reconciliation changed=#{result['reconciliation_changed'].inspect}, expected 1"
      end
      if fingerprint_tasks_available?
        failures << "#{relationship} owned field #{field} did not reach fingerprint recording" unless
          result.fetch("recorder_started")
        input_filename = FINGERPRINT_FILE_BY_KIND.fetch(kind)
        unless result.fetch("fingerprints_before").fetch(input_filename) ==
               result.fetch("fingerprints").fetch(input_filename)
          failures << "#{relationship} non-secret field #{field} rewrote a desired-input fingerprint"
        end
        if kind == :configarr
          before = result.fetch("fingerprints_before")
          after = result.fetch("fingerprints")
          unless before.fetch(CONFIGARR_OPAQUE_FINGERPRINT_FILE) ==
                 after.fetch(CONFIGARR_OPAQUE_FINGERPRINT_FILE)
            failures << "#{relationship} field #{field} changed opaque context continuity"
          end
          generated_identity = field.match?(
            /(?:quality_profile|custom_format)\.name|missing (?:quality profile|custom format)/
          )
          if generated_identity &&
             before.fetch(CONFIGARR_STATE_FINGERPRINT_FILE) ==
               after.fetch(CONFIGARR_STATE_FINGERPRINT_FILE)
            failures << "#{relationship} field #{field} did not advance verified owned state"
          end
        end
      end
      actual = current.call(api.state)
      expected = if kind == :configarr
                   configarr_expected_with_server_ids(actual, desired)
                 else
                   desired
                 end
      unless projection.call(actual) == projection.call(expected)
        failures << "#{relationship} full owned projection did not converge after #{field} mutant"
      end
      if fingerprint_tasks_available? && kind == :configarr
        state_hash = result.fetch("fingerprints").fetch(CONFIGARR_STATE_FINGERPRINT_FILE)
        unless state_hash&.fetch("content", nil) ==
               "#{configarr_state_fingerprint(actual)}\n"
          failures << "#{relationship} field #{field} recorded a stale owned-state hash"
        end
      end
      if preserved && !preserved.call(api.state, state)
        failures << "#{relationship} modified unmanaged state while repairing #{field}"
      end
    end
  end
end

def exercise_stable(failures, relationship:, kind:, state:, variables: {}, write_matcher:,
                    projection:, desired:, current:, safe_request_body: nil, preserved: nil)
  with_api(deep_copy(state)) do |api|
    result = run_tasks(kind, api, variables)
    sane = check_sanity(
      failures, "#{relationship} stable masked state", result, api, kind: kind
    )
    next unless sane

    unless result.fetch("status").success?
      failures << "#{relationship} rejected complete stable readable state"
      next
    end
    writes = mutation_requests(api, write_matcher)
    unless result.fetch("fingerprint_changes").zero?
      failures << "#{relationship} stable state rewrote a recorded desired-input fingerprint"
    end
    if fingerprint_tasks_available? && !result.fetch("recorder_started")
      failures << "#{relationship} stable state did not reach fingerprint recording"
    end
    unless result.fetch("reconciliation_changed").zero?
      failures << "#{relationship} stable reconciliation reported " \
                  "changed=#{result['reconciliation_changed'].inspect}, expected 0"
    end
    if safe_request_body
      failures << "#{relationship} stable masked state submitted more than one safe write" if writes.length > 1
      unless writes.all? { |request| safe_request_body.call(request) }
        failures << "#{relationship} stable masked state submitted a non-canonical request body"
      end
    elsif !writes.empty?
      failures << "#{relationship} complete stable readable state issued a write"
    end
    actual = current.call(api.state)
    unless projection.call(actual) == projection.call(desired)
      failures << "#{relationship} stable state no longer matches the owned projection"
    end
    if preserved && !preserved.call(api.state, state)
      failures << "#{relationship} stable reconciliation modified unmanaged state"
    end
  end
end

def exercise_secret_change(failures, relationship:, kind:, state:, field:, variables:,
                           old_variables:, write_matcher:, projection:, desired:, current:,
                           fingerprint_transition: true, expected_changed: 1,
                           expected_writes: 1, safe_request_body: nil,
                           write_set_validator: nil, expected_fingerprint_kinds: nil,
                           api_options: {})
  with_api(deep_copy(state), **api_options) do |api|
    transition_kinds = expected_fingerprint_kinds || [kind]
    old_fingerprints = {}
    runtime = nil
    if fingerprint_tasks_available? && fingerprint_transition
      runtime = Dir.mktmpdir("media-acquisition-secret-transition-")
      baseline = run_tasks(
        kind, api, old_variables, runtime: runtime, prepare_fingerprints: false
      )
      baseline_sane = check_sanity(
        failures, "#{relationship} old desired secret #{field}", baseline, api, kind: kind
      )
      unless baseline_sane && baseline.fetch("status").success?
        failures << "#{relationship} could not establish old desired secret #{field}"
        next
      end
      old_recorded = transition_kinds.all? do |fingerprint_kind|
        fingerprint = baseline.fetch("fingerprints").fetch(
          FINGERPRINT_FILE_BY_KIND.fetch(fingerprint_kind)
        )
        old_fingerprints[fingerprint_kind] = fingerprint
        expected = baseline.fetch("expected_fingerprints").fetch(
          FINGERPRINT_INPUT_BY_KIND.fetch(fingerprint_kind)
        )
        fingerprint && fingerprint.fetch("type") == "regular" &&
          fingerprint.fetch("mode") == 0o600 &&
          fingerprint.fetch("content") == "#{expected}\n" &&
          fingerprint.fetch("content").match?(/\A[0-9a-f]{64}\n\z/)
      end
      unless old_recorded
        failures << "#{relationship} did not record the exact old desired digest for #{field}"
        next
      end
      api.requests.clear
    end
    result = run_tasks(
      kind, api, variables, runtime: runtime,
      prepare_fingerprints: !fingerprint_transition
    )
    sane = check_sanity(
      failures, "#{relationship} masked secret #{field}", result, api, kind: kind
    )
    next unless sane

    unless result.fetch("status").success?
      failures << "#{relationship} failed while repairing masked secret #{field}"
      next
    end
    writes = mutation_requests(api, write_matcher)
    unless writes.length == expected_writes
      failures << "#{relationship} masked secret #{field} produced #{writes.length} applicable " \
                  "writes, expected #{expected_writes}"
    end
    if safe_request_body && !writes.all? { |request| safe_request_body.call(request) }
      failures << "#{relationship} masked secret #{field} submitted a non-canonical request body"
    end
    if write_set_validator && !write_set_validator.call(writes)
      failures << "#{relationship} masked secret #{field} did not submit the complete desired write set"
    end
    if fingerprint_tasks_available? && fingerprint_transition
      failures << "#{relationship} masked secret #{field} did not reach fingerprint recording" unless
        result.fetch("recorder_started")
      unless result.fetch("fingerprint_changes") == transition_kinds.length
        failures << "#{relationship} masked secret #{field} recorded an unexpected fingerprint set"
      end
      recorded = transition_kinds.all? do |fingerprint_kind|
        fingerprint = result.fetch("fingerprints").fetch(
          FINGERPRINT_FILE_BY_KIND.fetch(fingerprint_kind)
        )
        expected = result.fetch("expected_fingerprints").fetch(
          FINGERPRINT_INPUT_BY_KIND.fetch(fingerprint_kind)
        )
        fingerprint && fingerprint.fetch("type") == "regular" &&
          fingerprint.fetch("mode") == 0o600 &&
          fingerprint.fetch("uid") == Process.uid && fingerprint.fetch("gid") == Process.gid &&
          fingerprint.fetch("content") == "#{expected}\n" &&
          fingerprint.fetch("content").match?(/\A[0-9a-f]{64}\n\z/) &&
          fingerprint.fetch("content") != old_fingerprints.fetch(fingerprint_kind).fetch("content")
      end
      failures << "#{relationship} masked secret #{field} did not record the expected digest" unless recorded
    elsif fingerprint_tasks_available?
      failures << "#{relationship} masked secret #{field} rewrote an unrelated fingerprint" unless
        result.fetch("fingerprint_changes").zero?
    end
    unless result.fetch("reconciliation_changed") == expected_changed
      failures << "#{relationship} masked secret #{field} reported " \
                  "reconciliation changed=#{result['reconciliation_changed'].inspect}, " \
                  "expected #{expected_changed}"
    end
    actual = current.call(api.state)
    unless projection.call(actual) == projection.call(desired)
      failures << "#{relationship} full owned projection did not converge after masked #{field} drift"
    end
  ensure
    FileUtils.remove_entry(runtime) if runtime && File.directory?(runtime)
  end
end

def exercise_duplicate(failures, relationship:, kind:, state:, variables:, write_matcher:)
  with_api(deep_copy(state)) do |api|
    result = run_tasks(kind, api, variables)
    sane = check_sanity(
      failures, "#{relationship} duplicate identity", result, api, kind: kind
    )
    next unless sane

    failures << "#{relationship} duplicate identity was accepted" if result.fetch("status").success?
    unless mutation_requests(api, write_matcher).empty?
      failures << "#{relationship} duplicate identity reached mutation"
    end
    failures << "#{relationship} duplicate identity reached fingerprint recording" if
      result.fetch("recorder_started")
  end
end

def assert_unsafe_fingerprint_rejected(failures, label, kind, api, variables, runtime, before)
  api.requests.clear
  result = run_tasks(
    kind, api, variables, runtime: runtime, prepare_fingerprints: false
  )
  sane = check_sanity(failures, label, result, api, kind: kind)
  return unless sane

  failures << "#{label} was accepted" if result.fetch("status").success?
  writes = mutation_requests(api, ->(_request) { true })
  failures << "#{label} reached an API mutation" unless writes.empty?
  failures << "#{label} reached fingerprint recording" if result.fetch("recorder_started")
  failures << "#{label} changed fingerprint filesystem state" unless
    result.fetch("fingerprints") == before
end

abort "media acquisition reconciliation fixture requires #{ANSIBLE_PLAYBOOK}" unless File.executable?(ANSIBLE_PLAYBOOK)

# Force every exact production boundary to load before starting the HTTP fixture. A
# missing task name is a harness defect, not an owned-field failure.
%i[application indexer download_client bazarr configarr].each { |kind| selected_tasks(kind) }

failures = []
CONFIGARR_QUALITY_DEFINITION_SOURCES.each do |service, path|
  failures << "Configarr #{service} pinned quality-definition source differs" unless
    Digest::SHA256.file(path).hexdigest == CONFIGARR_QUALITY_DEFINITION_SHA256.fetch(service)
end

Dir.mktmpdir("media-acquisition-ansible-resolution-") do |temporary|
  path_bin = File.join(temporary, "path-bin")
  FileUtils.mkdir_p(path_bin)
  path_ansible = File.join(path_bin, "ansible-playbook")
  File.write(path_ansible, "#!/bin/sh\nexit 0\n", mode: "w", perm: 0o700)
  failures << "PATH-first Ansible resolver ignored an executable ansible-playbook" unless
    resolve_ansible_playbook(path: path_bin) == path_ansible

  normal_root = File.join(temporary, "normal-repository")
  FileUtils.mkdir_p(normal_root)
  _output, git_status = Open3.capture2("git", "init", "-q", normal_root)
  if git_status.success?
    fallback = File.join(normal_root, ".venv", "bin", "ansible-playbook")
    FileUtils.mkdir_p(File.dirname(fallback))
    File.write(fallback, "#!/bin/sh\nexit 0\n", mode: "w", perm: 0o700)
    failures << "normal-layout Ansible fallback did not follow the Git common directory" unless
      resolve_ansible_playbook(root: normal_root, path: "") == fallback
  else
    failures << "HARNESS normal-layout Ansible resolver simulation could not initialize Git"
  end
end
failures << "current-worktree Ansible resolution is not executable" unless
  File.executable?(ANSIBLE_PLAYBOOK)

deadline_probe = capture_process(
  {}, RbConfig.ruby, "-e", "sleep 30", chdir: ROOT, timeout: 0.1
)
unless deadline_probe.fetch("timed_out") && deadline_probe.fetch("reaped") &&
       !deadline_probe.fetch("status").success? && deadline_probe.fetch("elapsed") < 4
  failures << "HARNESS wedged-command deadline did not terminate and reap its process group"
end

partial_api = AcquisitionApi.new({})
partial_client = TCPSocket.new("127.0.0.1", partial_api.port)
partial_client.write("POST /api/system/settings HTTP/1.1\r\nContent-Length: 100\r\n")
accept_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
while partial_api.accepted_client_count.zero? &&
      Process.clock_gettime(Process::CLOCK_MONOTONIC) < accept_deadline
  Thread.pass
end
partial_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
partial_api.close
partial_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - partial_started
failures << "HARNESS partial-client shutdown exceeded its deadline" if
  partial_elapsed >= SOCKET_DEADLINE_SECONDS + 1 || partial_api.error
partial_client.close unless partial_client.closed?

secret_sets = secret_task_sets
missing_secret_output_guards(secret_sets).each do |name|
  failures << "secret-bearing acquisition task can disclose private data: #{name}"
end
secret_sets.each do |path, tasks|
  tasks.each do |task|
    next unless secret_task_protected?(path, task)

    mutant_sets = deep_copy(secret_sets)
    mutant = mutant_sets.fetch(path).find { |candidate| candidate.fetch("name") == task.fetch("name") }
    mutant["no_log"] = false
    guard_name = File.join(File.basename(path), task.fetch("name"))
    failures << "acquisition output-guard mutation survived: #{File.basename(path)}/#{task.fetch('name')}" if
      !missing_secret_output_guards(mutant_sets).include?(guard_name)
  end
end

synthetic_recorder_tasks = [{
  "name" => FINGERPRINT_RECORD_TASK_NAME,
  "ansible.builtin.copy" => {
    "owner" => "{{ nas_uid }}", "group" => "{{ nas_gid }}", "mode" => "0600"
  }
}]
synthetic_loader_tasks = [{
  "name" => "Inspect private Arr desired-input fingerprint files",
  "ansible.builtin.stat" => {
    "get_checksum" => false, "get_mime" => false, "get_attributes" => false
  }
}, {
  "name" => "Validate private Arr desired-input fingerprints",
  "ansible.builtin.assert" => { "that" => FINGERPRINT_FILE_SAFETY_PREDICATES.values },
  "loop" => FINGERPRINT_STAT_RESULTS
}, {
  "name" => FINGERPRINT_READER_TASK_NAME,
  "ansible.builtin.command" => {
    "argv" => ["{{ ansible_facts.python.executable }}", "-c", <<~PYTHON]
      flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
      before = os.fstat(fd)
      raise RuntimeError unless stat.S_ISREG(before.st_mode)
      raise RuntimeError if stat.S_IMODE(before.st_mode) != 0o600
      raise RuntimeError if before.st_uid != expected_uid
      raise RuntimeError if before.st_gid != expected_gid
      raise RuntimeError if before.st_size != 65
      content = os.read(fd, 65)
      raise RuntimeError if os.read(fd, 1)
      raise RuntimeError if content[64:] != b"\\n"
      raise RuntimeError if byte not in b"0123456789abcdef"
      after = os.fstat(fd)
      raise RuntimeError if before_identity != after_identity
      sys.stdout.write(content[:64].decode("ascii"))
    PYTHON
  }
}]
check_fingerprint_record_contract(
  failures, "synthetic mutation sanity", synthetic_recorder_tasks
)
check_fingerprint_loader_contract(
  failures, "synthetic mutation sanity", synthetic_loader_tasks
)

fingerprint_loader = File.join(ARR_TASKS, "reconciliation_fingerprints.yml")
fingerprint_recorder = File.join(ARR_TASKS, "record_reconciliation_fingerprints.yml")
failures << "private desired-input fingerprint loading is unavailable" unless File.file?(fingerprint_loader)
failures << "verified desired-input fingerprint recording is unavailable" unless File.file?(fingerprint_recorder)
if File.file?(fingerprint_loader)
  loader_tasks = YAML.safe_load_file(fingerprint_loader, aliases: true)
  check_fingerprint_loader_contract(
    failures, File.basename(fingerprint_loader),
    loader_tasks
  )
  computed = loader_tasks.first&.fetch("ansible.builtin.set_fact", {}) || {}
  filenames = computed.fetch("arr_reconciliation_fingerprint_filenames", {})
  failures << "Configarr verified owned-state hash path is unavailable" unless
    filenames["configarr_owned_state"] == CONFIGARR_STATE_FINGERPRINT_FILE
  failures << "Configarr opaque-context hash path is unavailable" unless
    filenames["configarr_opaque_context"] == CONFIGARR_OPAQUE_FINGERPRINT_FILE
  desired_inputs = computed.fetch("arr_desired_reconciliation_fingerprints", {})
  failures << "Configarr verified state was mislabeled as a desired-input digest" if
    desired_inputs.key?("configarr_owned_state")
  failures << "Configarr opaque context was mislabeled as a desired-input digest" if
    desired_inputs.key?("configarr_opaque_context")
end
if File.file?(fingerprint_recorder)
  recorder_tasks = YAML.safe_load_file(fingerprint_recorder, aliases: true)
  check_fingerprint_record_contract(
    failures, File.basename(fingerprint_recorder),
    recorder_tasks
  )
  recorder_source = recorder_tasks.to_s
  failures << "Configarr verified state is not recorded from a distinct verified-state fact" unless
    recorder_source.include?("arr_verified_reconciliation_state_fingerprints")
end
check_verification_gate_contract(
  failures,
  YAML.safe_load_file(File.join(ARR_TASKS, "main.yml"), aliases: true),
  YAML.safe_load_file(File.join(ARR_TASKS, "verify.yml"), aliases: true)
)
production_order_contract_failures(
  YAML.safe_load_file(File.join(ROOT, "site.yml"), aliases: true),
  YAML.safe_load_file(File.join(ARR_TASKS, "main.yml"), aliases: true),
  YAML.safe_load_file(File.join(ARR_TASKS, "verify.yml"), aliases: true),
  YAML.safe_load_file(File.join(DOWNLOADER_TASKS, "main.yml"), aliases: true),
  YAML.safe_load_file(File.join(DOWNLOADER_TASKS, "verify.yml"), aliases: true),
  fingerprint_load_tasks,
  fingerprint_record_tasks
).each do |violation|
  failures << "production-order relationship contract violates #{violation}"
end

unless OPAQUE_TARGETED_ONLY
cross_resource_malformed_indexer = deep_copy(INDEXER_DECLARATION).merge(
  "name" => "Malformed Later Indexer"
)
cross_resource_malformed_indexer.fetch("fields").last.delete("value")
cross_resource_preflight_state = {
  "applications" => [
    deep_copy(APPLICATION).merge("enable" => false),
    deep_copy(SONARR_APPLICATION)
  ],
  "indexers" => [deep_copy(INDEXER)]
}
with_api(cross_resource_preflight_state) do |api|
  result = run_tasks(
    :prowlarr_preflight,
    api,
    {
      "media_arr_indexers" => [
        deep_copy(INDEXER_DECLARATION), cross_resource_malformed_indexer
      ]
    },
    prepare_fingerprints: false
  )
  sane = check_sanity(failures, "global Prowlarr preflight", result, api)
  if sane
    failures << "global Prowlarr preflight accepted a malformed later indexer" if
      result.fetch("status").success?
    failures << "global Prowlarr preflight reached a mutation" unless
      mutation_requests(api, ->(_request) { true }).empty?
  end
end

malformed_later_current_application_state = {
  "applications" => [
    deep_copy(APPLICATION).merge("enable" => false),
    deep_copy(SONARR_APPLICATION),
    {
      "id" => 12,
      "name" => "Malformed Later Current Application",
      "fields" => [{ "name" => "baseUrl" }]
    }
  ],
  "indexers" => [deep_copy(INDEXER)]
}
with_api(malformed_later_current_application_state) do |api|
  result = run_tasks(
    :prowlarr_preflight, api, {}, prepare_fingerprints: false
  )
  sane = check_sanity(failures, "malformed later current Prowlarr application", result, api)
  if sane
    failures << "malformed later current Prowlarr application was accepted" if
      result.fetch("status").success?
    failures << "malformed later current Prowlarr application reached a mutation" unless
      mutation_requests(api, ->(_request) { true }).empty?
  end
end

{
  "later application syncCategories" => lambda do
    state = {
      "applications" => [
        deep_copy(APPLICATION).merge("enable" => false), deep_copy(SONARR_APPLICATION)
      ],
      "indexers" => [deep_copy(INDEXER)]
    }
    set_field!(state.fetch("applications").last, "syncCategories", nil)
    state
  end,
  "later indexer minimumSeeders" => lambda do
    state = {
      "applications" => [
        deep_copy(APPLICATION).merge("enable" => false), deep_copy(SONARR_APPLICATION)
      ],
      "indexers" => [deep_copy(INDEXER)]
    }
    set_field!(state.fetch("indexers").first, "minimumSeeders", nil)
    state
  end
}.each do |label, build_state|
  with_api(build_state.call) do |api|
    result = run_tasks(:prowlarr_preflight, api, {}, prepare_fingerprints: false)
    sane = check_sanity(failures, "malformed typed Prowlarr #{label}", result, api)
    if sane
      failures << "malformed typed Prowlarr #{label} was accepted" if
        result.fetch("status").success?
      failures << "malformed typed Prowlarr #{label} reached a mutation" unless
        mutation_requests(api, ->(_request) { true }).empty?
    end
  end
end

application_state = {
  "applications" => [
    deep_copy(APPLICATION), deep_copy(SONARR_APPLICATION),
    {
      "id" => 12, "name" => "Unmanaged", "enable" => true,
      "syncLevel" => "fullSync", "implementation" => "Unmanaged",
      "implementationName" => "Unmanaged", "configContract" => "UnmanagedSettings",
      "fields" => [], "tags" => []
    }
  ]
}
if fingerprint_tasks_available?
  with_api(deep_copy(application_state)) do |api|
    result = run_tasks(:application, api)
    sane = check_sanity(
      failures, "dedicated fingerprint loader and recorder", result, api, kind: :application
    )
    if sane
      failures << "dedicated fingerprint loader and recorder failed: #{sanitized_tail(result)}" unless
        result.fetch("status").success?
      expected = result.fetch("expected_fingerprints")
      valid = FINGERPRINT_FILE_BY_KIND.reject do |kind, _filename|
        %i[download_client download_client_production].include?(kind)
      end.all? do |kind, filename|
        entry = result.fetch("fingerprints").fetch(filename)
        entry && entry.fetch("type") == "regular" && entry.fetch("mode") == 0o600 &&
          entry.fetch("uid") == Process.uid && entry.fetch("gid") == Process.gid &&
          entry.fetch("content") ==
            "#{expected.fetch(FINGERPRINT_INPUT_BY_KIND.fetch(kind))}\n"
      end
      valid &&= result.fetch("fingerprints").fetch(
        FINGERPRINT_FILE_BY_KIND.fetch(:download_client)
      ).nil?
      failures << "dedicated loader/recorder did not create exact private owned fingerprints" unless valid
    end
  end
  # The dedicated production probe above establishes the algorithm. The matrix
  # can seed equivalent private baselines without running another setup playbook
  # before every scenario.
  FINGERPRINT_BASELINE_CACHE["enabled"] = true
end

production_client_write = lambda do |request|
  request["target"].match?(%r{\A/(radarr|sonarr)/api/v3/downloadclient(?:/\d+)?\z})
end
clean_production_client_state = {
  "radarr_download_clients" => [], "sonarr_download_clients" => []
}
with_api(deep_copy(clean_production_client_state)) do |api|
  result = run_tasks(
    :download_client_production, api, {}, prepare_fingerprints: false
  )
  sane = check_sanity(
    failures, "clean production-order Servarr clients", result, api,
    kind: :download_client_production
  )
  if sane
    failures << "clean production-order Servarr clients failed" unless
      result.fetch("status").success?
    writes = mutation_requests(api, production_client_write)
    failures << "clean production-order Servarr clients did not create both clients" unless
      writes.length == 2 && writes.all? { |request| request["method"] == "POST" } &&
      canonical_production_client_writes?(writes)
    failures << "clean production-order Servarr clients reported an unexpected change count" unless
      result.fetch("reconciliation_changed") == 2
    failures << "clean production-order Servarr clients did not converge Radarr" unless
      download_client_projection(api.state.fetch("radarr_download_clients").first) ==
      download_client_projection(DOWNLOAD_CLIENT)
    failures << "clean production-order Servarr clients did not converge Sonarr" unless
      download_client_projection(api.state.fetch("sonarr_download_clients").first) ==
      download_client_projection(SONARR_DOWNLOAD_CLIENT)
    servarr_file = FINGERPRINT_FILE_BY_KIND.fetch(:download_client)
    entry = result.fetch("fingerprints").fetch(servarr_file)
    expected = result.fetch("expected_fingerprints").fetch("servarr_sabnzbd")
    failures << "clean production-order Servarr clients did not record only the Servarr digest" unless
      entry && entry.fetch("content") == "#{expected}\n" &&
      (FINGERPRINT_FILES - [servarr_file]).all? do |filename|
        result.fetch("fingerprints").fetch(filename).nil?
      end
    success_index = result.fetch("task_events").index do |event|
      event.fetch("task") == DOWNLOADER_GATE_SUCCESS_TASK_NAME
    end
    record_index = result.fetch("task_events").index do |event|
      event.fetch("task") == FINGERPRINT_RECORD_TASK_NAME
    end
    failures << "clean production-order Servarr digest was recorded before downloader verification" unless
      success_index && record_index && success_index < record_index
  end
end

malformed_later_production_client_state = {
  "radarr_download_clients" => [deep_copy(DOWNLOAD_CLIENT).merge("enable" => false)],
  "sonarr_download_clients" => [deep_copy(SONARR_DOWNLOAD_CLIENT).merge("priority" => nil)]
}
with_api(malformed_later_production_client_state) do |api|
  result = run_tasks(
    :download_client_production, api, {}, prepare_fingerprints: false
  )
  sane = check_sanity(
    failures, "malformed later production-order Servarr client", result, api,
    kind: :download_client_production
  )
  if sane
    failures << "malformed later production-order Servarr client was accepted" if
      result.fetch("status").success?
    failures << "malformed later production-order Servarr client reached mutation" unless
      mutation_requests(api, production_client_write).empty?
  end
end

servarr_global_ownership_cases = {}
servarr_url_duplicate_state = {
  "radarr_download_clients" => [deep_copy(DOWNLOAD_CLIENT).merge("enable" => false)],
  "sonarr_download_clients" => [
    deep_copy(SONARR_DOWNLOAD_CLIENT),
    deep_copy(SONARR_DOWNLOAD_CLIENT).merge("id" => 91, "name" => "URL Duplicate")
  ]
}
servarr_global_ownership_cases["later Sonarr URL duplicate"] = servarr_url_duplicate_state
servarr_conflicting_identity_state = {
  "radarr_download_clients" => [deep_copy(DOWNLOAD_CLIENT).merge("enable" => false)],
  "sonarr_download_clients" => [
    deep_copy(SONARR_DOWNLOAD_CLIENT).tap do |client|
      set_field!(client, "host", "legacy-sab")
    end,
    deep_copy(SONARR_DOWNLOAD_CLIENT).merge("id" => 92, "name" => "URL Owner")
  ]
}
servarr_global_ownership_cases["later Sonarr conflicting name and URL"] =
  servarr_conflicting_identity_state
servarr_incomplete_adoption = deep_copy(SONARR_DOWNLOAD_CLIENT).merge(
  "id" => 93, "name" => "URL Adoption"
)
remove_field!(servarr_incomplete_adoption, "useSsl")
servarr_global_ownership_cases["later Sonarr incomplete URL adoption"] = {
  "radarr_download_clients" => [deep_copy(DOWNLOAD_CLIENT).merge("enable" => false)],
  "sonarr_download_clients" => [servarr_incomplete_adoption]
}
servarr_global_ownership_cases.each do |label, state|
  with_api(state) do |api|
    result = run_tasks(
      :download_client_production, api, {}, prepare_fingerprints: false
    )
    sane = check_sanity(failures, label, result, api, kind: :download_client_production)
    if sane
      failures << "#{label} was accepted" if result.fetch("status").success?
      failures << "#{label} reached mutation" unless
        mutation_requests(api, production_client_write).empty?
    end
  end
end


with_api(
  deep_copy(clean_production_client_state), fail_client_service: "sonarr"
) do |api|
  result = run_tasks(
    :download_client_production, api, {}, prepare_fingerprints: false
  )
  sane = check_sanity(
    failures, "failed production-order Servarr client write", result, api,
    kind: :download_client_production
  )
  if sane
    failures << "failed production-order Servarr client write was accepted" if
      result.fetch("status").success?
    failures << "failed production-order Servarr client write reached downloader success" if
      result.fetch("task_events").any? do |event|
        event.fetch("task") == DOWNLOADER_GATE_SUCCESS_TASK_NAME
      end
    failures << "failed production-order Servarr client write reached fingerprint recording" if
      result.fetch("task_events").any? do |event|
        event.fetch("task") == FINGERPRINT_RECORD_TASK_NAME
      end
    failures << "failed production-order Servarr client write advanced a fingerprint" unless
      result.fetch("fingerprints").values.compact.empty?
  end
end

stable_production_client_state = {
  "radarr_download_clients" => [deep_copy(DOWNLOAD_CLIENT)],
  "sonarr_download_clients" => [deep_copy(SONARR_DOWNLOAD_CLIENT)]
}
with_api(
  deep_copy(stable_production_client_state), corrupt_client_verification: true
) do |api|
  result = run_tasks(
    :download_client_production, api, {}, prepare_fingerprints: false
  )
  sane = check_sanity(
    failures, "failed production-order downloader verification", result, api,
    kind: :download_client_production
  )
  if sane
    failures << "failed production-order downloader verification was accepted" if
      result.fetch("status").success?
    failures << "failed production-order downloader verification reached success" if
      result.fetch("task_events").any? do |event|
        event.fetch("task") == DOWNLOADER_GATE_SUCCESS_TASK_NAME
      end
    failures << "failed production-order downloader verification reached fingerprint recording" if
      result.fetch("task_events").any? do |event|
        event.fetch("task") == FINGERPRINT_RECORD_TASK_NAME
      end
    failures << "failed production-order downloader verification advanced a fingerprint" unless
      result.fetch("fingerprints").values.compact.empty?
  end
end

production_secret_state = deep_copy(stable_production_client_state)
%w[radarr_download_clients sonarr_download_clients].each do |collection|
  set_field!(
    production_secret_state.fetch(collection).first,
    "apiKey",
    "private-stale-apiKey"
  )
end
Dir.mktmpdir("media-acquisition-production-client-secret-") do |runtime|
  with_api(production_secret_state) do |api|
    baseline = run_tasks(
      :download_client_production,
      api,
      { "vault_downloaders_sabnzbd_api_key" => "private-stale-apiKey" },
      runtime: runtime,
      prepare_fingerprints: false
    )
    sane = check_sanity(
      failures, "old production-order Servarr secret", baseline, api,
      kind: :download_client_production
    )
    if sane && baseline.fetch("status").success?
      api.requests.clear
      result = run_tasks(
        :download_client_production, api, {}, runtime: runtime,
        prepare_fingerprints: false
      )
      sane = check_sanity(
        failures, "shared production-order Servarr secret transition", result, api,
        kind: :download_client_production
      )
      if sane
        writes = mutation_requests(api, production_client_write)
        failures << "shared production-order Servarr secret did not update both exact clients" unless
          result.fetch("status").success? && writes.length == 2 &&
          writes.all? { |request| request["method"] == "PUT" } &&
          canonical_production_client_writes?(writes)
        failures << "shared production-order Servarr secret reported an unexpected change count" unless
          result.fetch("reconciliation_changed") == 2
        failures << "shared production-order Servarr secret did not record one digest transition" unless
          result.fetch("fingerprint_changes") == 1
        success_index = result.fetch("task_events").index do |event|
          event.fetch("task") == DOWNLOADER_GATE_SUCCESS_TASK_NAME
        end
        record_index = result.fetch("task_events").index do |event|
          event.fetch("task") == FINGERPRINT_RECORD_TASK_NAME
        end
        failures << "shared production-order Servarr secret recorded before both clients verified" unless
          success_index && record_index && success_index < record_index
      end
    else
      failures << "could not establish old production-order Servarr secret fingerprint"
    end
  end
end

Dir.mktmpdir("media-acquisition-fingerprint-tags-") do |directory|
  runtime = File.join(directory, "runtime")
  FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
  File.write(
    File.join(runtime, "services", "arr", FINGERPRINT_FILE_BY_KIND.fetch(:configarr)),
    "#{'0' * 64}\n", mode: "w", perm: 0o600
  )
  fingerprints_before = fingerprint_snapshot(runtime)
  variables = base_variables(1).merge(
    "media_usenet_enabled" => true,
    "platform_runtime_dir" => runtime
  )
  callback_directory = write_event_callback(directory)
  env = {
    "ANSIBLE_NOCOLOR" => "1",
    "ANSIBLE_CALLBACK_PLUGINS" => callback_directory,
    "ANSIBLE_CALLBACKS_ENABLED" => "acquisition_fixture_events",
    "ACQUISITION_FIXTURE_EVENT_LOG" => File.join(directory, "ansible-events.jsonl")
  }
  playbook = File.join(directory, "playbook.yml")
  write_playbook(playbook, variables, tag_filtered_fingerprint_tasks)
  result = run_playbook(
    playbook, env, "--tags", "arr", "--skip-tags", "platform_verify_arr"
  )
  failures << "HARNESS tag-filtered fingerprint gate produced no task events" if
    result.fetch("task_events").empty?
  failures << "tag-filtered verification skip failed: #{sanitized_tail(result)}" unless
    result.fetch("status")&.success?
  recorder_started = result.fetch("task_events").any? do |event|
    event.fetch("task") == FINGERPRINT_RECORD_TASK_NAME
  end
  failures << "tag-filtered verification skip reached fingerprint recording" if recorder_started
  failures << "tag-filtered verification skip changed fingerprint files" unless
    fingerprint_snapshot(runtime) == fingerprints_before
end


Dir.mktmpdir("media-acquisition-downloader-tags-") do |directory|
  runtime = File.join(directory, "runtime")
  FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
  with_api(deep_copy(clean_production_client_state)) do |api|
    variables = base_variables(api.port).merge(
      "media_usenet_enabled" => true,
      "platform_runtime_dir" => runtime,
      "arr_servarr_instances" => [SERVARR_INSTANCE, SONARR_INSTANCE].map do |instance|
        deep_copy(instance).merge(
          "api" => "http://127.0.0.1:#{api.port}/#{instance.fetch('name')}/api/v3"
        )
      end
    )
    callback_directory = write_event_callback(directory)
    env = {
      "ANSIBLE_NOCOLOR" => "1",
      "ANSIBLE_CALLBACK_PLUGINS" => callback_directory,
      "ANSIBLE_CALLBACKS_ENABLED" => "acquisition_fixture_events",
      "ACQUISITION_FIXTURE_EVENT_LOG" => File.join(directory, "ansible-events.jsonl")
    }
    playbook = File.join(directory, "playbook.yml")
    write_playbook(playbook, variables, tag_filtered_downloader_relationship_tasks)
    result = run_playbook(
      playbook, env, "--tags", "downloaders", "--skip-tags", "platform_verify_downloaders"
    )
    failures << "HARNESS downloader tag-filtered gate produced no task events" if
      result.fetch("task_events").empty?
    failures << "downloader tag-filtered verification skip failed: #{sanitized_tail(result)}" unless
      result.fetch("status")&.success?
    failures << "downloader tag-filtered verification skip did not reconcile both clients" unless
      mutation_requests(api, production_client_write).length == 2
    failures << "downloader tag-filtered verification skip reached its success marker" if
      result.fetch("task_events").any? do |event|
        event.fetch("task") == DOWNLOADER_GATE_SUCCESS_TASK_NAME && event.fetch("event") == "ok"
      end
    failures << "downloader tag-filtered verification skip reached fingerprint recording" if
      result.fetch("task_events").any? do |event|
        event.fetch("task") == FINGERPRINT_RECORD_TASK_NAME
      end
    failures << "downloader tag-filtered verification skip changed fingerprint files" unless
      fingerprint_snapshot(runtime).values.compact.empty?
  end
end


[true, false].each do |stale|
  Dir.mktmpdir("media-acquisition-arr-verify-only-") do |directory|
    runtime = File.join(directory, "runtime")
    FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
    state = { "applications" => [deep_copy(APPLICATION), deep_copy(SONARR_APPLICATION)],
              "indexers" => [deep_copy(INDEXER)] }
    with_api(state) do |api|
      variables = base_variables(api.port).merge("platform_runtime_dir" => runtime)
      fingerprint_variables = deep_copy(variables)
      if stale
        set_field!(
          fingerprint_variables.fetch("media_arr_indexers").first,
          "apiKey", "private-stale-indexer-secret"
        )
      end
      seed_fingerprint_baseline(
        runtime, fingerprint_variables, kind: :indexer, state: state
      )
      before = fingerprint_snapshot(runtime)
      callback_directory = write_event_callback(directory)
      env = {
        "ANSIBLE_NOCOLOR" => "1", "ANSIBLE_CALLBACK_PLUGINS" => callback_directory,
        "ANSIBLE_CALLBACKS_ENABLED" => "acquisition_fixture_events",
        "ACQUISITION_FIXTURE_EVENT_LOG" => File.join(directory, "ansible-events.jsonl")
      }
      playbook = File.join(directory, "playbook.yml")
      write_playbook(playbook, variables, arr_verify_only_tasks)
      result = run_playbook(playbook, env, "--tags", "platform_verify_arr")
      failures << "Arr verify-only stale digest was accepted" if stale && result.fetch("status").success?
      failures << "Arr verify-only matching digest failed: #{sanitized_tail(result)}" if
        !stale && !result.fetch("status").success?
      failures << "Arr verify-only execution reached an API mutation" unless
        mutation_requests(api, ->(_request) { true }).empty?
      failures << "Arr verify-only execution changed fingerprint state" unless
        fingerprint_snapshot(runtime) == before
    end
  end
end

[true, false].each do |stale|
  Dir.mktmpdir("media-acquisition-downloader-verify-only-") do |directory|
    runtime = File.join(directory, "runtime")
    FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
    with_api(deep_copy(stable_production_client_state)) do |api|
      variables = base_variables(api.port).merge(
        "platform_runtime_dir" => runtime,
        "arr_servarr_instances" => [SERVARR_INSTANCE, SONARR_INSTANCE].map do |instance|
          deep_copy(instance).merge(
            "api" => "http://127.0.0.1:#{api.port}/#{instance.fetch('name')}/api/v3"
          )
        end
      )
      fingerprint_variables = deep_copy(variables)
      if stale
        fingerprint_variables["vault_downloaders_sabnzbd_admin_username"] =
          "private-stale-username"
        fingerprint_variables["vault_downloaders_sabnzbd_admin_password"] =
          "private-stale-password"
      end
      seed_fingerprint_baseline(
        runtime, fingerprint_variables, kind: :download_client_production,
        state: api.state
      )
      before = fingerprint_snapshot(runtime)
      callback_directory = write_event_callback(directory)
      env = {
        "ANSIBLE_NOCOLOR" => "1", "ANSIBLE_CALLBACK_PLUGINS" => callback_directory,
        "ANSIBLE_CALLBACKS_ENABLED" => "acquisition_fixture_events",
        "ACQUISITION_FIXTURE_EVENT_LOG" => File.join(directory, "ansible-events.jsonl")
      }
      playbook = File.join(directory, "playbook.yml")
      write_playbook(playbook, variables, downloader_verify_only_tasks)
      result = run_playbook(playbook, env, "--tags", "platform_verify_downloaders")
      failures << "downloader verify-only stale digest was accepted" if
        stale && result.fetch("status").success?
      failures << "downloader verify-only matching digest failed: #{sanitized_tail(result)}" if
        !stale && !result.fetch("status").success?
      failures << "downloader verify-only execution reached an API mutation" unless
        mutation_requests(api, ->(_request) { true }).empty?
      failures << "downloader verify-only execution changed fingerprint state" unless
        fingerprint_snapshot(runtime) == before
    end
  end
end

Dir.mktmpdir("media-acquisition-fingerprint-oversized-") do |runtime|
  FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
  with_api(deep_copy(application_state)) do |api|
    variables = base_variables(api.port)
    seed_fingerprint_baseline(
      runtime, variables, kind: :application, state: api.state
    )
    path = File.join(
      runtime, "services", "arr", FINGERPRINT_FILE_BY_KIND.fetch(:application)
    )
    File.write(path, "a" * (1024 * 1024), mode: "w", perm: 0o600)
    before = fingerprint_snapshot(runtime)
    result = run_tasks(
      :application, api, {}, runtime: runtime, prepare_fingerprints: false
    )
    failures << "oversized fingerprint was accepted" if result.fetch("status").success?
    failures << "oversized fingerprint reached an API request" unless api.requests.empty?
    failures << "oversized fingerprint reached fingerprint recording" if
      result.fetch("recorder_started")
    failures << "oversized fingerprint changed filesystem state" unless
      result.fetch("fingerprints") == before

    File.write(path, "#{'A' * 64}\n", mode: "w", perm: 0o600)
    before = fingerprint_snapshot(runtime)
    api.requests.clear
    result = run_tasks(
      :application, api, {}, runtime: runtime, prepare_fingerprints: false
    )
    failures << "uppercase fingerprint was accepted" if result.fetch("status").success?
    failures << "uppercase fingerprint reached an API request" unless api.requests.empty?
    failures << "uppercase fingerprint reached fingerprint recording" if
      result.fetch("recorder_started")
    failures << "uppercase fingerprint changed filesystem state" unless
      result.fetch("fingerprints") == before
  end
end

Dir.mktmpdir("media-acquisition-fingerprint-race-") do |runtime|
  fingerprint_directory = File.join(runtime, "services", "arr")
  FileUtils.mkdir_p(fingerprint_directory)
  with_api(deep_copy(application_state)) do |api|
    variables = base_variables(api.port)
    seed_fingerprint_baseline(
      runtime, variables, kind: :application, state: api.state
    )
    path = File.join(fingerprint_directory, FINGERPRINT_FILE_BY_KIND.fetch(:application))
    target = File.join(runtime, "replacement-target")
    File.write(target, "#{'f' * 64}\n", mode: "w", perm: 0o600)
    target_before = File.binread(target)
    inject_replacement = lambda do |tasks|
      assertion_index = tasks.index do |task|
        task["name"] == "Validate private Arr desired-input fingerprints"
      end
      raise "fingerprint race injection boundary is unavailable" unless assertion_index

      tasks.insert(
        assertion_index + 1,
        {
          "name" => "Remove the inspected fingerprint for race injection",
          "ansible.builtin.file" => { "path" => path, "state" => "absent" },
          "no_log" => true
        },
        {
          "name" => "Replace the inspected fingerprint with a symlink",
          "ansible.builtin.file" => {
            "src" => target, "dest" => path, "state" => "link"
          },
          "no_log" => true
        }
      )
    end
    result = run_tasks(
      :application, api, {}, runtime: runtime, prepare_fingerprints: false,
      task_mutator: inject_replacement
    )
    failures << "replacement-symlink fingerprint race was accepted" if
      result.fetch("status").success?
    failures << "replacement-symlink fingerprint race reached an API request" unless
      api.requests.empty?
    failures << "replacement-symlink fingerprint race reached fingerprint recording" if
      result.fetch("recorder_started")
    failures << "replacement-symlink fingerprint race did not execute" unless
      result.dig("fingerprints", FINGERPRINT_FILE_BY_KIND.fetch(:application), "type") == "symlink"
    failures << "replacement-symlink fingerprint race changed its target" unless
      File.binread(target) == target_before
  end
end

Dir.mktmpdir("media-acquisition-fingerprint-fifo-race-") do |runtime|
  fingerprint_directory = File.join(runtime, "services", "arr")
  FileUtils.mkdir_p(fingerprint_directory)
  with_api(deep_copy(application_state)) do |api|
    variables = base_variables(api.port)
    seed_fingerprint_baseline(
      runtime, variables, kind: :application, state: api.state
    )
    path = File.join(fingerprint_directory, FINGERPRINT_FILE_BY_KIND.fetch(:application))
    inject_fifo = lambda do |tasks|
      assertion_index = tasks.index do |task|
        task["name"] == "Validate private Arr desired-input fingerprints"
      end
      raise "fingerprint FIFO race injection boundary is unavailable" unless assertion_index

      tasks.insert(
        assertion_index + 1,
        {
          "name" => "Remove the inspected fingerprint for FIFO race injection",
          "ansible.builtin.file" => { "path" => path, "state" => "absent" },
          "no_log" => true
        },
        {
          "name" => "Replace the inspected fingerprint with a FIFO",
          "ansible.builtin.command" => { "argv" => ["/usr/bin/mkfifo", path] },
          "changed_when" => false,
          "no_log" => true
        }
      )
    end
    result = run_tasks(
      :application, api, {}, runtime: runtime, prepare_fingerprints: false,
      task_mutator: inject_fifo
    )
    failures << "replacement-FIFO fingerprint race was accepted" if
      result.fetch("status").success?
    failures << "replacement-FIFO fingerprint race reached an API request" unless
      api.requests.empty?
    failures << "replacement-FIFO fingerprint race reached fingerprint recording" if
      result.fetch("recorder_started")
    failures << "replacement-FIFO fingerprint race did not execute" unless
      result.dig("fingerprints", FINGERPRINT_FILE_BY_KIND.fetch(:application), "type") == "other"
  end
end

if ENV["ACQUISITION_FINGERPRINT_TARGETED_ONLY"] == "1"
  abort failures.join("\n") unless failures.empty?
  puts "media acquisition fingerprint safety behavior holds"
  exit
end

if ENV["ACQUISITION_PRODUCTION_ORDER_TARGETED_ONLY"] == "1"
  abort failures.join("\n") unless failures.empty?
  puts "media acquisition production-order relationship behavior holds"
  exit
end

application_mutations = {
  "name" => ->(state) { state.fetch("applications").first["name"] = "Legacy Radarr" },
  "enable" => ->(state) { state.fetch("applications").first["enable"] = false },
  "syncLevel" => ->(state) { state.fetch("applications").first["syncLevel"] = "addOnly" },
  "implementation" => ->(state) { state.fetch("applications").first["implementation"] = "Legacy" },
  "implementationName" => ->(state) { state.fetch("applications").first["implementationName"] = "Legacy" },
  "configContract" => ->(state) { state.fetch("applications").first["configContract"] = "LegacySettings" },
  "sorted tags" => ->(state) { state.fetch("applications").first["tags"] = [44] },
  "fields.prowlarrUrl" => lambda do |state|
    set_field!(state.fetch("applications").first, "prowlarrUrl", "http://legacy:9696")
  end,
  "fields.baseUrl" => ->(state) { set_field!(state.fetch("applications").first, "baseUrl", "http://legacy:7878") },
  "fields.username" => ->(state) { set_field!(state.fetch("applications").first, "username", "legacy-user") },
  "fields.password" => ->(state) { set_field!(state.fetch("applications").first, "password", "legacy-readable-value") },
  "fields.syncCategories" => ->(state) { set_field!(state.fetch("applications").first, "syncCategories", [9999]) },
  "fields.apiKey missing readable value" => lambda do |state|
    remove_field!(state.fetch("applications").first, "apiKey")
  end
}
application_write = ->(request) { request["target"].match?(%r{\A/api/v1/applications(?:/\d+)?\z}) }
application_current = lambda do |state|
  state.fetch("applications").find { |item| item["name"] == APPLICATION.fetch("name") }
end
exercise_mutations(
  failures, relationship: "Prowlarr application", kind: :application,
  baseline: application_state, mutations: application_mutations,
  write_matcher: application_write, projection: method(:application_projection),
  desired: APPLICATION, current: application_current
)
exercise_stable(
  failures, relationship: "Prowlarr application", kind: :application,
  state: application_state, write_matcher: application_write,
  projection: method(:application_projection), desired: APPLICATION,
  current: application_current
)
application_secret_state = deep_copy(application_state)
set_field!(application_secret_state.fetch("applications").first, "apiKey", "private-stale-application-secret")
old_application_declaration = deep_copy(APPLICATION_DECLARATION)
old_application_declaration["api_key"] = "private-stale-application-secret"
exercise_secret_change(
  failures, relationship: "Prowlarr application", kind: :application,
  state: application_secret_state, field: "fields.apiKey",
  variables: {},
  old_variables: {
    "arr_prowlarr_applications" => [old_application_declaration, SONARR_APPLICATION_DECLARATION]
  }, write_matcher: application_write, projection: method(:application_projection),
  desired: APPLICATION, current: application_current,
  expected_writes: 2, expected_changed: 2,
  write_set_validator: method(:canonical_application_secret_writes?)
)
duplicate_applications = deep_copy(application_state)
duplicate_applications.fetch("applications") << deep_copy(APPLICATION).merge("id" => 14)
exercise_duplicate(
  failures, relationship: "Prowlarr application", kind: :application,
  state: duplicate_applications, variables: {}, write_matcher: application_write
)
duplicate_application_declarations = [
  deep_copy(APPLICATION_DECLARATION), deep_copy(APPLICATION_DECLARATION)
]
application_declaration_preflight_state = deep_copy(application_state)
application_declaration_preflight_state.fetch("applications").first["enable"] = false
exercise_duplicate(
  failures, relationship: "Prowlarr application declaration", kind: :application,
  state: application_declaration_preflight_state,
  variables: { "arr_prowlarr_applications" => duplicate_application_declarations },
  write_matcher: application_write
)
malformed_application_declaration = deep_copy(SONARR_APPLICATION_DECLARATION)
malformed_application_declaration.delete("base_url")
exercise_duplicate(
  failures, relationship: "Prowlarr malformed later application declaration",
  kind: :application, state: application_declaration_preflight_state,
  variables: {
    "arr_prowlarr_applications" => [
      deep_copy(APPLICATION_DECLARATION), malformed_application_declaration
    ]
  },
  write_matcher: application_write
)

client_state = { "download_clients" => [deep_copy(DOWNLOAD_CLIENT)] }
client_mutations = {
  "name" => ->(state) { state.fetch("download_clients").first["name"] = "Legacy SAB" },
  "enable" => ->(state) { state.fetch("download_clients").first["enable"] = false },
  "protocol" => ->(state) { state.fetch("download_clients").first["protocol"] = "torrent" },
  "priority" => ->(state) { state.fetch("download_clients").first["priority"] = 50 },
  "removeCompletedDownloads" => ->(state) { state.fetch("download_clients").first["removeCompletedDownloads"] = false },
  "removeFailedDownloads" => ->(state) { state.fetch("download_clients").first["removeFailedDownloads"] = false },
  "implementation" => ->(state) { state.fetch("download_clients").first["implementation"] = "Legacy" },
  "implementationName" => ->(state) { state.fetch("download_clients").first["implementationName"] = "Legacy" },
  "configContract" => ->(state) { state.fetch("download_clients").first["configContract"] = "LegacySettings" },
  "sorted tags" => ->(state) { state.fetch("download_clients").first["tags"] = [44] },
  "fields.host" => ->(state) { set_field!(state.fetch("download_clients").first, "host", "legacy-sab") },
  "fields.port" => ->(state) { set_field!(state.fetch("download_clients").first, "port", "9999") },
  "fields.useSsl" => ->(state) { set_field!(state.fetch("download_clients").first, "useSsl", true) },
  "fields.urlBase" => ->(state) { set_field!(state.fetch("download_clients").first, "urlBase", "/legacy") },
  "fields.apiKey missing readable value" => lambda do |state|
    remove_field!(state.fetch("download_clients").first, "apiKey")
  end,
  "fields.username missing readable value" => lambda do |state|
    remove_field!(state.fetch("download_clients").first, "username")
  end,
  "fields.password missing readable value" => lambda do |state|
    remove_field!(state.fetch("download_clients").first, "password")
  end,
  "fields.movieCategory" => ->(state) { set_field!(state.fetch("download_clients").first, "movieCategory", "legacy") },
  "fields.movieCategory wrong key" => lambda do |state|
    client = state.fetch("download_clients").first
    remove_field!(client, "movieCategory")
    client.fetch("fields") << { "name" => "tvCategory", "value" => "movies" }
  end,
  "fields.movieCategory missing key" => lambda do |state|
    remove_field!(state.fetch("download_clients").first, "movieCategory")
  end
}
client_write = ->(request) { request["target"].match?(%r{\A/api/v3/downloadclient(?:/\d+)?\z}) }
client_current = lambda do |state|
  state.fetch("download_clients").find { |item| item["name"] == DOWNLOAD_CLIENT.fetch("name") }
end
exercise_mutations(
  failures, relationship: "Servarr SABnzbd client", kind: :download_client,
  baseline: client_state, mutations: client_mutations,
  write_matcher: client_write, projection: method(:download_client_projection),
  desired: DOWNLOAD_CLIENT, current: client_current
)
exercise_stable(
  failures, relationship: "Servarr SABnzbd client", kind: :download_client,
  state: client_state, write_matcher: client_write,
  projection: method(:download_client_projection), desired: DOWNLOAD_CLIENT,
  current: client_current
)
radarr_blank_category_state = deep_copy(client_state)
radarr_blank_category_state.fetch("download_clients").first.fetch("fields") <<
  { "name" => "tvCategory", "value" => "" }
exercise_stable(
  failures, relationship: "Radarr SABnzbd client blank non-applicable category",
  kind: :download_client, state: radarr_blank_category_state,
  write_matcher: client_write, projection: method(:download_client_projection),
  desired: DOWNLOAD_CLIENT, current: client_current
)
%w[apiKey username password].each do |secret_field|
  secret_state = deep_copy(client_state)
  old_secret = "private-stale-#{secret_field}"
  set_field!(secret_state.fetch("download_clients").first, secret_field, old_secret)
  variable = {
    "apiKey" => "vault_downloaders_sabnzbd_api_key",
    "username" => "vault_downloaders_sabnzbd_admin_username",
    "password" => "vault_downloaders_sabnzbd_admin_password"
  }.fetch(secret_field)
  exercise_secret_change(
    failures, relationship: "Servarr SABnzbd client", kind: :download_client,
    state: secret_state, field: "fields.#{secret_field}",
    variables: {}, old_variables: { variable => old_secret },
    write_matcher: client_write, projection: method(:download_client_projection),
    desired: DOWNLOAD_CLIENT, current: client_current
  )
end
duplicate_clients = deep_copy(client_state)
duplicate_clients.fetch("download_clients") << deep_copy(DOWNLOAD_CLIENT).merge("id" => 23)
exercise_duplicate(
  failures, relationship: "Servarr SABnzbd client", kind: :download_client,
  state: duplicate_clients, variables: {}, write_matcher: client_write
)
{
  "missing port" => ->(client) { remove_field!(client, "port") },
  "null port" => ->(client) { set_field!(client, "port", nil) },
  "invalid useSsl" => ->(client) { set_field!(client, "useSsl", "sometimes") },
  "null priority" => ->(client) { client["priority"] = nil }
}.each do |label, mutate|
  malformed = deep_copy(client_state)
  mutate.call(malformed.fetch("download_clients").first)
  exercise_duplicate(
    failures, relationship: "Servarr SABnzbd client #{label}", kind: :download_client,
    state: malformed, variables: {}, write_matcher: client_write
  )
end

sonarr_client_state = { "download_clients" => [deep_copy(SONARR_DOWNLOAD_CLIENT)] }
sonarr_client_mutations = client_mutations.reject do |field, _mutate|
  field.start_with?("fields.movieCategory")
end
sonarr_client_mutations["fields.tvCategory"] = lambda do |state|
  set_field!(state.fetch("download_clients").first, "tvCategory", "legacy")
end
sonarr_client_mutations["fields.tvCategory wrong key"] = lambda do |state|
  client = state.fetch("download_clients").first
  remove_field!(client, "tvCategory")
  client.fetch("fields") << { "name" => "movieCategory", "value" => "series" }
end
sonarr_client_mutations["fields.tvCategory missing key"] = lambda do |state|
  remove_field!(state.fetch("download_clients").first, "tvCategory")
end
sonarr_variables = { "fixture_servarr_instance" => deep_copy(SONARR_INSTANCE) }
sonarr_client_current = lambda do |state|
  state.fetch("download_clients").find do |item|
    item["name"] == SONARR_DOWNLOAD_CLIENT.fetch("name")
  end
end
exercise_mutations(
  failures, relationship: "Sonarr SABnzbd client", kind: :download_client,
  baseline: sonarr_client_state, mutations: sonarr_client_mutations,
  variables: sonarr_variables, write_matcher: client_write,
  projection: method(:download_client_projection), desired: SONARR_DOWNLOAD_CLIENT,
  current: sonarr_client_current
)
exercise_stable(
  failures, relationship: "Sonarr SABnzbd client", kind: :download_client,
  state: sonarr_client_state, variables: sonarr_variables, write_matcher: client_write,
  projection: method(:download_client_projection), desired: SONARR_DOWNLOAD_CLIENT,
  current: sonarr_client_current
)
sonarr_blank_category_state = deep_copy(sonarr_client_state)
sonarr_blank_category_state.fetch("download_clients").first.fetch("fields") <<
  { "name" => "movieCategory", "value" => "" }
exercise_stable(
  failures, relationship: "Sonarr SABnzbd client blank non-applicable category",
  kind: :download_client, state: sonarr_blank_category_state,
  variables: sonarr_variables, write_matcher: client_write,
  projection: method(:download_client_projection), desired: SONARR_DOWNLOAD_CLIENT,
  current: sonarr_client_current
)
%w[apiKey username password].each do |secret_field|
  secret_state = deep_copy(sonarr_client_state)
  old_secret = "private-stale-sonarr-#{secret_field}"
  set_field!(secret_state.fetch("download_clients").first, secret_field, old_secret)
  variable = {
    "apiKey" => "vault_downloaders_sabnzbd_api_key",
    "username" => "vault_downloaders_sabnzbd_admin_username",
    "password" => "vault_downloaders_sabnzbd_admin_password"
  }.fetch(secret_field)
  exercise_secret_change(
    failures, relationship: "Sonarr SABnzbd client", kind: :download_client,
    state: secret_state, field: "fields.#{secret_field}",
    variables: sonarr_variables,
    old_variables: sonarr_variables.merge(variable => old_secret),
    write_matcher: client_write, projection: method(:download_client_projection),
    desired: SONARR_DOWNLOAD_CLIENT, current: sonarr_client_current
  )
end
duplicate_sonarr_clients = deep_copy(sonarr_client_state)
duplicate_sonarr_clients.fetch("download_clients") << deep_copy(SONARR_DOWNLOAD_CLIENT).merge("id" => 24)
exercise_duplicate(
  failures, relationship: "Sonarr SABnzbd client", kind: :download_client,
  state: duplicate_sonarr_clients, variables: sonarr_variables, write_matcher: client_write
)

indexer_state = { "indexers" => [deep_copy(INDEXER)] }
indexer_mutations = {
  "name" => ->(state) { state.fetch("indexers").first["name"] = "Legacy Indexer" },
  "enable" => ->(state) { state.fetch("indexers").first["enable"] = false },
  "priority" => ->(state) { state.fetch("indexers").first["priority"] = 50 },
  "implementation" => ->(state) { state.fetch("indexers").first["implementation"] = "Legacy" },
  "implementationName" => ->(state) { state.fetch("indexers").first["implementationName"] = "Legacy" },
  "configContract" => ->(state) { state.fetch("indexers").first["configContract"] = "LegacySettings" },
  "sorted tags" => ->(state) { state.fetch("indexers").first["tags"] = [44] },
  "fields.baseUrl" => ->(state) { set_field!(state.fetch("indexers").first, "baseUrl", "https://legacy.invalid") },
  "fields.apiPath" => ->(state) { set_field!(state.fetch("indexers").first, "apiPath", "/legacy") },
  "fields.orderedValues" => lambda do |state|
    set_field!(state.fetch("indexers").first, "orderedValues", [2, { "nested" => 1 }, "first"])
  end,
  "fields.categories" => ->(state) { set_field!(state.fetch("indexers").first, "categories", [9999]) },
  "fields.minimumSeeders" => ->(state) { set_field!(state.fetch("indexers").first, "minimumSeeders", 99) }
}
indexer_write = ->(request) { request["target"].match?(%r{\A/api/v1/indexer(?:/\d+)?\z}) }
indexer_current = lambda do |state|
  state.fetch("indexers").find { |item| item["name"] == INDEXER.fetch("name") }
end
exercise_mutations(
  failures, relationship: "Prowlarr indexer", kind: :indexer,
  baseline: indexer_state, mutations: indexer_mutations,
  write_matcher: indexer_write, projection: method(:indexer_projection),
  desired: INDEXER, current: indexer_current
)
exercise_stable(
  failures, relationship: "Prowlarr indexer", kind: :indexer,
  state: indexer_state, write_matcher: indexer_write,
  projection: method(:indexer_projection), desired: INDEXER,
  current: indexer_current
)
category_order_state = deep_copy(indexer_state)
set_field!(category_order_state.fetch("indexers").first, "categories", [2000, 5000])
exercise_stable(
  failures, relationship: "Prowlarr unordered indexer categories", kind: :indexer,
  state: category_order_state, write_matcher: indexer_write,
  projection: method(:indexer_projection), desired: INDEXER,
  current: indexer_current
)
malformed_category_state = deep_copy(indexer_state)
set_field!(malformed_category_state.fetch("indexers").first, "categories", [5000, [2000]])
exercise_duplicate(
  failures, relationship: "Prowlarr malformed indexer categories", kind: :indexer,
  state: malformed_category_state, variables: {}, write_matcher: indexer_write
)
missing_indexer_api_key_state = deep_copy(indexer_state)
remove_field!(missing_indexer_api_key_state.fetch("indexers").first, "apiKey")
exercise_duplicate(
  failures, relationship: "Prowlarr missing readable indexer API key", kind: :indexer,
  state: missing_indexer_api_key_state, variables: {}, write_matcher: indexer_write
)
indexer_secret_state = deep_copy(indexer_state)
set_field!(indexer_secret_state.fetch("indexers").first, "apiKey", "private-stale-indexer-secret")
exercise_secret_change(
  failures, relationship: "Prowlarr indexer", kind: :indexer,
  state: indexer_secret_state, field: "fields.apiKey",
  variables: {},
  old_variables: {
    "media_arr_indexers" => [deep_copy(INDEXER_DECLARATION).tap do |declaration|
      set_field!(declaration, "apiKey", "private-stale-indexer-secret")
    end]
  }, write_matcher: indexer_write, projection: method(:indexer_projection),
  desired: INDEXER, current: indexer_current
)
duplicate_indexers = deep_copy(indexer_state)
duplicate_indexers.fetch("indexers") << deep_copy(INDEXER).merge("id" => 32)
exercise_duplicate(
  failures, relationship: "Prowlarr indexer", kind: :indexer,
  state: duplicate_indexers, variables: {}, write_matcher: indexer_write
)
malformed_indexer_declaration = deep_copy(INDEXER_DECLARATION)
malformed_indexer_declaration.fetch("fields").last.delete("value")
indexer_declaration_preflight_state = deep_copy(indexer_state)
indexer_declaration_preflight_state.fetch("indexers").first["priority"] = 50
exercise_duplicate(
  failures, relationship: "Prowlarr malformed later indexer declaration", kind: :indexer,
  state: indexer_declaration_preflight_state,
  variables: {
    "media_arr_indexers" => [
      deep_copy(INDEXER_DECLARATION), malformed_indexer_declaration.merge(
        "name" => "Malformed Later Indexer"
      )
    ]
  },
  write_matcher: indexer_write
)
malformed_later_current_indexer_state = deep_copy(indexer_declaration_preflight_state)
malformed_later_current_indexer_state.fetch("indexers") << {
  "id" => 33,
  "name" => "Malformed Later Current Indexer",
  "fields" => [{ "name" => "baseUrl" }]
}
exercise_duplicate(
  failures, relationship: "Prowlarr malformed later current indexer", kind: :indexer,
  state: malformed_later_current_indexer_state,
  variables: {}, write_matcher: indexer_write
)

if ENV["ACQUISITION_RELATIONSHIPS_TARGETED_ONLY"] == "1"
  abort failures.join("\n") unless failures.empty?
  puts "media acquisition relationship reconciliation behavior holds"
  exit
end
end

FINGERPRINT_BASELINE_CACHE["enabled"] = true if OPAQUE_TARGETED_ONLY

%w[matching stale_input stale_state stale_opaque].each do |scenario|
  Dir.mktmpdir("media-acquisition-configarr-verify-only-") do |directory|
    runtime = File.join(directory, "runtime")
    FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
    state = {
      "configarr" => deep_copy(CONFIGARR),
      "configarr_desired" => deep_copy(CONFIGARR)
    }
    if scenario == "stale_state"
      state.dig("configarr", "radarr", "qualityprofile").first["minFormatScore"] = 999
    elsif scenario == "stale_opaque"
      definition = state.dig("configarr", "sonarr", "qualitydefinition").find do |item|
        item.dig("quality", "name") == "Raw-HD"
      end
      definition["id"] += 100
    end
    with_api(state) do |api|
      instances = [SERVARR_INSTANCE, SONARR_INSTANCE].map do |instance|
        deep_copy(instance).merge(
          "api" => "http://127.0.0.1:#{api.port}/#{instance.fetch('name')}/api/v3"
        )
      end
      variables = base_variables(api.port).merge(
        "platform_runtime_dir" => runtime,
        "arr_servarr_instances" => instances
      )
      fingerprint_variables = deep_copy(variables)
      if scenario == "stale_input"
        fingerprint_variables["vault_arr_radarr_api_key"] = "private-stale-radarr-apikey"
      end
      seed_fingerprint_baseline(
        runtime, fingerprint_variables, kind: :configarr, state: state
      )
      before = fingerprint_snapshot(runtime)
      callback_directory = write_event_callback(directory)
      env = {
        "ANSIBLE_NOCOLOR" => "1", "ANSIBLE_CALLBACK_PLUGINS" => callback_directory,
        "ANSIBLE_CALLBACKS_ENABLED" => "acquisition_fixture_events",
        "ACQUISITION_FIXTURE_EVENT_LOG" => File.join(directory, "ansible-events.jsonl")
      }
      playbook = File.join(directory, "playbook.yml")
      write_playbook(playbook, variables, configarr_verify_only_tasks)
      result = run_playbook(playbook, env, "--tags", "platform_verify_arr")
      if scenario == "matching"
        failures << "Configarr verify-only matching state failed: #{sanitized_tail(result)}" unless
          result.fetch("status").success?
      elsif result.fetch("status").success?
        failures << "Configarr verify-only #{scenario.tr('_', ' ')} was accepted"
      end
      failures << "Configarr verify-only #{scenario} reached a mutation" unless
        mutation_requests(api, ->(_request) { true }).empty?
      failures << "Configarr verify-only #{scenario} changed reconciliation hashes" unless
        fingerprint_snapshot(runtime) == before
    end
  end
end

bazarr_state = { "bazarr" => deep_copy(BAZARR) }
bazarr_mutations = {
  "auth.type" => ->(state) { state.dig("bazarr", "auth")["type"] = "basic" },
  "auth.type nullable default" => ->(state) { state.dig("bazarr", "auth")["type"] = nil },
  "auth.username" => ->(state) { state.dig("bazarr", "auth")["username"] = "legacy" },
  "general.use_radarr" => ->(state) { state.dig("bazarr", "general")["use_radarr"] = false },
  "general.use_sonarr" => ->(state) { state.dig("bazarr", "general")["use_sonarr"] = false },
  "radarr.ip" => ->(state) { state.dig("bazarr", "radarr")["ip"] = "legacy-radarr" },
  "radarr.port" => ->(state) { state.dig("bazarr", "radarr")["port"] = 9999 },
  "radarr.base_url" => ->(state) { state.dig("bazarr", "radarr")["base_url"] = "/legacy" },
  "radarr.ssl" => ->(state) { state.dig("bazarr", "radarr")["ssl"] = true },
  "sonarr.ip" => ->(state) { state.dig("bazarr", "sonarr")["ip"] = "legacy-sonarr" },
  "sonarr.port" => ->(state) { state.dig("bazarr", "sonarr")["port"] = 9999 },
  "sonarr.base_url" => ->(state) { state.dig("bazarr", "sonarr")["base_url"] = "/legacy" },
  "sonarr.ssl" => ->(state) { state.dig("bazarr", "sonarr")["ssl"] = true },
  "identical series paths" => ->(state) { state.dig("bazarr", "general")["path_mappings"] = [["/old", "/new"]] },
  "identical movie paths" => ->(state) { state.dig("bazarr", "general")["path_mappings_movie"] = [["/old", "/new"]] },
  "sorted languages" => ->(state) { state.dig("bazarr", "languages")["enabled"] = ["fr"] }
}
bazarr_connection_write = lambda do |request|
  request["method"] == "POST" && request["target"] == "/api/system/settings" &&
    Array(request["form"]).any? { |key, _value| key == "settings-auth-type" }
end
bazarr_current = ->(state) { state.fetch("bazarr") }
exercise_mutations(
  failures, relationship: "Bazarr connection", kind: :bazarr,
  baseline: bazarr_state, mutations: bazarr_mutations,
  write_matcher: bazarr_connection_write, projection: method(:bazarr_projection),
  desired: BAZARR, current: bazarr_current
)
exercise_stable(
  failures, relationship: "Bazarr connection", kind: :bazarr,
  state: bazarr_state, write_matcher: bazarr_connection_write,
  projection: method(:bazarr_projection), desired: BAZARR,
  current: bazarr_current,
  safe_request_body: ->(request) { canonical_bazarr_connection_body?(request, []) }
)
{
  "series mapping entry is not a pair" => ["path_mappings", ["/old"]],
  "movie mapping entry has extra fields" => [
    "path_mappings_movie", ["/old", "/new", "/extra"]
  ],
  "series mapping entry is not a sequence" => [
    "path_mappings", { "from" => "/old", "to" => "/new" }
  ],
  "movie mapping source is not a string" => ["path_mappings_movie", [7, "/new"]],
  "series mapping target is not a string" => ["path_mappings", ["/old", false]]
}.each do |label, (field, entry)|
  malformed_mapping_state = deep_copy(bazarr_state)
  malformed_mapping_state.dig("bazarr", "general")[field] = [entry]
  exercise_duplicate(
    failures,
    relationship: "Bazarr malformed #{label}",
    kind: :bazarr,
    state: malformed_mapping_state,
    variables: {},
    write_matcher: ->(request) { request["target"] == "/api/system/settings" }
  )
end
{
  "auth.password" => ["auth", "password"],
  "radarr.apikey" => ["radarr", "apikey"],
  "sonarr.apikey" => ["sonarr", "apikey"]
}.each do |label, (section, field)|
  secret_state = deep_copy(bazarr_state)
  old_secret = "private-stale-#{section}-#{field}"
  secret_state.dig("bazarr", section)[field] = old_secret
  variable = {
    "auth.password" => "vault_arr_bazarr_admin_password",
    "radarr.apikey" => "vault_arr_radarr_api_key",
    "sonarr.apikey" => "vault_arr_sonarr_api_key"
  }.fetch(label)
  exercise_secret_change(
    failures, relationship: "Bazarr connection", kind: :bazarr,
    state: secret_state, field: label,
    variables: {}, old_variables: { variable => old_secret },
    write_matcher: bazarr_connection_write, projection: method(:bazarr_projection),
    desired: BAZARR, current: bazarr_current,
    safe_request_body: ->(request) { canonical_bazarr_connection_body?(request, []) },
    expected_fingerprint_kinds:
      (%w[radarr.apikey sonarr.apikey].include?(label) ? %i[bazarr configarr] : nil)
  )
end

language_input_state = deep_copy(bazarr_state)
language_input_state.dig("bazarr", "languages")["enabled"] = ["fr"]
exercise_secret_change(
  failures, relationship: "Bazarr connection", kind: :bazarr,
  state: language_input_state, field: "language desired input",
  variables: {}, old_variables: { "media_bazarr_languages" => ["fr"] },
  write_matcher: bazarr_connection_write, projection: method(:bazarr_projection),
  desired: BAZARR, current: bazarr_current,
  safe_request_body: ->(request) { canonical_bazarr_connection_body?(request, []) }
)

provider_state = { "bazarr" => deep_copy(BAZARR_WITH_PROVIDER) }
provider_variables = { "media_bazarr_providers" => [deep_copy(BAZARR_PROVIDER)] }
provider_mutations = {
  "provider.username" => ->(state) { state.dig("bazarr", "providers", "opensubtitlescom")["username"] = "legacy" },
  "provider.use_hash" => lambda do |state|
    state.dig("bazarr", "providers", "opensubtitlescom")["use_hash"] = false
  end,
  "provider.include_ai_translated" => lambda do |state|
    state.dig("bazarr", "providers", "opensubtitlescom")["include_ai_translated"] = true
  end,
  "provider.include_machine_translated" => lambda do |state|
    state.dig("bazarr", "providers", "opensubtitlescom")["include_machine_translated"] = true
  end
}
provider_write = lambda do |request|
  request["method"] == "POST" && request["target"] == "/api/system/settings" &&
    Array(request["form"]).any? { |key, _value| key.start_with?("settings-opensubtitlescom-") }
end
provider_projection = lambda do |settings|
  bazarr_projection(settings, [BAZARR_PROVIDER])
end
exercise_mutations(
  failures, relationship: "Bazarr provider", kind: :bazarr,
  baseline: provider_state, mutations: provider_mutations, variables: provider_variables,
  write_matcher: provider_write, projection: provider_projection,
  desired: BAZARR_WITH_PROVIDER, current: bazarr_current
)
provider_enablement_mutation = {
  "declared provider enablement" => lambda do |state|
    state.dig("bazarr", "general")["enabled_providers"] = []
  end
}
exercise_mutations(
  failures, relationship: "Bazarr provider", kind: :bazarr,
  baseline: provider_state, mutations: provider_enablement_mutation,
  variables: provider_variables, write_matcher: bazarr_connection_write,
  projection: provider_projection, desired: BAZARR_WITH_PROVIDER, current: bazarr_current
)
duplicate_provider_variables = {
  "media_bazarr_providers" => [deep_copy(BAZARR_PROVIDER), deep_copy(BAZARR_PROVIDER)]
}
exercise_duplicate(
  failures, relationship: "Bazarr provider", kind: :bazarr,
  state: provider_state, variables: duplicate_provider_variables,
  write_matcher: ->(request) { request["target"] == "/api/system/settings" }
)
exercise_stable(
  failures, relationship: "Bazarr provider", kind: :bazarr,
  state: provider_state, variables: provider_variables, write_matcher: provider_write,
  projection: provider_projection, desired: BAZARR_WITH_PROVIDER,
  current: bazarr_current,
  safe_request_body: ->(request) { canonical_bazarr_provider_body?(request) }
)
boolean_provider = deep_copy(BAZARR_PROVIDER)
boolean_provider.fetch("settings").merge!(
  "settings-opensubtitlescom-use_hash" => true,
  "settings-opensubtitlescom-include_ai_translated" => false,
  "settings-opensubtitlescom-include_machine_translated" => false
)
boolean_variables = { "media_bazarr_providers" => [boolean_provider] }
boolean_state = deep_copy(provider_state)
boolean_state.dig("bazarr", "providers", "opensubtitlescom")["use_hash"] = false

Dir.mktmpdir("media-acquisition-bazarr-boolean-boundary-") do |runtime|
  FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
  with_api(boolean_state) do |api|
    variables = base_variables(api.port).merge(boolean_variables)
    seed_fingerprint_baseline(runtime, variables, kind: :bazarr, state: boolean_state)
    first = run_tasks(
      :bazarr, api, boolean_variables,
      runtime: runtime, prepare_fingerprints: false
    )
    sane = check_sanity(
      failures, "Bazarr actual boolean provider declaration", first, api, kind: :bazarr
    )
    if sane
      failures << "Bazarr actual boolean provider declaration did not converge" unless
        first.fetch("status").success?
      writes = mutation_requests(api, provider_write)
      failures << "Bazarr actual boolean provider declaration did not write exactly once" unless
        writes.length == 1
      expected_values = {
        "settings-opensubtitlescom-use_hash" => "true",
        "settings-opensubtitlescom-include_ai_translated" => "false",
        "settings-opensubtitlescom-include_machine_translated" => "false"
      }
      submitted = Array(writes.first&.fetch("form", nil)).to_h
      failures << "Bazarr actual boolean provider declaration was not serialized canonically" unless
        submitted.slice(*expected_values.keys) == expected_values
      after_first = fingerprint_snapshot(runtime)
      failures << "Bazarr actual boolean provider declaration did not record fingerprints" unless
        first.fetch("recorder_started")
      failures << "Bazarr actual boolean provider declaration did not apply true" unless
        api.state.dig("bazarr", "providers", "opensubtitlescom", "use_hash") == true

      request_count = api.requests.length
      second = run_tasks(
        :bazarr, api, boolean_variables,
        runtime: runtime, prepare_fingerprints: false
      )
      sane = check_sanity(
        failures, "Bazarr stable actual boolean provider declaration",
        second, api, kind: :bazarr
      )
      if sane
        second_mutations = api.requests.drop(request_count).select do |request|
          %w[POST PUT PATCH DELETE].include?(request.fetch("method"))
        end
        failures << "Bazarr stable actual boolean provider declaration mutated again" unless
          second_mutations.empty?
        failures << "Bazarr stable actual boolean provider declaration reported changed" unless
          second.fetch("reconciliation_changed") == 0
        failures << "Bazarr stable actual boolean provider declaration rewrote fingerprints" unless
          fingerprint_snapshot(runtime) == after_first
      end
    end
  end
end
provider_secret_state = deep_copy(provider_state)
provider_secret_state.dig("bazarr", "providers", "opensubtitlescom")["password"] = "private-stale-provider-secret"
old_provider = deep_copy(BAZARR_PROVIDER)
old_provider.fetch("settings")["settings-opensubtitlescom-password"] = "private-stale-provider-secret"
exercise_secret_change(
  failures, relationship: "Bazarr provider", kind: :bazarr,
  state: provider_secret_state, field: "provider.password",
  variables: provider_variables,
  old_variables: { "media_bazarr_providers" => [old_provider] },
  write_matcher: ->(request) { request["target"] == "/api/system/settings" },
  projection: provider_projection,
  desired: BAZARR_WITH_PROVIDER, current: bazarr_current,
  expected_writes: 2, expected_changed: 2,
  write_set_validator: lambda do |requests|
    canonical_bazarr_complete_write_set?(requests, [BAZARR_PROVIDER])
  end
)
exercise_secret_change(
  failures, relationship: "Bazarr masked provider compatibility", kind: :bazarr,
  state: provider_secret_state, field: "provider.password",
  variables: provider_variables,
  old_variables: { "media_bazarr_providers" => [old_provider] },
  write_matcher: ->(request) { request["target"] == "/api/system/settings" },
  projection: provider_projection,
  desired: BAZARR_WITH_PROVIDER, current: bazarr_current,
  expected_writes: 2, expected_changed: 2,
  write_set_validator: lambda do |requests|
    canonical_bazarr_complete_write_set?(requests, [BAZARR_PROVIDER])
  end,
  api_options: { mask_bazarr_provider_secrets: true }
)
unmanaged_provider_state = deep_copy(provider_state)
unmanaged_provider_state.dig("bazarr", "general", "enabled_providers") << "unmanaged-provider"
unmanaged_provider_state.dig("bazarr", "providers")["unmanaged-provider"] = {
  "username" => "unmanaged-user", "unmanaged_option" => "preserve-unmanaged-provider"
}
unmanaged_provider_state.dig("bazarr", "providers", BAZARR_PROVIDER.fetch("name"))[
  "unmanaged_option"
] = "preserve-declared-provider-extra"
exercise_stable(
  failures, relationship: "Bazarr declared provider with unmanaged state", kind: :bazarr,
  state: unmanaged_provider_state, variables: provider_variables,
  write_matcher: ->(request) { request["target"] == "/api/system/settings" },
  projection: provider_projection,
  desired: BAZARR_WITH_PROVIDER, current: bazarr_current,
  preserved: lambda do |state, _before|
    settings = state.fetch("bazarr")
    settings.dig("providers", "unmanaged-provider") == {
      "username" => "unmanaged-user", "unmanaged_option" => "preserve-unmanaged-provider"
    } &&
      settings.dig("providers", BAZARR_PROVIDER.fetch("name"), "unmanaged_option") ==
        "preserve-declared-provider-extra" &&
      settings.dig("general", "enabled_providers").include?("unmanaged-provider")
  end
)
exercise_mutations(
  failures, relationship: "Bazarr declared provider with unmanaged state", kind: :bazarr,
  baseline: unmanaged_provider_state,
  mutations: {
    "declared readable setting" => lambda do |state|
      state.dig("bazarr", "providers", BAZARR_PROVIDER.fetch("name"))["username"] = "legacy"
    end
  },
  variables: provider_variables, write_matcher: provider_write,
  projection: provider_projection, desired: BAZARR_WITH_PROVIDER, current: bazarr_current,
  preserved: lambda do |state, _before|
    settings = state.fetch("bazarr")
    settings.dig("providers", "unmanaged-provider") == {
      "username" => "unmanaged-user", "unmanaged_option" => "preserve-unmanaged-provider"
    } &&
      settings.dig("providers", BAZARR_PROVIDER.fetch("name"), "unmanaged_option") ==
        "preserve-declared-provider-extra" &&
      settings.dig("general", "enabled_providers").include?("unmanaged-provider")
  end
)
exercise_mutations(
  failures, relationship: "Bazarr declared provider enablement with unmanaged state", kind: :bazarr,
  baseline: unmanaged_provider_state,
  mutations: {
    "declared enablement" => lambda do |state|
      state.dig("bazarr", "general", "enabled_providers").delete(BAZARR_PROVIDER.fetch("name"))
    end
  },
  variables: provider_variables, write_matcher: bazarr_connection_write,
  projection: provider_projection, desired: BAZARR_WITH_PROVIDER, current: bazarr_current,
  preserved: lambda do |state, _before|
    state.dig("bazarr", "general", "enabled_providers").include?("unmanaged-provider") &&
      state.dig("bazarr", "providers", "unmanaged-provider", "unmanaged_option") ==
        "preserve-unmanaged-provider"
  end
)

typed_provider_settings = deep_copy(BAZARR)
typed_provider_settings.dig("general", "enabled_providers") << "animetosho"
typed_provider_settings.fetch("providers")["animetosho"] = {
  "search_threshold" => 6, "exclude" => []
}
typed_provider_state = { "bazarr" => typed_provider_settings }
typed_provider_variables = {
  "media_bazarr_providers" => [deep_copy(BAZARR_TYPED_PROVIDER)]
}
typed_provider_write = lambda do |request|
  request["method"] == "POST" && request["target"] == "/api/system/settings" &&
    Array(request["form"]).any? { |key, _value| key.start_with?("settings-animetosho-") }
end
exercise_mutations(
  failures, relationship: "Bazarr typed provider", kind: :bazarr,
  baseline: typed_provider_state,
  mutations: {
    "numeric string canonicalization" => lambda do |state|
      state.dig("bazarr", "providers", "animetosho")["search_threshold"] = 7
    end,
    "empty array sentinel" => lambda do |state|
      state.dig("bazarr", "providers", "animetosho")["exclude"] = ["legacy"]
    end
  },
  variables: typed_provider_variables, write_matcher: typed_provider_write,
  projection: lambda { |settings| bazarr_projection(settings, [BAZARR_TYPED_PROVIDER]) },
  desired: typed_provider_settings, current: bazarr_current
)
exercise_stable(
  failures, relationship: "Bazarr typed provider", kind: :bazarr,
  state: typed_provider_state, variables: typed_provider_variables,
  write_matcher: typed_provider_write,
  projection: lambda { |settings| bazarr_projection(settings, [BAZARR_TYPED_PROVIDER]) },
  desired: typed_provider_settings, current: bazarr_current
)
exercise_duplicate(
  failures, relationship: "Bazarr language declaration", kind: :bazarr,
  state: bazarr_state, variables: { "media_bazarr_languages" => %w[en en] },
  write_matcher: ->(request) { request["target"] == "/api/system/settings" }
)
{
  "missing auth password" => lambda do |state|
    state.dig("bazarr", "auth").delete("password")
  end,
  "non-string Radarr host" => lambda do |state|
    state.dig("bazarr", "radarr")["ip"] = 1
  end,
  "non-integer Radarr port" => lambda do |state|
    state.dig("bazarr", "radarr")["port"] = "7878"
  end,
  "non-boolean Sonarr SSL" => lambda do |state|
    state.dig("bazarr", "sonarr")["ssl"] = "false"
  end
}.each do |label, mutate|
  invalid_state = deep_copy(bazarr_state)
  mutate.call(invalid_state)
  exercise_duplicate(
    failures, relationship: "Bazarr invalid current #{label}", kind: :bazarr,
    state: invalid_state, variables: {},
    write_matcher: ->(request) { request["target"] == "/api/system/settings" }
  )
end
{
  "language mapping" => { "media_bazarr_languages" => { "en" => true } },
  "language scalar" => { "media_bazarr_languages" => "en" },
  "language non-string" => { "media_bazarr_languages" => ["en", 1] },
  "language non-canonical" => { "media_bazarr_languages" => ["EN"] },
  "provider mapping" => { "media_bazarr_providers" => { "name" => "opensubtitlescom" } },
  "provider non-mapping" => { "media_bazarr_providers" => ["opensubtitlescom"] },
  "provider empty name" => {
    "media_bazarr_providers" => [{ "name" => "", "settings" => {} }]
  },
  "provider empty settings" => {
    "media_bazarr_providers" => [{ "name" => "opensubtitlescom", "settings" => {} }]
  },
  "provider wrong setting prefix" => {
    "media_bazarr_providers" => [{
      "name" => "opensubtitlescom",
      "settings" => { "settings-other-password" => "unsafe" }
    }]
  },
  "provider empty setting suffix" => {
    "media_bazarr_providers" => [{
      "name" => "opensubtitlescom",
      "settings" => { "settings-opensubtitlescom-" => "unsafe" }
    }]
  },
  "provider ambiguous hyphenated name" => {
    "media_bazarr_providers" => [{
      "name" => "open-subtitles",
      "settings" => { "settings-open-subtitles-password" => "unsafe" }
    }]
  },
  "provider ambiguous hyphenated setting suffix" => {
    "media_bazarr_providers" => [{
      "name" => "opensubtitlescom",
      "settings" => { "settings-opensubtitlescom-api-key" => "unsafe" }
    }]
  },
  "provider unsafe setting mapping" => {
    "media_bazarr_providers" => [{
      "name" => "opensubtitlescom",
      "settings" => { "settings-opensubtitlescom-password" => { "unsafe" => true } }
    }]
  },
  "provider unsafe nested list" => {
    "media_bazarr_providers" => [{
      "name" => "opensubtitlescom",
      "settings" => { "settings-opensubtitlescom-options" => [["unsafe"]] }
    }]
  }
}.each do |label, variables|
  exercise_duplicate(
    failures, relationship: "Bazarr invalid #{label}", kind: :bazarr,
    state: provider_state, variables: variables,
    write_matcher: ->(request) { request["target"] == "/api/system/settings" }
  )
end

configarr_state = { "configarr" => deep_copy(CONFIGARR), "configarr_desired" => deep_copy(CONFIGARR) }
%w[radarr sonarr].each do |service|
  colliding_profile_tree_state = deep_copy(configarr_state)
  colliding_definition = colliding_profile_tree_state.dig(
    "configarr", service, "qualitydefinition"
  ).find { |definition| definition.dig("quality", "name") == "WEBDL-1080p" }
  colliding_definition.fetch("quality")["id"] = 1001
  colliding_profile_tree_state.dig(
    "configarr", service, "qualityprofile", 0
  )["minFormatScore"] = 99

  other_service = service == "radarr" ? "sonarr" : "radarr"
  colliding_profile_tree_state.dig("configarr", other_service, "customformat").reject! do |format|
    format["name"] == CONFIGARR_FORMAT_NAME
  end
  colliding_profile_tree_state.dig(
    "configarr", other_service, "qualityprofile", 0, "formatItems"
  ).reject! { |assignment| assignment["name"] == CONFIGARR_FORMAT_NAME }

  Dir.mktmpdir("media-acquisition-configarr-profile-tree-id-") do |runtime|
    FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
    with_api(colliding_profile_tree_state) do |api|
      variables = base_variables(api.port)
      seed_fingerprint_baseline(
        runtime, variables, kind: :configarr, state: configarr_state
      )
      File.unlink(File.join(runtime, "services", "arr", CONFIGARR_OPAQUE_FINGERPRINT_FILE))
      before = fingerprint_snapshot(runtime)
      result = run_tasks(
        :configarr, api, {}, runtime: runtime, prepare_fingerprints: false
      )
      sane = check_sanity(
        failures,
        "Configarr #{service} recursive profile-tree numeric identity",
        result,
        api,
        kind: :configarr
      )
      next unless sane

      failures << "Configarr #{service} recursive profile-tree numeric identity was accepted" if
        result.fetch("status").success?
      failures << "Configarr #{service} recursive profile-tree numeric identity reached mutation" unless
        mutation_requests(api, ->(_request) { true }).empty?
      failures << "Configarr #{service} recursive profile-tree numeric identity reached fingerprint recording" if
        result.fetch("recorder_started")
      failures << "Configarr #{service} recursive profile-tree numeric identity advanced a fingerprint" unless
        fingerprint_snapshot(runtime) == before
    end
  end
end
[
  ["radarr", "string", "corrupt"],
  ["sonarr", "boolean", true],
  ["radarr", "list", []],
  ["sonarr", "number", 7]
].each do |service, label, invalid_quality|
  malformed_quality_state = deep_copy(configarr_state)
  profile_group = malformed_quality_state.dig(
    "configarr", service, "qualityprofile", 0, "items"
  ).find { |item| item["name"] == "WEB 1080p" }
  profile_group["quality"] = invalid_quality
  other_service = service == "radarr" ? "sonarr" : "radarr"
  malformed_quality_state.dig(
    "configarr", other_service, "customformat"
  ).reject! { |format| format["name"] == CONFIGARR_FORMAT_NAME }

  Dir.mktmpdir("media-acquisition-configarr-quality-discriminator-") do |runtime|
    FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
    with_api(malformed_quality_state) do |api|
      variables = base_variables(api.port)
      seed_fingerprint_baseline(
        runtime, variables, kind: :configarr, state: configarr_state
      )
      before = fingerprint_snapshot(runtime)
      result = run_tasks(
        :configarr, api, {}, runtime: runtime, prepare_fingerprints: false
      )
      sane = check_sanity(
        failures, "Configarr #{service} non-mapping quality #{label}",
        result, api, kind: :configarr
      )
      next unless sane

      failures << "Configarr #{service} non-mapping quality #{label} was accepted" if
        result.fetch("status").success?
      failures << "Configarr #{service} non-mapping quality #{label} reached mutation" unless
        mutation_requests(api, ->(_request) { true }).empty?
      failures << "Configarr #{service} non-mapping quality #{label} reached fingerprint recording" if
        result.fetch("recorder_started")
      failures << "Configarr #{service} non-mapping quality #{label} advanced a fingerprint" unless
        fingerprint_snapshot(runtime) == before
    end
  end
end
if API_BOUNDARY_TARGETED_ONLY
  abort failures.join("\n") unless failures.empty?
  puts "acquisition API boundary behavior holds"
  exit
end
if PROFILE_TREE_ID_TARGETED_ONLY
  abort failures.join("\n") unless failures.empty?
  puts "Configarr recursive profile-tree identity preflight behavior holds"
  exit
end
configarr_mutations = {}
%w[radarr sonarr].each do |service|
  service_name = service.dup
  profile_mutations = {
    "name" => ->(profile) { profile["name"] = "Legacy Profile" },
    "upgradeAllowed" => ->(profile) { profile["upgradeAllowed"] = true },
    "cutoff" => ->(profile) { profile["cutoff"] = 9 },
    "minFormatScore" => ->(profile) { profile["minFormatScore"] = 100 },
    "cutoffFormatScore" => ->(profile) { profile["cutoffFormatScore"] = 100 },
    "minUpgradeFormatScore" => ->(profile) { profile["minUpgradeFormatScore"] = 100 },
    "reset unmatched scores outcome" => ->(profile) { profile["formatItems"].last["score"] = 99 },
    "quality sort/order outcome" => ->(profile) { profile["items"].reverse! },
    "quality structure" => lambda do |profile|
      profile.fetch("items").find { |item| item["name"] == "WEB 1080p" }.fetch("items").pop
    end,
    "non-cutoff nested item id" => lambda do |profile|
      profile.fetch("items").find { |item| item["name"] == "WEB 1080p" }
        .fetch("items").find { |item| item.dig("quality", "name") == "WEBDL-1080p" }
        .fetch("quality")["id"] = 999
    end,
    "format assignment name" => ->(profile) { profile["formatItems"].first["name"] = "Legacy Format" },
    "format assignment score" => ->(profile) { profile["formatItems"].first["score"] = 0 }
  }
  profile_mutations.each do |field, mutate_profile|
    configarr_mutations["#{service_name}.quality_profile.#{field}"] = lambda do |state|
      mutate_profile.call(state.dig("configarr", service_name, "qualityprofile").first)
    end
  end
  [
    ["HDTV-1080p", 0], ["Raw-HD", 1], ["Bluray-1080p", 3],
    ["WEB 1080p", 2], ["WEBRip-1080p", 2, 0], ["WEBDL-1080p", 2, 1]
  ].each do |quality_name, item_index, child_index|
    configarr_mutations["#{service_name}.quality_profile.#{quality_name}.name"] = lambda do |state|
      item = state.dig("configarr", service_name, "qualityprofile").first.fetch("items")[item_index]
      item = item.fetch("items")[child_index] unless child_index.nil?
      if item["quality"].is_a?(Hash)
        item.fetch("quality")["name"] = "Legacy Quality"
      else
        item["name"] = "Legacy Quality Group"
      end
    end
    configarr_mutations["#{service_name}.quality_profile.#{quality_name}.allowed"] = lambda do |state|
      item = state.dig("configarr", service_name, "qualityprofile").first.fetch("items")[item_index]
      item = item.fetch("items")[child_index] unless child_index.nil?
      item["allowed"] = !item.fetch("allowed")
    end
  end

  CONFIGARR.dig(service_name, "qualitydefinition").each_with_index do |definition, index|
    quality_name = definition.dig("quality", "name")
    # Configarr v1.28.0 only applies the three numeric TRaSH leaves in this
    # bundled configuration. Identity metadata, title and weight are retained
    # in the verified state hash and fail closed if they drift.
    definition_mutations = if quality_sizes.fetch(service_name).key?(quality_name)
      {
      "minSize" => ->(item) { item["minSize"] = item["minSize"].nil? ? 1 : item["minSize"] + 1 },
      "preferredSize" => lambda do |item|
        item["preferredSize"] = item["preferredSize"].nil? ? 1 : item["preferredSize"] + 1
      end,
      "maxSize" => ->(item) { item["maxSize"] = item["maxSize"].nil? ? 1 : item["maxSize"] + 1 }
      }
    else
      {}
    end
    definition_mutations.each do |field, mutate_definition|
      label = "#{service_name}.quality_definition.#{quality_name}.#{field}"
      configarr_mutations[label] = lambda do |state|
        item = state.dig("configarr", service_name, "qualitydefinition").fetch(index)
        mutate_definition.call(item)
      end
    end
  end

  {
    "name" => ->(format) { format["name"] = "Legacy Format" },
    "includeWhenRenaming" => ->(format) { format["includeCustomFormatWhenRenaming"] = true },
    "specification.name" => ->(format) { format.dig("specifications", 0)["name"] = "Legacy" },
    "specification.implementation" => lambda do |format|
      format.dig("specifications", 0)["implementation"] = "LegacySpecification"
    end,
    "specification.negate" => ->(format) { format.dig("specifications", 0)["negate"] = true },
    "specification.required" => ->(format) { format.dig("specifications", 0)["required"] = true },
    "specification.regex" => lambda do |format|
      format.dig("specifications", 0, "fields", 0)["value"] = "legacy-regex"
    end
  }.each do |field, mutate_format|
    configarr_mutations["#{service_name}.custom_format.#{field}"] = lambda do |state|
      mutate_format.call(state.dig("configarr", service_name, "customformat").first)
    end
  end
end
{
  "radarr.naming.renameMovies" => ["radarr", "renameMovies", true],
  "radarr.naming.standardMovieFormat" => ["radarr", "standardMovieFormat", "Legacy"],
  "radarr.naming.movieFolderFormat" => ["radarr", "movieFolderFormat", "Legacy"],
  "sonarr.naming.renameEpisodes" => ["sonarr", "renameEpisodes", true],
  "sonarr.naming.standardEpisodeFormat" => ["sonarr", "standardEpisodeFormat", "Legacy"],
  "sonarr.naming.dailyEpisodeFormat" => ["sonarr", "dailyEpisodeFormat", "Legacy"],
  "sonarr.naming.animeEpisodeFormat" => ["sonarr", "animeEpisodeFormat", "Legacy"],
  "sonarr.naming.seriesFolderFormat" => ["sonarr", "seriesFolderFormat", "Legacy"],
  "sonarr.naming.seasonFolderFormat" => ["sonarr", "seasonFolderFormat", "Legacy"]
}.each do |label, (service, field, value)|
  configarr_mutations[label] = lambda do |state|
    state.dig("configarr", service, "config/naming")[field] = value
  end
end
{
  "radarr.naming.nullable standard format" => ["radarr", "standardMovieFormat"],
  "sonarr.naming.nullable daily format" => ["sonarr", "dailyEpisodeFormat"]
}.each do |label, (service, field)|
  configarr_mutations[label] = lambda do |state|
    state.dig("configarr", service, "config/naming")[field] = nil
  end
end
configarr_write = lambda do |request|
  request["method"] == "POST" && request["target"] == "/_fixture/configarr/apply"
end
configarr_any_write = ->(_request) { true }
configarr_current = ->(state) { state.fetch("configarr") }
configarr_unmanaged_preserved = lambda do |state, before|
  %w[radarr sonarr].all? do |service|
    current = state.dig("configarr", service)
    previous = before.dig("configarr", service)
    previous_profile = previous.fetch("qualityprofile").find do |item|
      item["name"] == CONFIGARR_PROFILE_NAME
    end
    current_profile = current.fetch("qualityprofile").find do |item|
      item["name"] == CONFIGARR_PROFILE_NAME
    end
    unrelated_profile_fields_preserved = previous_profile.nil? ||
      %w[unmanagedProfileField language].all? do |field|
        !previous_profile.key?(field) || current_profile&.fetch(field, nil) == previous_profile[field]
      end

    previous.fetch("qualityprofile")
      .reject { |item| item["name"] == CONFIGARR_PROFILE_NAME }
      .all? { |item| current.fetch("qualityprofile").include?(item) } &&
      previous.fetch("customformat")
        .reject { |item| item["name"] == CONFIGARR_FORMAT_NAME }
        .all? { |item| current.fetch("customformat").include?(item) } &&
      unrelated_profile_fields_preserved
  end
end
if COMPLETE_PROFILE_TREE_TARGETED_ONLY
  %w[radarr sonarr].each do |service|
    id_drift_state = deep_copy(configarr_state)
    profile = id_drift_state.dig("configarr", service, "qualityprofile").first
    profile.fetch("items").find { |item| item["name"] == "WEB 1080p" }
      .fetch("items").find { |item| item.dig("quality", "name") == "WEBDL-1080p" }
      .fetch("quality")["id"] = 999

    Dir.mktmpdir("media-acquisition-configarr-complete-profile-tree-") do |runtime|
      FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
      with_api(id_drift_state) do |api|
        variables = base_variables(api.port)
        seed_fingerprint_baseline(
          runtime, variables, kind: :configarr, state: configarr_state
        )
        before = fingerprint_snapshot(runtime)
        first = run_tasks(
          :configarr, api, {}, runtime: runtime, prepare_fingerprints: false
        )
        sane = check_sanity(
          failures, "Configarr #{service} non-cutoff profile-tree ID drift",
          first, api, kind: :configarr
        )
        next unless sane

        failures << "Configarr #{service} non-cutoff profile-tree ID drift did not converge" unless
          first.fetch("status").success?
        profile_puts = mutation_requests(
          api,
          ->(request) do
            request["method"] == "PUT" &&
              request["target"].start_with?("/#{service}/api/v3/qualityprofile/")
          end
        )
        failures << "Configarr #{service} non-cutoff profile-tree ID drift was not repaired exactly once" unless
          profile_puts.length == 1
        jobs = mutation_requests(api, configarr_write)
        failures << "Configarr #{service} non-cutoff profile-tree ID drift did not run Configarr exactly once" unless
          jobs.length == 1
        after_first = fingerprint_snapshot(runtime)
        failures << "Configarr #{service} non-cutoff profile-tree ID drift changed desired input bytes" unless
          before.fetch(FINGERPRINT_FILE_BY_KIND.fetch(:configarr)) ==
            after_first.fetch(FINGERPRINT_FILE_BY_KIND.fetch(:configarr))
        failures << "Configarr #{service} non-cutoff profile-tree ID drift changed opaque continuity" unless
          before.fetch(CONFIGARR_OPAQUE_FINGERPRINT_FILE) ==
            after_first.fetch(CONFIGARR_OPAQUE_FINGERPRINT_FILE)
        failures << "Configarr #{service} non-cutoff profile-tree repair recorded stale full state" unless
          after_first.fetch(CONFIGARR_STATE_FINGERPRINT_FILE)&.fetch("content", nil) ==
            "#{configarr_state_fingerprint(api.state.fetch('configarr'))}\n"

        request_count = api.requests.length
        second = run_tasks(
          :configarr, api, {}, runtime: runtime, prepare_fingerprints: false
        )
        sane = check_sanity(
          failures, "Configarr #{service} stable repaired profile-tree IDs",
          second, api, kind: :configarr
        )
        next unless sane

        second_mutations = api.requests.drop(request_count).select do |request|
          %w[POST PUT PATCH DELETE].include?(request.fetch("method"))
        end
        failures << "Configarr #{service} stable repaired profile-tree IDs mutated again" unless
          second_mutations.empty?
        failures << "Configarr #{service} stable repaired profile-tree IDs reported changed" unless
          second.fetch("reconciliation_changed") == 0
        failures << "Configarr #{service} stable repaired profile-tree IDs rewrote fingerprints" unless
          fingerprint_snapshot(runtime) == after_first
      end
    end
  end

  invalid_profile_trees = {
    "zero ID" => lambda do |profile|
      profile.fetch("items").first.fetch("quality")["id"] = 0
    end,
    "negative ID" => lambda do |profile|
      profile.fetch("items").first.fetch("quality")["id"] = -1
    end,
    "boolean ID" => lambda do |profile|
      profile.fetch("items").first.fetch("quality")["id"] = true
    end,
    "string ID" => lambda do |profile|
      profile.fetch("items").first.fetch("quality")["id"] = "4"
    end,
    "over-depth tree" => lambda do |profile|
      leaf = {
        "quality" => { "id" => 3, "name" => "WEBDL-1080p" },
        "allowed" => true, "items" => []
      }
      16.downto(1) do |depth|
        leaf = {
          "id" => 2000 + depth, "name" => "level-#{depth}",
          "allowed" => true, "items" => [leaf]
        }
      end
      profile["items"] = [leaf]
      profile["cutoff"] = 3
    end,
    "over-count tree" => lambda do |profile|
      profile["items"] = 513.times.map do |index|
        {
          "quality" => { "id" => 3000 + index, "name" => "quality-#{index}" },
          "allowed" => true, "items" => []
        }
      end
      profile["cutoff"] = 3000
    end
  }
  invalid_profile_trees.each do |label, mutate|
    invalid_state = deep_copy(configarr_state)
    mutate.call(invalid_state.dig("configarr", "radarr", "qualityprofile").first)
    invalid_state.dig("configarr", "sonarr", "customformat").reject! do |format|
      format["name"] == CONFIGARR_FORMAT_NAME
    end

    Dir.mktmpdir("media-acquisition-configarr-invalid-profile-tree-") do |runtime|
      FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
      with_api(invalid_state) do |api|
        variables = base_variables(api.port)
        seed_fingerprint_baseline(
          runtime, variables, kind: :configarr, state: configarr_state
        )
        before = fingerprint_snapshot(runtime)
        result = run_tasks(
          :configarr, api, {}, runtime: runtime, prepare_fingerprints: false
        )
        sane = check_sanity(
          failures, "Configarr invalid #{label}", result, api, kind: :configarr
        )
        next unless sane

        failures << "Configarr invalid #{label} was accepted" if
          result.fetch("status").success?
        failures << "Configarr invalid #{label} reached mutation" unless
          mutation_requests(api, ->(_request) { true }).empty?
        failures << "Configarr invalid #{label} reached fingerprint recording" if
          result.fetch("recorder_started")
        failures << "Configarr invalid #{label} advanced a fingerprint" unless
          fingerprint_snapshot(runtime) == before
      end
    end
  end

  abort failures.join("\n") unless failures.empty?
  puts "complete Configarr profile-tree identity behavior holds"
  exit
end
%w[radarr sonarr].each do |service|
  configarr_mutations["#{service}.missing quality profile among unrelated profiles"] = lambda do |state|
    state.dig("configarr", service, "qualityprofile").reject! do |profile|
      profile["name"] == CONFIGARR_PROFILE_NAME
    end
  end
  configarr_mutations["#{service}.missing custom format among unrelated formats"] = lambda do |state|
    state.dig("configarr", service, "customformat").reject! do |format|
      format["name"] == CONFIGARR_FORMAT_NAME
    end
  end
  configarr_mutations["#{service}.missing format assignment among unrelated assignments"] = lambda do |state|
    profile = state.dig("configarr", service, "qualityprofile").find do |candidate|
      candidate["name"] == CONFIGARR_PROFILE_NAME
    end
    profile.fetch("formatItems").reject! { |item| item["name"] == CONFIGARR_FORMAT_NAME }
  end
  configarr_mutations["#{service}.empty format-score assignments"] = lambda do |state|
    profile = state.dig("configarr", service, "qualityprofile").find do |candidate|
      candidate["name"] == CONFIGARR_PROFILE_NAME
    end
    profile["formatItems"] = []
  end
end
if CONFIGARR_MUTATION_PATTERN
  selector = Regexp.new(CONFIGARR_MUTATION_PATTERN)
  configarr_mutations.select! { |field, _mutation| field.match?(selector) }
  abort "Configarr mutation selector matched no scenarios" if configarr_mutations.empty?
end
exercise_mutations(
  failures, relationship: "Configarr", kind: :configarr,
  baseline: configarr_state, mutations: configarr_mutations,
  write_matcher: configarr_write, projection: method(:configarr_projection),
  desired: CONFIGARR, current: configarr_current,
  preserved: configarr_unmanaged_preserved
)
if CONFIGARR_MUTATION_PATTERN
  abort failures.join("\n") unless failures.empty?
  puts "selected Configarr mutation reconciliation behavior holds"
  exit
end

# Configarr cannot restore server-owned qdef identity metadata, weight, title,
# or values for definitions absent from the pinned TRaSH input. An independent
# continuity hash must reject that drift before any mutation, even if a desired
# input changed or the broader owned-state hash is absent.
context_state = deep_copy(configarr_state)
%w[radarr sonarr].each do |service|
  definition = context_state.dig("configarr", service, "qualitydefinition").find do |item|
    item.dig("quality", "name") == "Raw-HD"
  end
  definition["id"] += 100
  definition.fetch("quality")["id"] += 100
  definition.fetch("quality")["source"] = "legacy"
  definition.fetch("quality")["resolution"] = 720
  definition.fetch("quality")["modifier"] = "legacy" if service == "radarr"
  definition["title"] = "Legacy Raw-HD"
  definition["weight"] += 100
  definition["minSize"] = 1
  definition["preferredSize"] = 2
  definition["maxSize"] = 3
end
{
  "existing opaque continuity" => {},
  "desired input transition plus opaque drift" => {
    "vault_arr_radarr_api_key" => "private-stale-radarr-apikey",
    "vault_arr_sonarr_api_key" => "private-stale-sonarr-apikey"
  },
  "missing full state plus opaque drift" => :remove_full_state
}.each do |label, seed_input|
  Dir.mktmpdir("media-acquisition-configarr-context-") do |runtime|
    FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
    with_api(deep_copy(context_state)) do |api|
      variables = base_variables(api.port)
      fingerprint_variables = deep_copy(variables)
      fingerprint_variables.merge!(seed_input) if seed_input.is_a?(Hash)
      seed_fingerprint_baseline(
        runtime, fingerprint_variables, kind: :configarr, state: context_state
      )
      if seed_input == :remove_full_state
        File.unlink(File.join(runtime, "services", "arr", CONFIGARR_STATE_FINGERPRINT_FILE))
      end
      before = fingerprint_snapshot(runtime)
      result = run_tasks(
        :configarr, api, {}, runtime: runtime, prepare_fingerprints: false
      )
      sane = check_sanity(
        failures, "Configarr #{label}", result, api,
        kind: :configarr
      )
      next unless sane

      failures << "Configarr #{label} accepted non-repairable qdef context drift" if
        result.fetch("status").success?
      failures << "Configarr #{label} reached a mutation" unless
        mutation_requests(api, configarr_any_write).empty?
      failures << "Configarr #{label} advanced a reconciliation hash" unless
        fingerprint_snapshot(runtime) == before
      failures << "Configarr #{label} reached fingerprint recording" if
        result.fetch("recorder_started")
    end
  end
end

{
  "clean first opaque baseline" => nil,
  "repairable source qdef drift before first opaque baseline" => lambda do |state|
    state.dig("configarr", "radarr", "qualitydefinition").first["minSize"] += 1
  end
}.each do |label, mutate|
  baseline_state = deep_copy(configarr_state)
  mutate&.call(baseline_state)
  Dir.mktmpdir("media-acquisition-configarr-first-opaque-") do |runtime|
    FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
    with_api(baseline_state) do |api|
      variables = base_variables(api.port)
      seed_fingerprint_baseline(runtime, variables, kind: :configarr, state: baseline_state)
      File.unlink(File.join(runtime, "services", "arr", CONFIGARR_OPAQUE_FINGERPRINT_FILE))
      result = run_tasks(
        :configarr, api, {}, runtime: runtime, prepare_fingerprints: false
      )
      sane = check_sanity(failures, "Configarr #{label}", result, api, kind: :configarr)
      next unless sane

      failures << "Configarr #{label} failed" unless result.fetch("status").success?
      failures << "Configarr #{label} did not run exactly one job" unless
        mutation_requests(api, configarr_write).length == 1
      failures << "Configarr #{label} did not converge" unless
        configarr_projection(api.state.fetch("configarr")) == configarr_projection(CONFIGARR)
      opaque_file = result.fetch("fingerprints").fetch(CONFIGARR_OPAQUE_FINGERPRINT_FILE, {})
      failures << "Configarr #{label} did not record opaque continuity" unless
        opaque_file["content"] == "#{configarr_opaque_fingerprint(CONFIGARR)}\n"
    end
  end
end

exercise_stable(
  failures, relationship: "Configarr", kind: :configarr,
  state: configarr_state, write_matcher: configarr_any_write,
  projection: method(:configarr_projection), desired: CONFIGARR,
  current: configarr_current, preserved: configarr_unmanaged_preserved
)
reordered_definition_state = deep_copy(configarr_state)
%w[radarr sonarr].each do |service|
  reordered_definition_state.dig("configarr", service, "qualitydefinition").reverse!
end
exercise_stable(
  failures, relationship: "Configarr quality-definition API ordering", kind: :configarr,
  state: reordered_definition_state, write_matcher: configarr_any_write,
  projection: method(:configarr_projection), desired: CONFIGARR,
  current: configarr_current
)
configarr_secret_variables = {}
exercise_secret_change(
  failures, relationship: "Configarr", kind: :configarr,
  state: configarr_state, field: "API key input fingerprint",
  variables: configarr_secret_variables,
  old_variables: {
    "vault_arr_radarr_api_key" => "private-stale-radarr-apikey",
    "vault_arr_sonarr_api_key" => "private-stale-sonarr-apikey"
  }, write_matcher: configarr_any_write,
  projection: method(:configarr_projection), desired: CONFIGARR, current: configarr_current,
  expected_fingerprint_kinds: %i[configarr bazarr]
)
%w[radarr sonarr].each do |service|
  {
    "quality profile" => ["qualityprofile", 900],
    "custom format" => ["customformat", 901]
  }.each do |identity, (resource, duplicate_id)|
    duplicate_state = deep_copy(configarr_state)
    duplicate_state.dig("configarr", service, resource) <<
      deep_copy(CONFIGARR.dig(service, resource).first).merge("id" => duplicate_id)
    exercise_duplicate(
      failures, relationship: "Configarr #{service} #{identity}", kind: :configarr,
      state: duplicate_state, variables: {}, write_matcher: configarr_any_write
    )
  end
  duplicate_definition_state = deep_copy(configarr_state)
  duplicate_definition_state.dig("configarr", service, "qualitydefinition") <<
    deep_copy(CONFIGARR.dig(service, "qualitydefinition").first)
  exercise_duplicate(
    failures, relationship: "Configarr #{service} quality definition", kind: :configarr,
    state: duplicate_definition_state, variables: {}, write_matcher: configarr_any_write
  )

  duplicate_score_state = deep_copy(configarr_state)
  profile = duplicate_score_state.dig("configarr", service, "qualityprofile").first
  profile.fetch("formatItems") << deep_copy(profile.fetch("formatItems").first)
  exercise_duplicate(
    failures, relationship: "Configarr #{service} format-score assignment", kind: :configarr,
    state: duplicate_score_state, variables: {}, write_matcher: configarr_any_write
  )

  duplicate_score_id_state = deep_copy(configarr_state)
  score_items = duplicate_score_id_state.dig(
    "configarr", service, "qualityprofile", 0, "formatItems"
  )
  score_items.last["format"] = score_items.first.fetch("format")
  other_service = service == "radarr" ? "sonarr" : "radarr"
  duplicate_score_id_state.dig("configarr", other_service, "customformat").reject! do |format|
    format["name"] == CONFIGARR_FORMAT_NAME
  end
  exercise_duplicate(
    failures,
    relationship: "Configarr #{service} format-score numeric identity",
    kind: :configarr,
    state: duplicate_score_id_state,
    variables: {},
    write_matcher: configarr_any_write
  )

  {
    "quality-profile numeric identity" => ["qualityprofile", 0, 1, "id"],
    "custom-format numeric identity" => ["customformat", 0, 1, "id"],
    "quality-definition numeric identity" => ["qualitydefinition", 0, -1, "id"]
  }.each do |identity, (resource, source_index, target_index, field)|
    duplicate_numeric_state = deep_copy(configarr_state)
    collection = duplicate_numeric_state.dig("configarr", service, resource)
    collection.fetch(target_index)[field] = collection.fetch(source_index).fetch(field)
    other_service = service == "radarr" ? "sonarr" : "radarr"
    duplicate_numeric_state.dig("configarr", other_service, "customformat").reject! do |format|
      format["name"] == CONFIGARR_FORMAT_NAME
    end
    duplicate_numeric_state.dig(
      "configarr", other_service, "qualityprofile", 0, "formatItems"
    ).reject! do |assignment|
      assignment["name"] == CONFIGARR_FORMAT_NAME
    end
    exercise_duplicate(
      failures,
      relationship: "Configarr #{service} #{identity}",
      kind: :configarr,
      state: duplicate_numeric_state,
      variables: {},
      write_matcher: configarr_any_write
    )
  end
  duplicate_quality_id_state = deep_copy(configarr_state)
  definitions = duplicate_quality_id_state.dig(
    "configarr", service, "qualitydefinition"
  )
  definitions.last.fetch("quality")["id"] = definitions.first.dig("quality", "id")
  other_service = service == "radarr" ? "sonarr" : "radarr"
  duplicate_quality_id_state.dig("configarr", other_service, "customformat").reject! do |format|
    format["name"] == CONFIGARR_FORMAT_NAME
  end
  exercise_duplicate(
    failures,
    relationship: "Configarr #{service} quality-definition quality numeric identity",
    kind: :configarr,
    state: duplicate_quality_id_state,
    variables: {},
    write_matcher: configarr_any_write
  )
end

{
  "HTTP failure" => { fail_custom_format_service: "radarr" },
  "malformed duplicate numeric identity" => { malformed_custom_format_service: "radarr" }
}.each do |label, api_options|
  missing_state = deep_copy(configarr_state)
  missing_state.dig("configarr", "radarr", "customformat").reject! do |format|
    format["name"] == CONFIGARR_FORMAT_NAME
  end
  missing_state.dig("configarr", "radarr", "qualityprofile").first
    .fetch("formatItems").reject! { |item| item["name"] == CONFIGARR_FORMAT_NAME }
  Dir.mktmpdir("media-acquisition-configarr-create-failure-") do |runtime|
    FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
    with_api(missing_state, **api_options) do |api|
      variables = base_variables(api.port)
      seed_fingerprint_baseline(runtime, variables, kind: :configarr, state: missing_state)
      before = fingerprint_snapshot(runtime)
      result = run_tasks(
        :configarr, api, {}, runtime: runtime, prepare_fingerprints: false
      )
      sane = check_sanity(
        failures, "Configarr absent custom format #{label}", result, api,
        kind: :configarr
      )
      next unless sane

      failures << "Configarr absent custom format #{label} was accepted" if
        result.fetch("status").success?
      creates = mutation_requests(api, lambda do |request|
        request["method"] == "POST" &&
          request["target"] == "/radarr/api/v3/customformat"
      end)
      failures << "Configarr absent custom format #{label} did not attempt one exact create" unless
        creates.length == 1
      failures << "Configarr absent custom format #{label} reached the job" unless
        mutation_requests(api, configarr_write).empty?
      failures << "Configarr absent custom format #{label} advanced reconciliation hashes" unless
        fingerprint_snapshot(runtime) == before
      failures << "Configarr absent custom format #{label} reached fingerprint recording" if
        result.fetch("recorder_started")
    end
  end
end

{
  "quality-profile collection" => lambda do |state|
    state.dig("configarr", "radarr")["qualityprofile"] = {}
  end,
  "quality-definition object" => lambda do |state|
    state.dig("configarr", "sonarr", "qualitydefinition")[0] = "invalid"
  end,
  "custom-format collection" => lambda do |state|
    state.dig("configarr", "radarr")["customformat"] = nil
  end,
  "naming object" => lambda do |state|
    state.dig("configarr", "sonarr")["config/naming"] = []
  end,
  "quality item boolean" => lambda do |state|
    state.dig("configarr", "radarr", "qualityprofile", 0, "items", 0)["allowed"] = "false"
  end
}.each do |label, mutate|
  malformed_state = deep_copy(configarr_state)
  mutate.call(malformed_state)
  exercise_duplicate(
    failures, relationship: "Configarr malformed #{label}", kind: :configarr,
    state: malformed_state, variables: {}, write_matcher: configarr_any_write
  )
end

invalid_source_documents = {
  "unparseable pinned document" => "{\"qualities\":",
  "non-numeric pinned size" => JSON.generate(
    deep_copy(CONFIGARR_QUALITY_DEFINITION_DOCUMENTS.fetch("radarr")).tap do |document|
      document.fetch("qualities").first["min"] = true
    end
  )
}
invalid_source_documents.each do |label, invalid_source|
  Dir.mktmpdir("media-acquisition-configarr-source-") do |runtime|
    FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
    with_api(deep_copy(configarr_state)) do |api|
      variables = base_variables(api.port)
      seed_fingerprint_baseline(runtime, variables, kind: :configarr, state: configarr_state)
      before = fingerprint_snapshot(runtime)
      task_mutator = lambda do |tasks|
        source_task = tasks.find do |task|
          task["name"] == "Load pinned Configarr quality-definition source documents"
        end
        source_task.fetch("ansible.builtin.set_fact")
          .fetch("arr_configarr_quality_definition_sources")["radarr"] = invalid_source
      end
      result = run_tasks(
        :configarr, api, {}, runtime: runtime, prepare_fingerprints: false,
        task_mutator: task_mutator
      )
      sane = check_sanity(
        failures, "Configarr #{label}", result, api, kind: :configarr
      )
      next unless sane

      failures << "Configarr #{label} was accepted" if result.fetch("status").success?
      failures << "Configarr #{label} reached a mutation" unless
        mutation_requests(api, configarr_any_write).empty?
      failures << "Configarr #{label} changed reconciliation hashes" unless
        fingerprint_snapshot(runtime) == before
      failures << "Configarr #{label} reached fingerprint recording" if
        result.fetch("recorder_started")
    end
  end
end

%w[radarr sonarr].each do |service|
  empty_profile_state = deep_copy(configarr_state)
  empty_profile_state.dig("configarr", service)["qualityprofile"] = []
  exercise_duplicate(
    failures,
    relationship: "Configarr #{service} empty quality-profile collection",
    kind: :configarr,
    state: empty_profile_state,
    variables: {},
    write_matcher: configarr_any_write
  )

  expected_state = deep_copy(CONFIGARR)
  expected_state.dig(service, "customformat").select! do |format|
    format["name"] == CONFIGARR_FORMAT_NAME
  end
  expected_profile = expected_state.dig(service, "qualityprofile").find do |profile|
    profile["name"] == CONFIGARR_PROFILE_NAME
  end
  expected_profile.fetch("formatItems").select! do |assignment|
    assignment["name"] == CONFIGARR_FORMAT_NAME
  end
  bootstrap_state = {
    "configarr" => deep_copy(CONFIGARR),
    "configarr_desired" => expected_state
  }
  bootstrap_state.dig("configarr", service)["customformat"] = []
  bootstrap_profile = bootstrap_state.dig("configarr", service, "qualityprofile").find do |profile|
    profile["name"] == CONFIGARR_PROFILE_NAME
  end
  bootstrap_profile["formatItems"] = []
  with_api(bootstrap_state) do |api|
    result = run_tasks(:configarr, api, {}, prepare_fingerprints: false)
    sane = check_sanity(
      failures, "Configarr #{service} empty custom-format bootstrap", result, api,
      kind: :configarr
    )
    next unless sane

    failures << "Configarr #{service} empty custom-format bootstrap failed" unless
      result.fetch("status").success?
    writes = mutation_requests(api, configarr_any_write)
    expected_writes = [
      ["POST", "/#{service}/api/v3/customformat"],
      ["PUT", "/#{service}/api/v3/qualityprofile/#{101 + %w[radarr sonarr].index(service)}"],
      ["POST", "/_fixture/configarr/apply"]
    ]
    failures << "Configarr #{service} empty custom-format bootstrap write set differs" unless
      writes.map { |request| [request["method"], request["target"]] } == expected_writes
    create_index = api.requests.index do |request|
      request["method"] == "POST" &&
        request["target"] == "/#{service}/api/v3/customformat"
    end
    profile_put_index = api.requests.index do |request|
      request["method"] == "PUT" &&
        request["target"].start_with?("/#{service}/api/v3/qualityprofile/")
    end
    immediate_reads = api.requests.each_index.count do |index|
      request = api.requests[index]
      create_index && profile_put_index && index > create_index && index < profile_put_index &&
        request["method"] == "GET" && request["target"].match?(
          %r{\A/(radarr|sonarr)/api/v3/(qualityprofile|qualitydefinition|customformat|config/naming)\z}
        )
    end
    failures << "Configarr #{service} empty custom-format bootstrap skipped immediate reread" unless
      immediate_reads == 8
    created_format = api.state.dig("configarr", service, "customformat").find do |format|
      format["name"] == CONFIGARR_FORMAT_NAME
    end
    expected_state.dig(service, "customformat").first["id"] = created_format.fetch("id")
    expected_profile.fetch("formatItems").first["format"] = created_format.fetch("id")
    failures << "Configarr #{service} empty custom-format bootstrap did not converge" unless
      configarr_projection(api.state.fetch("configarr")) == configarr_projection(expected_state)
    unrelated_resources = %w[qualitydefinition config/naming]
    unrelated_resources.each do |resource|
      failures << "Configarr #{service} empty custom-format bootstrap changed #{resource}" unless
        api.state.dig("configarr", service, resource) == expected_state.dig(service, resource)
    end
    failures << "Configarr #{service} empty custom-format bootstrap did not record verified hashes" unless
      result.fetch("recorder_started")
  end
end

Dir.mktmpdir("media-acquisition-fingerprint-failure-") do |runtime|
  fingerprint_directory = File.join(runtime, "services", "arr")
  FileUtils.mkdir_p(fingerprint_directory)
  with_api(deep_copy(configarr_state), fail_configarr: true) do |api|
    stale_variables = base_variables(api.port).merge(
      "vault_arr_radarr_api_key" => "private-stale-radarr-apikey",
      "vault_arr_sonarr_api_key" => "private-stale-sonarr-apikey"
    )
    seed_fingerprint_baseline(
      runtime, stale_variables, kind: :configarr, state: configarr_state
    )
    before = fingerprint_snapshot(runtime)
    result = run_tasks(
      :configarr, api, configarr_secret_variables, runtime: runtime,
      prepare_fingerprints: false
    )
    sane = check_sanity(
      failures, "failed reconciliation fingerprint ordering", result, api, kind: :configarr
    )
    if sane
      failures << "failed reconciliation was accepted" if result.fetch("status").success?
      unless mutation_requests(api, configarr_write).length == 1
        failures << "failed reconciliation did not attempt exactly one applicable write"
      end
      after = fingerprint_snapshot(runtime)
      failures << "failed reconciliation advanced future fingerprint files" unless after == before
      failures << "failed reconciliation reached future fingerprint recording" if
        result.fetch("recorder_started")
    end
  end
end

partial_configarr_state = deep_copy(configarr_state)
partial_configarr_state.dig("configarr", "radarr", "qualitydefinition").first[
  "minSize"
] += 1
Dir.mktmpdir("media-acquisition-configarr-partial-") do |runtime|
  FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
  with_api(deep_copy(partial_configarr_state), partial_configarr: true) do |api|
    variables = base_variables(api.port)
    seed_fingerprint_baseline(
      runtime, variables, kind: :configarr, state: partial_configarr_state
    )
    before = fingerprint_snapshot(runtime)
    result = run_tasks(
      :configarr, api, configarr_secret_variables, runtime: runtime,
      prepare_fingerprints: false
    )
    sane = check_sanity(
      failures, "partial Configarr success without repair", result, api, kind: :configarr
    )
    if sane
      failures << "partial Configarr success without repair was accepted" if
        result.fetch("status").success?
      unless mutation_requests(api, configarr_write).length == 1
        failures << "partial Configarr success did not run exactly one job"
      end
      failures << "partial Configarr success advanced verified hashes" unless
        fingerprint_snapshot(runtime) == before
      failures << "partial Configarr success reached fingerprint recording" if
        result.fetch("recorder_started")
    end
  end
end

if fingerprint_tasks_available?
  fingerprint_safety_cases = [
    [:bazarr, provider_state, provider_variables, FINGERPRINT_FILE_BY_KIND.fetch(:bazarr)],
    [:configarr, configarr_state, configarr_secret_variables,
     FINGERPRINT_FILE_BY_KIND.fetch(:configarr)],
    [:configarr, configarr_state, configarr_secret_variables, CONFIGARR_STATE_FINGERPRINT_FILE],
    [:configarr, configarr_state, configarr_secret_variables, CONFIGARR_OPAQUE_FINGERPRINT_FILE]
  ]
  unless OPAQUE_TARGETED_ONLY
    fingerprint_safety_cases = [
      [:application, application_state, {}, FINGERPRINT_FILE_BY_KIND.fetch(:application)],
      [:download_client, client_state, {}, FINGERPRINT_FILE_BY_KIND.fetch(:download_client)],
      [:indexer, indexer_state, {}, FINGERPRINT_FILE_BY_KIND.fetch(:indexer)]
    ] + fingerprint_safety_cases
  end
  fingerprint_safety_cases.each do |kind, state, variables, filename|
    Dir.mktmpdir("media-acquisition-fingerprint-safety-") do |runtime|
      with_api(deep_copy(state)) do |api|
        baseline = run_tasks(kind, api, variables, runtime: runtime)
        sane = check_sanity(
          failures, "#{kind} fingerprint safety baseline", baseline, api, kind: kind
        )
        if sane && !baseline.fetch("status").success?
          failures << "#{kind} fingerprint safety baseline failed"
        end
        next unless sane && baseline.fetch("status").success?

        path = File.join(runtime, "services", "arr", filename)
        if kind == :application
          baseline_content = baseline.fetch("fingerprints").fetch(filename).fetch("content")
          File.write(path, "#{baseline_content}\n", mode: "w", perm: 0o600)
          before_content = fingerprint_snapshot(runtime)
          assert_unsafe_fingerprint_rejected(
            failures, "invalid-content fingerprint", kind, api, variables, runtime,
            before_content
          )
          File.write(path, baseline_content, mode: "w", perm: 0o600)
        end

        File.chmod(0o644, path)
        before_mode = fingerprint_snapshot(runtime)
        assert_unsafe_fingerprint_rejected(
          failures, "#{kind} unsafe-mode fingerprint", kind, api, variables, runtime,
          before_mode
        )

        File.chmod(0o600, path)
        File.unlink(path)
        symlink_target = File.join(runtime, "#{kind}-unsafe-target")
        File.write(symlink_target, "#{'f' * 64}\n", mode: "w", perm: 0o600)
        File.symlink(symlink_target, path)
        before_symlink = fingerprint_snapshot(runtime)
        target_before = File.binread(symlink_target)
        assert_unsafe_fingerprint_rejected(
          failures, "#{kind} symlink fingerprint", kind, api, variables, runtime,
          before_symlink
        )
        failures << "#{kind} symlink fingerprint modified its target" unless
          File.binread(symlink_target) == target_before
      end
    end
  end
end

abort failures.join("\n") unless failures.empty?
puts "media acquisition reconciliation behavior holds"
