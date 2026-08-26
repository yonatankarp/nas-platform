#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "digest"
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
PLAYBOOK_TIMEOUT_SECONDS = Float(ENV.fetch("ACQUISITION_PLAYBOOK_TIMEOUT", "30"))
PROCESS_TERM_GRACE_SECONDS = 1.0
SOCKET_DEADLINE_SECONDS = 2.0
SECRET_TASK_FILES = [
  [ARR_TASKS, "reconcile_prowlarr.yml"],
  [ARR_TASKS, "reconcile_prowlarr_application.yml"],
  [ARR_TASKS, "reconcile_servarr_download_client.yml"],
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
  .prowlarr-applications-input.sha256
  .servarr-sabnzbd-input.sha256
  .prowlarr-indexers-input.sha256
  .bazarr-providers-input.sha256
].freeze
FINGERPRINT_FILE_BY_KIND = {
  application: ".prowlarr-applications-input.sha256",
  download_client: ".servarr-sabnzbd-input.sha256",
  indexer: ".prowlarr-indexers-input.sha256",
  bazarr: ".bazarr-providers-input.sha256",
  configarr: ".configarr-input.sha256"
}.freeze
FINGERPRINT_KIND_BY_FILE = FINGERPRINT_FILE_BY_KIND.invert.freeze
FINGERPRINT_INPUT_BY_KIND = {
  application: "prowlarr_applications",
  download_client: "servarr_sabnzbd",
  indexer: "prowlarr_indexers",
  bazarr: "bazarr_providers",
  configarr: "configarr"
}.freeze
FINGERPRINT_BASELINE_CACHE = { "enabled" => false }
CONFIGARR_IMAGE = "ghcr.io/raydak-labs/configarr:1.28.0@sha256:" \
                  "008d8659ff35f63fbcc20b860b33ba7cc49e8d7458a6ec446810ec4d783ef017"

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
  "fixture-radarr-admin-password", "fixture-sonarr-admin-password"
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
    "settings-opensubtitlescom-use_tag_search" => "true",
    "settings-opensubtitlescom-hearing_impaired" => "false"
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
    "use_tag_search" => true,
    "hearing_impaired" => false
  }
end.freeze

configarr_yaml = File.read(CONFIGARR_SOURCE).gsub(/!secret\s+[A-Z_]+/, '"fixture-secret-reference"')
CONFIGARR_POLICY = YAML.safe_load(configarr_yaml, aliases: false).freeze
CONFIGARR_CUSTOM_FORMAT = CONFIGARR_POLICY.fetch("customFormatDefinitions").fetch(0)
CONFIGARR_PROFILE_NAME = "HD Bluray + WEB 1080p"
CONFIGARR_FORMAT_NAME = CONFIGARR_CUSTOM_FORMAT.fetch("name")

quality_items = lambda do |profile|
  profile.fetch("qualities").map do |quality|
    if quality.key?("qualities")
      {
        "name" => quality.fetch("name"), "allowed" => true,
        "items" => quality.fetch("qualities").map do |name|
          { "quality" => { "name" => name }, "allowed" => true }
        end
      }
    else
      { "quality" => { "name" => quality.fetch("name") }, "allowed" => true }
    end
  end
end

quality_definitions = [
  { "quality" => { "name" => "Bluray-1080p" }, "title" => "Bluray-1080p",
    "weight" => 1, "minSize" => 0, "preferredSize" => 50, "maxSize" => 100 },
  { "quality" => { "name" => "WEBDL-1080p" }, "title" => "WEBDL-1080p",
    "weight" => 2, "minSize" => 0, "preferredSize" => 45, "maxSize" => 90 }
].freeze

CONFIGARR = %w[radarr sonarr].each_with_index.to_h do |service, index|
  policy = CONFIGARR_POLICY.fetch(service).fetch("phase1")
  profile = policy.fetch("quality_profiles").find do |candidate|
    candidate.fetch("name") == CONFIGARR_PROFILE_NAME
  end
  format_assignment = policy.fetch("custom_formats").fetch(0)
  score = format_assignment.fetch("assign_scores_to").find do |assignment|
    assignment.fetch("name") == CONFIGARR_PROFILE_NAME
  end.fetch("score")
  media_naming = policy.fetch("media_naming")
  naming = if service == "radarr"
             {
               "id" => 301, "renameMovies" => media_naming.dig("movie", "rename"),
               "standardMovieFormat" => media_naming.dig("movie", "standard"),
               "movieFolderFormat" => media_naming.fetch("folder")
             }
           else
             {
               "id" => 302, "renameEpisodes" => media_naming.dig("episodes", "rename"),
               "standardEpisodeFormat" => media_naming.dig("episodes", "standard"),
               "dailyEpisodeFormat" => media_naming.dig("episodes", "daily"),
               "animeEpisodeFormat" => media_naming.dig("episodes", "anime"),
               "seriesFolderFormat" => media_naming.fetch("series"),
               "seasonFolderFormat" => media_naming.fetch("season")
             }
           end
  specification = CONFIGARR_CUSTOM_FORMAT.fetch("specifications").fetch(0)
  [service, {
    "qualityprofile" => [{
      "id" => 101 + index, "name" => profile.fetch("name"),
      "upgradeAllowed" => profile.dig("upgrade", "allowed"),
      "minFormatScore" => profile.fetch("min_format_score"),
      "resetUnmatchedScores" => profile.dig("reset_unmatched_scores", "enabled"),
      "qualitySort" => profile.fetch("quality_sort"),
      "items" => quality_items.call(profile),
      "formatItems" => [{ "name" => CONFIGARR_FORMAT_NAME, "score" => score }]
    }],
    "qualitydefinition" => Marshal.load(Marshal.dump(quality_definitions)),
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

def reconciliation_tasks(kind)
  case kind
  when :application
    tasks = task_slice(
      "reconcile_prowlarr.yml", "Read Prowlarr applications",
      "Reconcile each Prowlarr full-sync application"
    )
    include_task = tasks.find do |task|
      task["name"] == "Reconcile each Prowlarr full-sync application"
    end
    include_task["ansible.builtin.include_tasks"] = File.join(
      ARR_TASKS, "reconcile_prowlarr_application.yml"
    )
    tasks
  when :indexer
    task_slice(
      "reconcile_prowlarr.yml", "Validate operator-owned Prowlarr indexer declarations",
      "Refuse duplicate Prowlarr indexer names"
    )
  when :download_client
    task_slice(
      "reconcile_servarr_download_client.yml", "Read Servarr download clients",
      "Reconcile the owned Servarr SABnzbd client"
    )
  when :bazarr
    task_slice(
      "reconcile_bazarr.yml", "Validate operator-owned Bazarr declarations",
      "Reconcile operator-owned Bazarr provider settings"
    )
  when :configarr
    task_slice(
      "configarr.yml", "Apply Configarr profiles synchronously",
      "Verify Configarr-owned profiles, definitions, formats, and naming"
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
  when :download_client
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
      "Verify Servarr authentication, roots, rename, and SABnzbd"
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

def verification_success_tasks
  tasks = YAML.safe_load_file(File.join(ARR_TASKS, "verify.yml"), aliases: true)
  return [] unless tasks.last&.fetch("name", nil) == VERIFICATION_GATE_SUCCESS_TASK_NAME

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
  unless tasks.first&.fetch("name", nil) == "Record verified Arr desired-input fingerprints"
    raise "verified Arr fingerprint recording boundary is unavailable"
  end

  deep_copy(tasks)
end

def selected_tasks(kind)
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
    [field.fetch("name"), fields[field.fetch("name")]]
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

def quality_definition_projection(definition)
  {
    "quality" => definition.dig("quality", "name"), "title" => definition["title"],
    "weight" => definition["weight"], "minSize" => definition["minSize"],
    "preferredSize" => definition["preferredSize"], "maxSize" => definition["maxSize"]
  }
end

def configarr_projection(settings)
  %w[radarr sonarr].to_h do |service|
    resources = settings.fetch(service)
    profiles = resources.fetch("qualityprofile")
    profile_matches = profiles.select { |profile| profile["name"] == CONFIGARR_PROFILE_NAME }
    profile = profile_matches.length == 1 ? profile_matches.first : profiles.first
    formats = resources.fetch("customformat")
    format_matches = formats.select { |format| format["name"] == CONFIGARR_FORMAT_NAME }
    custom_format = format_matches.length == 1 ? format_matches.first : formats.first
    specification = Array(custom_format&.fetch("specifications", nil)).first || {}
    specification_fields = fields_hash(specification)
    format_items = Array(profile&.fetch("formatItems", nil))
    score_matches = format_items.select do |format_item|
      format_item["name"] == CONFIGARR_FORMAT_NAME
    end
    format_item = score_matches.length == 1 ? score_matches.first : format_items.first
    naming_fields = service == "radarr" ?
      %w[renameMovies standardMovieFormat movieFolderFormat] :
      %w[renameEpisodes standardEpisodeFormat dailyEpisodeFormat animeEpisodeFormat
         seriesFolderFormat seasonFolderFormat]
    [service, {
      "quality_profile_identity_count" => profile_matches.length,
      "quality_profile" => {
        "name" => profile&.fetch("name", nil),
        "upgradeAllowed" => profile&.fetch("upgradeAllowed", nil),
        "minFormatScore" => profile&.fetch("minFormatScore", nil),
        "resetUnmatchedScores" => profile&.fetch("resetUnmatchedScores", nil),
        "qualitySort" => profile&.fetch("qualitySort", nil),
        "items" => Array(profile&.fetch("items", nil)).map do |item|
          quality_item_projection(item)
        end,
        "format_assignment" => {
          "identity_count" => score_matches.length,
          "name" => format_item&.fetch("name", nil),
          "score" => format_item&.fetch("score", nil)
        }
      },
      "quality_definitions" => resources.fetch("qualitydefinition")
        .map { |definition| quality_definition_projection(definition) }
        .sort_by { |definition| definition.fetch("quality").to_s },
      "custom_format_identity_count" => format_matches.length,
      "custom_format" => {
        "name" => custom_format&.fetch("name", nil),
        "includeCustomFormatWhenRenaming" =>
          custom_format&.fetch("includeCustomFormatWhenRenaming", nil),
        "specification" => {
          "name" => specification["name"], "implementation" => specification["implementation"],
          "negate" => specification["negate"], "required" => specification["required"],
          "regex" => specification_fields["value"]
        }
      },
      "naming" => resources.fetch("config/naming").slice(*naming_fields)
    }]
  end
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

  def initialize(state, fail_configarr: false)
    @state = state
    @fail_configarr = fail_configarr
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
    when ["POST", "/api/system/settings"]
      request["form"] = URI.decode_www_form(body)
      apply_bazarr(request.fetch("form"))
      send_empty(client, 204)
    when ["POST", "/_fixture/configarr/apply"]
      if @fail_configarr
        send_json(client, 500, { "error" => "fixture Configarr failure" })
      else
        @state["configarr"] = deep_copy(@state.fetch("configarr_desired"))
        send_empty(client, 204)
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
    copy.dig("auth")["password"] = "********"
    copy.dig("radarr")["apikey"] = "********"
    copy.dig("sonarr")["apikey"] = "********"
    copy.fetch("providers", {}).each_value do |settings|
      settings.each_key do |name|
        settings[name] = "********" if name.match?(/(?:api.?key|password|token|secret)/i)
      end
    end
    copy
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
    @state.fetch("bazarr").fetch("providers")[name] = values.to_h do |key, value|
      setting = key.delete_prefix(prefix)
      normalized = %w[use_tag_search hearing_impaired].include?(setting) ? boolean(value) : value
      [setting, normalized]
    end
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

def base_variables(port)
  variables = {
    "arr_prowlarr_api" => "http://127.0.0.1:#{port}/api/v1",
    "arr_prowlarr_internal_url" => "http://prowlarr:9696",
    "arr_prowlarr_application_sync_level" => "fullSync",
    "arr_prowlarr_applications" => [
      deep_copy(APPLICATION_DECLARATION), deep_copy(SONARR_APPLICATION_DECLARATION)
    ],
    "vault_arr_prowlarr_api_key" => "fixture-prowlarr-control-key",
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
    "bazarr_providers" => variables.fetch("media_bazarr_providers"),
    "configarr" => {
      # Ansible's file lookup strips trailing whitespace by default.
      "config" => File.read(CONFIGARR_SOURCE).rstrip,
      "radarr_api_key" => variables.fetch("vault_arr_radarr_api_key"),
      "sonarr_api_key" => variables.fetch("vault_arr_sonarr_api_key"),
      "image" => CONFIGARR_IMAGE
    }
  }.transform_values { |value| Digest::SHA256.hexdigest(ansible_json(value)) }
end

def seed_fingerprint_baseline(runtime, variables)
  directory = File.join(runtime, "services", "arr")
  desired = desired_fingerprint_values(variables)
  FINGERPRINT_FILE_BY_KIND.each do |kind, filename|
    File.write(
      File.join(directory, filename), "#{desired.fetch(FINGERPRINT_INPUT_BY_KIND.fetch(kind))}\n",
      mode: "w", perm: 0o600
    )
  end
end

def reconciliation_phase(result)
  events = result.fetch("task_events")
  recorder_task = fingerprint_tasks_available? ? fingerprint_record_tasks.first.fetch("name") : nil
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
      seed_fingerprint_baseline(runtime, variables)
    end
    fingerprints_before_play = fingerprint_snapshot(runtime)
    playbook = File.join(directory, "playbook.yml")
    tasks = selected_tasks(kind)
    task_mutator&.call(tasks)
    write_playbook(playbook, variables, tasks)
    result = reconciliation_phase(run_playbook(playbook, env))
    fingerprints_after_play = fingerprint_snapshot(runtime)
    result.merge(
      "fingerprints" => fingerprints_after_play,
      "expected_fingerprints" => desired_fingerprint_values(variables),
      "fingerprint_changes" => fingerprint_change_count(
        fingerprints_before_play, fingerprints_after_play
      )
    )
  end
end

def with_api(state, fail_configarr: false)
  api = AcquisitionApi.new(state, fail_configarr: fail_configarr)
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
  when :bazarr
    get_targets.count("/api/system/settings") >= 2
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
                       write_matcher:, projection:, desired:, current:)
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
        unless result.fetch("fingerprint_changes").zero?
          failures << "#{relationship} non-secret field #{field} rewrote a desired-input fingerprint"
        end
      end
      actual = current.call(api.state)
      unless projection.call(actual) == projection.call(desired)
        failures << "#{relationship} full owned projection did not converge after #{field} mutant"
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
    if preserved && !preserved.call(api.state)
      failures << "#{relationship} stable reconciliation modified unmanaged state"
    end
  end
end

def exercise_secret_change(failures, relationship:, kind:, state:, field:, variables:,
                           old_variables:, write_matcher:, projection:, desired:, current:,
                           fingerprint_transition: true, expected_changed: 1,
                           expected_writes: 1, safe_request_body: nil,
                           write_set_validator: nil)
  with_api(deep_copy(state)) do |api|
    old_fingerprint = nil
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
      old_fingerprint = baseline.fetch("fingerprints").fetch(FINGERPRINT_FILE_BY_KIND.fetch(kind))
      old_expected = baseline.fetch("expected_fingerprints").fetch(
        FINGERPRINT_INPUT_BY_KIND.fetch(kind)
      )
      old_recorded = old_fingerprint && old_fingerprint.fetch("type") == "regular" &&
        old_fingerprint.fetch("mode") == 0o600 &&
        old_fingerprint.fetch("content") == "#{old_expected}\n" &&
        old_fingerprint.fetch("content").match?(/\A[0-9a-f]{64}\n\z/)
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
      unless result.fetch("fingerprint_changes") == 1
        failures << "#{relationship} masked secret #{field} recorded an unexpected fingerprint set"
      end
      fingerprint = result.fetch("fingerprints").fetch(FINGERPRINT_FILE_BY_KIND.fetch(kind))
      expected = result.fetch("expected_fingerprints").fetch(
        FINGERPRINT_INPUT_BY_KIND.fetch(kind)
      )
      recorded = fingerprint && fingerprint.fetch("type") == "regular" &&
        fingerprint.fetch("mode") == 0o600 &&
        fingerprint.fetch("uid") == Process.uid && fingerprint.fetch("gid") == Process.gid &&
        fingerprint.fetch("content") == "#{expected}\n" &&
        fingerprint.fetch("content").match?(/\A[0-9a-f]{64}\n\z/) &&
        fingerprint.fetch("content") != old_fingerprint&.fetch("content")
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
  check_fingerprint_loader_contract(
    failures, File.basename(fingerprint_loader),
    YAML.safe_load_file(fingerprint_loader, aliases: true)
  )
end
if File.file?(fingerprint_recorder)
  check_fingerprint_record_contract(
    failures, File.basename(fingerprint_recorder),
    YAML.safe_load_file(fingerprint_recorder, aliases: true)
  )
end
check_verification_gate_contract(
  failures,
  YAML.safe_load_file(File.join(ARR_TASKS, "main.yml"), aliases: true),
  YAML.safe_load_file(File.join(ARR_TASKS, "verify.yml"), aliases: true)
)

application_state = {
  "applications" => [
    deep_copy(APPLICATION), deep_copy(SONARR_APPLICATION),
    { "id" => 12, "name" => "Unmanaged", "fields" => [], "tags" => [] }
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
      valid = FINGERPRINT_FILE_BY_KIND.all? do |kind, filename|
        entry = result.fetch("fingerprints").fetch(filename)
        entry && entry.fetch("type") == "regular" && entry.fetch("mode") == 0o600 &&
          entry.fetch("uid") == Process.uid && entry.fetch("gid") == Process.gid &&
          entry.fetch("content") ==
            "#{expected.fetch(FINGERPRINT_INPUT_BY_KIND.fetch(kind))}\n"
      end
      failures << "dedicated loader/recorder did not create exact private owned fingerprints" unless valid
    end
  end
  # The dedicated production probe above establishes the algorithm. The matrix
  # can seed equivalent private baselines without running another setup playbook
  # before every scenario.
  FINGERPRINT_BASELINE_CACHE["enabled"] = true
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

Dir.mktmpdir("media-acquisition-fingerprint-oversized-") do |runtime|
  FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
  with_api(deep_copy(application_state)) do |api|
    variables = base_variables(api.port)
    seed_fingerprint_baseline(runtime, variables)
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
    seed_fingerprint_baseline(runtime, variables)
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

if ENV["ACQUISITION_FINGERPRINT_TARGETED_ONLY"] == "1"
  abort failures.join("\n") unless failures.empty?
  puts "media acquisition fingerprint safety behavior holds"
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
  "fields.syncCategories" => ->(state) { set_field!(state.fetch("applications").first, "syncCategories", [9999]) }
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

bazarr_state = { "bazarr" => deep_copy(BAZARR) }
bazarr_mutations = {
  "auth.type" => ->(state) { state.dig("bazarr", "auth")["type"] = "basic" },
  "auth.username" => ->(state) { state.dig("bazarr", "auth")["username"] = "legacy" },
  "general.use_radarr" => ->(state) { state.dig("bazarr", "general")["use_radarr"] = false },
  "general.use_sonarr" => ->(state) { state.dig("bazarr", "general")["use_sonarr"] = false },
  "radarr.ip" => ->(state) { state.dig("bazarr", "radarr")["ip"] = "legacy-radarr" },
  "radarr.port" => ->(state) { state.dig("bazarr", "radarr")["port"] = "9999" },
  "radarr.base_url" => ->(state) { state.dig("bazarr", "radarr")["base_url"] = "/legacy" },
  "radarr.ssl" => ->(state) { state.dig("bazarr", "radarr")["ssl"] = true },
  "sonarr.ip" => ->(state) { state.dig("bazarr", "sonarr")["ip"] = "legacy-sonarr" },
  "sonarr.port" => ->(state) { state.dig("bazarr", "sonarr")["port"] = "9999" },
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
    fingerprint_transition: false, expected_changed: 0,
    safe_request_body: ->(request) { canonical_bazarr_connection_body?(request, []) }
  )
end

provider_state = { "bazarr" => deep_copy(BAZARR_WITH_PROVIDER) }
provider_variables = { "media_bazarr_providers" => [deep_copy(BAZARR_PROVIDER)] }
provider_mutations = {
  "provider.username" => ->(state) { state.dig("bazarr", "providers", "opensubtitlescom")["username"] = "legacy" },
  "provider.use_tag_search" => lambda do |state|
    state.dig("bazarr", "providers", "opensubtitlescom")["use_tag_search"] = false
  end,
  "provider.hearing_impaired" => lambda do |state|
    state.dig("bazarr", "providers", "opensubtitlescom")["hearing_impaired"] = true
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
provider_secret_state = deep_copy(provider_state)
provider_secret_state.dig("bazarr", "providers", "opensubtitlescom")["password"] = "private-stale-provider-secret"
old_provider = deep_copy(BAZARR_PROVIDER)
old_provider.fetch("settings")["settings-opensubtitlescom-password"] = "private-stale-provider-secret"
exercise_secret_change(
  failures, relationship: "Bazarr provider", kind: :bazarr,
  state: provider_secret_state, field: "provider.password",
  variables: provider_variables,
  old_variables: { "media_bazarr_providers" => [old_provider] },
  write_matcher: provider_write, projection: provider_projection,
  desired: BAZARR_WITH_PROVIDER, current: bazarr_current,
  safe_request_body: ->(request) { canonical_bazarr_provider_body?(request) }
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
  preserved: lambda do |state|
    settings = state.fetch("bazarr")
    settings.dig("providers", "unmanaged-provider") == {
      "username" => "unmanaged-user", "unmanaged_option" => "preserve-unmanaged-provider"
    } &&
      settings.dig("providers", BAZARR_PROVIDER.fetch("name"), "unmanaged_option") ==
        "preserve-declared-provider-extra" &&
      settings.dig("general", "enabled_providers").include?("unmanaged-provider")
  end
)
exercise_duplicate(
  failures, relationship: "Bazarr language declaration", kind: :bazarr,
  state: bazarr_state, variables: { "media_bazarr_languages" => %w[en en] },
  write_matcher: ->(request) { request["target"] == "/api/system/settings" }
)

configarr_state = { "configarr" => deep_copy(CONFIGARR), "configarr_desired" => deep_copy(CONFIGARR) }
configarr_mutations = {}
%w[radarr sonarr].each do |service|
  service_name = service.dup
  profile_mutations = {
    "name" => ->(profile) { profile["name"] = "Legacy Profile" },
    "upgradeAllowed" => ->(profile) { profile["upgradeAllowed"] = true },
    "minFormatScore" => ->(profile) { profile["minFormatScore"] = 100 },
    "resetUnmatchedScores" => ->(profile) { profile["resetUnmatchedScores"] = false },
    "qualitySort" => ->(profile) { profile["qualitySort"] = "bottom" },
    "quality order" => ->(profile) { profile["items"].reverse! },
    "quality structure" => ->(profile) { profile["items"].last["items"].pop },
    "format assignment name" => ->(profile) { profile["formatItems"].first["name"] = "Legacy Format" },
    "format assignment score" => ->(profile) { profile["formatItems"].first["score"] = 0 }
  }
  profile_mutations.each do |field, mutate_profile|
    configarr_mutations["#{service_name}.quality_profile.#{field}"] = lambda do |state|
      mutate_profile.call(state.dig("configarr", service_name, "qualityprofile").first)
    end
  end
  [
    ["Bluray-1080p", 0], ["WEB 1080p", 1],
    ["WEBDL-1080p", 1, 0], ["WEBRip-1080p", 1, 1]
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
      item["allowed"] = false
    end
  end

  CONFIGARR.dig(service_name, "qualitydefinition").each_with_index do |definition, index|
    quality_name = definition.dig("quality", "name")
    {
      "quality" => ->(item) { item.fetch("quality")["name"] = "Legacy Quality" },
      "title" => ->(item) { item["title"] = "Legacy Title" },
      "weight" => ->(item) { item["weight"] += 100 },
      "minSize" => ->(item) { item["minSize"] += 1 },
      "preferredSize" => ->(item) { item["preferredSize"] += 1 },
      "maxSize" => ->(item) { item["maxSize"] += 1 }
    }.each do |field, mutate_definition|
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
configarr_write = lambda do |request|
  request["method"] == "POST" && request["target"] == "/_fixture/configarr/apply"
end
configarr_current = ->(state) { state.fetch("configarr") }
exercise_mutations(
  failures, relationship: "Configarr", kind: :configarr,
  baseline: configarr_state, mutations: configarr_mutations,
  write_matcher: configarr_write, projection: method(:configarr_projection),
  desired: CONFIGARR, current: configarr_current
)
exercise_stable(
  failures, relationship: "Configarr", kind: :configarr,
  state: configarr_state, write_matcher: configarr_write,
  projection: method(:configarr_projection), desired: CONFIGARR,
  current: configarr_current
)
reordered_definition_state = deep_copy(configarr_state)
%w[radarr sonarr].each do |service|
  reordered_definition_state.dig("configarr", service, "qualitydefinition").reverse!
end
exercise_stable(
  failures, relationship: "Configarr quality-definition API ordering", kind: :configarr,
  state: reordered_definition_state, write_matcher: configarr_write,
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
  }, write_matcher: configarr_write,
  projection: method(:configarr_projection), desired: CONFIGARR, current: configarr_current
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
      state: duplicate_state, variables: {}, write_matcher: configarr_write
    )
  end
  duplicate_definition_state = deep_copy(configarr_state)
  duplicate_definition_state.dig("configarr", service, "qualitydefinition") <<
    deep_copy(CONFIGARR.dig(service, "qualitydefinition").first)
  exercise_duplicate(
    failures, relationship: "Configarr #{service} quality definition", kind: :configarr,
    state: duplicate_definition_state, variables: {}, write_matcher: configarr_write
  )

  duplicate_score_state = deep_copy(configarr_state)
  profile = duplicate_score_state.dig("configarr", service, "qualityprofile").first
  profile.fetch("formatItems") << deep_copy(profile.fetch("formatItems").first)
  exercise_duplicate(
    failures, relationship: "Configarr #{service} format-score assignment", kind: :configarr,
    state: duplicate_score_state, variables: {}, write_matcher: configarr_write
  )
end

Dir.mktmpdir("media-acquisition-fingerprint-failure-") do |runtime|
  fingerprint_directory = File.join(runtime, "services", "arr")
  FileUtils.mkdir_p(fingerprint_directory)
  FINGERPRINT_FILES.each do |filename|
    path = File.join(fingerprint_directory, filename)
    File.write(path, "#{'0' * 64}\n", mode: "w", perm: 0o600)
  end
  before = fingerprint_snapshot(runtime)
  with_api(deep_copy(configarr_state), fail_configarr: true) do |api|
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

if fingerprint_tasks_available?
  fingerprint_safety_cases = {
    application: [application_state, {}],
    download_client: [client_state, {}],
    indexer: [indexer_state, {}],
    bazarr: [provider_state, provider_variables],
    configarr: [configarr_state, configarr_secret_variables]
  }
  fingerprint_safety_cases.each do |kind, (state, variables)|
    filename = FINGERPRINT_FILE_BY_KIND.fetch(kind)
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
