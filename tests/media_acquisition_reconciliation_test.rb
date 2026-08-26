#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "socket"
require "tmpdir"
require "uri"
require "yaml"

ROOT = File.expand_path("..", __dir__)
ANSIBLE_PLAYBOOK = File.expand_path("../../.venv/bin/ansible-playbook", ROOT)
ARR_TASKS = File.join(ROOT, "roles", "arr", "tasks")

FINGERPRINT_FILES = %w[
  .configarr-input.sha256
  .prowlarr-applications-input.sha256
  .servarr-sabnzbd-input.sha256
  .prowlarr-indexers-input.sha256
  .bazarr-providers-input.sha256
].freeze

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
  "private-stale-radarr-apikey", "private-stale-sonarr-apikey"
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
  "api_key" => SECRETS.fetch("radarr")
}.freeze
SONARR_INSTANCE = {
  "name" => "sonarr", "category" => "series", "tags" => [6, 2],
  "api_key" => SECRETS.fetch("sonarr")
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

RADARR_MOVIE_FORMAT = "{Movie CleanTitle} ({Release Year}) {tmdb-{TmdbId}} [{Quality Full}]"
SONARR_EPISODE_FORMAT = "{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle}"
CONFIGARR = {
  "radarr" => {
    "qualityprofile" => [{
      "id" => 101, "name" => "HD Bluray + WEB 1080p", "upgradeAllowed" => false,
      "minFormatScore" => 0,
      "items" => [
        { "quality" => { "name" => "Bluray-1080p" }, "allowed" => true },
        { "name" => "WEB 1080p", "allowed" => true,
          "items" => %w[WEBDL-1080p WEBRip-1080p].map do |name|
            { "quality" => { "name" => name }, "allowed" => true }
          end }
      ],
      "formatItems" => [{ "name" => "NAS Repack or Proper", "score" => 10 }]
    }],
    "qualitydefinition" => [
      { "quality" => { "name" => "Bluray-1080p" }, "title" => "Bluray-1080p",
        "weight" => 1, "minSize" => 0, "preferredSize" => 50, "maxSize" => 100 },
      { "quality" => { "name" => "WEBDL-1080p" }, "title" => "WEBDL-1080p",
        "weight" => 2, "minSize" => 0, "preferredSize" => 45, "maxSize" => 90 }
    ],
    "customformat" => [{
      "id" => 201, "name" => "NAS Repack or Proper",
      "includeCustomFormatWhenRenaming" => false,
      "specifications" => [{
        "name" => "Repack or Proper release title",
        "implementation" => "ReleaseTitleSpecification", "negate" => false,
        "required" => false, "fields" => [{ "name" => "value", "value" => "(?i)repack|proper" }]
      }]
    }],
    "config/naming" => {
      "id" => 301, "renameMovies" => false,
      "standardMovieFormat" => RADARR_MOVIE_FORMAT,
      "movieFolderFormat" => "{Movie CleanTitle} ({Release Year}) {tmdb-{TmdbId}}"
    }
  },
  "sonarr" => {
    "qualityprofile" => [{
      "id" => 102, "name" => "HD Bluray + WEB 1080p", "upgradeAllowed" => false,
      "minFormatScore" => 0,
      "items" => [
        { "quality" => { "name" => "Bluray-1080p" }, "allowed" => true },
        { "name" => "WEB 1080p", "allowed" => true,
          "items" => %w[WEBDL-1080p WEBRip-1080p].map do |name|
            { "quality" => { "name" => name }, "allowed" => true }
          end }
      ],
      "formatItems" => [{ "name" => "NAS Repack or Proper", "score" => 10 }]
    }],
    "qualitydefinition" => [
      { "quality" => { "name" => "Bluray-1080p" }, "title" => "Bluray-1080p",
        "weight" => 1, "minSize" => 0, "preferredSize" => 50, "maxSize" => 100 },
      { "quality" => { "name" => "WEBDL-1080p" }, "title" => "WEBDL-1080p",
        "weight" => 2, "minSize" => 0, "preferredSize" => 45, "maxSize" => 90 }
    ],
    "customformat" => [{
      "id" => 202, "name" => "NAS Repack or Proper",
      "includeCustomFormatWhenRenaming" => false,
      "specifications" => [{
        "name" => "Repack or Proper release title",
        "implementation" => "ReleaseTitleSpecification", "negate" => false,
        "required" => false, "fields" => [{ "name" => "value", "value" => "(?i)repack|proper" }]
      }]
    }],
    "config/naming" => {
      "id" => 302, "renameEpisodes" => false,
      "standardEpisodeFormat" => SONARR_EPISODE_FORMAT,
      "dailyEpisodeFormat" => "{Series TitleYear} - {Air-Date} - {Episode CleanTitle}",
      "animeEpisodeFormat" => "{Series TitleYear} - {absolute:000} - {Episode CleanTitle}",
      "seriesFolderFormat" => "{Series TitleYear} {tvdb-{TvdbId}}",
      "seasonFolderFormat" => "Season {season:00}"
    }
  }
}.freeze

def deep_copy(value)
  Marshal.load(Marshal.dump(value))
end

def task_slice(filename, first_name, last_name)
  path = File.join(ARR_TASKS, filename)
  tasks = YAML.safe_load_file(path, aliases: true)
  first_matches = tasks.each_index.select { |index| tasks[index]["name"] == first_name }
  last_matches = tasks.each_index.select { |index| tasks[index]["name"] == last_name }
  unless first_matches.length == 1 && last_matches.length == 1 && first_matches.first <= last_matches.first
    raise "#{filename} exact reconciliation task boundary is unavailable"
  end

  deep_copy(tasks[first_matches.first..last_matches.first])
end

def selected_tasks(kind)
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
      "category" => fields["movieCategory"] || fields["tvCategory"]
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

def bazarr_projection(settings)
  {
    "auth" => settings.fetch("auth").slice("type", "username", "password"),
    "general" => settings.fetch("general").slice(
      "use_radarr", "use_sonarr", "path_mappings", "path_mappings_movie"
    ).merge("enabled_providers" => normalized_list(settings.dig("general", "enabled_providers"))),
    "radarr" => settings.fetch("radarr").slice("ip", "port", "base_url", "ssl", "apikey"),
    "sonarr" => settings.fetch("sonarr").slice("ip", "port", "base_url", "ssl", "apikey"),
    "languages" => normalized_list(settings.dig("languages", "enabled")),
    "providers" => settings.fetch("providers", {}).sort.to_h
  }
end

def configarr_projection(settings)
  %w[radarr sonarr].to_h do |service|
    resources = settings.fetch(service)
    [service, {
      "quality_profile" => resources.fetch("qualityprofile").find do |profile|
        profile["name"] == "HD Bluray + WEB 1080p"
      end,
      "quality_definitions" => resources.fetch("qualitydefinition"),
      "custom_format" => resources.fetch("customformat").find do |format|
        format["name"] == "NAS Repack or Proper"
      end,
      "naming" => resources.fetch("config/naming")
    }]
  end
end

def set_field!(object, name, value)
  field = object.fetch("fields").find { |candidate| candidate["name"] == name }
  raise "fixture field #{name} is unavailable" unless field

  field["value"] = value
end

class AcquisitionApi
  attr_reader :port, :requests, :state, :error, :unexpected_requests

  def initialize(state, fail_configarr: false)
    @state = state
    @fail_configarr = fail_configarr
    @requests = []
    @unexpected_requests = []
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr.fetch(1)
    @stopped = false
    @thread = Thread.new { serve }
  end

  def close
    @stopped = true
    @server.close
    @thread.join
  rescue IOError, Errno::EBADF
    @thread&.join
  end

  private

  def serve
    until @stopped
      next unless IO.select([@server], nil, nil, 0.05)

      client = @server.accept
      handle(client)
      client.close
    end
  rescue IOError, Errno::EBADF
    nil
  rescue StandardError => caught
    @error = caught unless @stopped
  end

  def handle(client)
    method, target, = client.gets.to_s.strip.split(" ", 3)
    headers = {}
    while (line = client.gets)
      line = line.chomp
      break if line == "\r" || line.empty?

      key, value = line.split(":", 2)
      headers[key.downcase] = value.to_s.strip
    end
    body = client.read(headers.fetch("content-length", "0").to_i)
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
    client.write(
      "HTTP/1.1 #{status} #{reason}\r\nContent-Type: #{content_type}\r\n" \
      "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
    )
  end
end

def base_variables(port)
  {
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
    "arr_bazarr_api" => "http://127.0.0.1:#{port}/api",
    "vault_arr_bazarr_api_key" => "fixture-bazarr-control-key",
    "vault_arr_bazarr_admin_username" => "fixture-bazarr-admin",
    "vault_arr_bazarr_admin_password" => SECRETS.fetch("bazarr_admin"),
    "vault_arr_radarr_api_key" => SECRETS.fetch("radarr"),
    "vault_arr_sonarr_api_key" => SECRETS.fetch("sonarr"),
    "media_bazarr_languages" => %w[en de], "media_bazarr_providers" => [],
    "arr_installed_reconciliation_fingerprints" => {
      "prowlarr_applications" => "same", "servarr_sabnzbd" => "same",
      "prowlarr_indexers" => "same", "bazarr_providers" => "same", "configarr" => "same"
    },
    "arr_desired_reconciliation_fingerprints" => {
      "prowlarr_applications" => "same", "servarr_sabnzbd" => "same",
      "prowlarr_indexers" => "same", "bazarr_providers" => "same", "configarr" => "same"
    }
  }
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

def run_tasks(kind, api, extra_variables = {}, runtime: nil)
  Dir.mktmpdir("media-acquisition-reconciliation-") do |directory|
    variables = base_variables(api.port).merge(extra_variables)
    if (fixture_servarr_instance = variables.delete("fixture_servarr_instance"))
      variables["arr_servarr_instance"] = fixture_servarr_instance.merge(
        "api" => "http://127.0.0.1:#{api.port}/api/v3"
      )
    end
    env = { "ANSIBLE_NOCOLOR" => "1" }
    if kind == :configarr
      runtime ||= File.join(directory, "runtime")
      FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
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
        "arr_servarr_instances" => %w[radarr sonarr].map do |service|
          {
            "name" => service,
            "api" => "http://127.0.0.1:#{api.port}/#{service}/api/v3",
            "api_key" => SECRETS.fetch(service),
            "rename_field" => service == "radarr" ? "renameMovies" : "renameEpisodes"
          }
        end
      )
    end
    playbook = File.join(directory, "playbook.yml")
    File.write(
      playbook,
      YAML.dump([{
        "hosts" => "localhost", "gather_facts" => false,
        "vars" => variables, "tasks" => selected_tasks(kind)
      }]),
      mode: "w", perm: 0o600
    )
    stdout, stderr, status = Open3.capture3(
      env, ANSIBLE_PLAYBOOK, "-i", "localhost,", "-c", "local", playbook, chdir: ROOT
    )
    {
      "stdout" => stdout, "stderr" => stderr, "status" => status,
      "changed" => stdout.scan(/changed=(\d+)/).flatten.last&.to_i
    }
  end
end

def with_api(state, fail_configarr: false)
  api = AcquisitionApi.new(state, fail_configarr: fail_configarr)
  yield api
ensure
  api&.close
end

def sanitized_tail(result)
  output = result.values_at("stdout", "stderr").join("\n")
  SECRET_SENTINELS.each { |secret| output = output.gsub(secret, "[REDACTED]") }
  output.lines.last(12).join.strip
end

def harness_problem(result, api)
  return "fixture server raised #{api.error.class}" if api.error
  unless api.unexpected_requests.empty?
    method, target = api.unexpected_requests.first
    return "fixture route is missing for #{method} #{target}"
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

def check_sanity(failures, label, result, api)
  output = result.values_at("stdout", "stderr").join("\n")
  if SECRET_SENTINELS.any? { |secret| output.include?(secret) }
    failures << "secret redaction failed during #{label}"
  end
  problem = harness_problem(result, api)
  failures << "HARNESS #{label}: #{problem}" if problem
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
      sane = check_sanity(failures, "#{relationship} #{field}", result, api)
      next unless sane

      unless result.fetch("status").success?
        failures << "#{relationship} failed while reconciling owned field #{field}"
        next
      end
      writes = mutation_requests(api, write_matcher)
      unless writes.length == 1
        failures << "#{relationship} owned field #{field} did not produce exactly one applicable write"
      end
      failures << "#{relationship} owned field #{field} did not report changed=1" unless result["changed"] == 1
      actual = current.call(api.state)
      unless projection.call(actual) == projection.call(desired)
        failures << "#{relationship} omitted owned field #{field}"
      end
    end
  end
end

def exercise_stable(failures, relationship:, kind:, state:, variables: {}, write_matcher:,
                    projection:, desired:, current:, allow_safe_resubmission: false)
  with_api(deep_copy(state)) do |api|
    result = run_tasks(kind, api, variables)
    sane = check_sanity(failures, "#{relationship} stable masked state", result, api)
    next unless sane

    unless result.fetch("status").success?
      failures << "#{relationship} rejected complete stable readable state"
      next
    end
    writes = mutation_requests(api, write_matcher)
    unless result["changed"] == 0
      failures << "#{relationship} stable state reported changed=#{result['changed'].inspect}, " \
                  "expected changed=0"
    end
    if allow_safe_resubmission
      failures << "#{relationship} stable masked state submitted more than one safe write" if writes.length > 1
    elsif !writes.empty?
      failures << "#{relationship} complete stable readable state issued a write"
    end
    actual = current.call(api.state)
    unless projection.call(actual) == projection.call(desired)
      failures << "#{relationship} stable state no longer matches the owned projection"
    end
  end
end

def exercise_secret_change(failures, relationship:, kind:, state:, field:, variables:,
                           write_matcher:, projection:, desired:, current:)
  with_api(deep_copy(state)) do |api|
    result = run_tasks(kind, api, variables)
    sane = check_sanity(failures, "#{relationship} masked secret #{field}", result, api)
    next unless sane

    unless result.fetch("status").success?
      failures << "#{relationship} failed while repairing masked secret #{field}"
      next
    end
    writes = mutation_requests(api, write_matcher)
    unless writes.length == 1
      failures << "#{relationship} masked secret #{field} did not produce exactly one applicable write"
    end
    failures << "#{relationship} masked secret #{field} did not report changed=1" unless result["changed"] == 1
    actual = current.call(api.state)
    unless projection.call(actual) == projection.call(desired)
      failures << "#{relationship} masked secret #{field} ignored desired-input fingerprint drift"
    end
  end
end

def exercise_duplicate(failures, relationship:, kind:, state:, variables:, write_matcher:)
  with_api(deep_copy(state)) do |api|
    result = run_tasks(kind, api, variables)
    sane = check_sanity(failures, "#{relationship} duplicate identity", result, api)
    next unless sane

    failures << "#{relationship} duplicate identity was accepted" if result.fetch("status").success?
    unless mutation_requests(api, write_matcher).empty?
      failures << "#{relationship} duplicate identity reached mutation"
    end
  end
end

abort "media acquisition reconciliation fixture requires #{ANSIBLE_PLAYBOOK}" unless File.executable?(ANSIBLE_PLAYBOOK)

# Force every exact production boundary to load before starting the HTTP fixture. A
# missing task name is a harness defect, not an owned-field failure.
%i[application indexer download_client bazarr configarr].each { |kind| selected_tasks(kind) }

failures = []
fingerprint_loader = File.join(ARR_TASKS, "reconciliation_fingerprints.yml")
fingerprint_recorder = File.join(ARR_TASKS, "record_reconciliation_fingerprints.yml")
failures << "private desired-input fingerprint loading is unavailable" unless File.file?(fingerprint_loader)
failures << "verified desired-input fingerprint recording is unavailable" unless File.file?(fingerprint_recorder)

application_state = {
  "applications" => [
    deep_copy(APPLICATION), deep_copy(SONARR_APPLICATION),
    { "id" => 12, "name" => "Unmanaged", "fields" => [], "tags" => [] }
  ]
}
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
  current: application_current, allow_safe_resubmission: true
)
application_secret_state = deep_copy(application_state)
set_field!(application_secret_state.fetch("applications").first, "apiKey", "private-stale-application-secret")
exercise_secret_change(
  failures, relationship: "Prowlarr application", kind: :application,
  state: application_secret_state, field: "fields.apiKey",
  variables: {
    "arr_installed_reconciliation_fingerprints" => { "prowlarr_applications" => "stale" },
    "arr_desired_reconciliation_fingerprints" => { "prowlarr_applications" => "desired" }
  }, write_matcher: application_write, projection: method(:application_projection),
  desired: APPLICATION, current: application_current
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
  "fields.movieCategory" => ->(state) { set_field!(state.fetch("download_clients").first, "movieCategory", "legacy") }
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
  current: client_current, allow_safe_resubmission: true
)
%w[apiKey username password].each do |secret_field|
  secret_state = deep_copy(client_state)
  set_field!(secret_state.fetch("download_clients").first, secret_field, "private-stale-#{secret_field}")
  exercise_secret_change(
    failures, relationship: "Servarr SABnzbd client", kind: :download_client,
    state: secret_state, field: "fields.#{secret_field}",
    variables: {
      "arr_installed_reconciliation_fingerprints" => { "servarr_sabnzbd" => "stale" },
      "arr_desired_reconciliation_fingerprints" => { "servarr_sabnzbd" => "desired" }
    }, write_matcher: client_write, projection: method(:download_client_projection),
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
sonarr_client_mutations = client_mutations.reject { |field, _mutate| field == "fields.movieCategory" }
sonarr_client_mutations["fields.tvCategory"] = lambda do |state|
  set_field!(state.fetch("download_clients").first, "tvCategory", "legacy")
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
  current: sonarr_client_current, allow_safe_resubmission: true
)
%w[apiKey username password].each do |secret_field|
  secret_state = deep_copy(sonarr_client_state)
  set_field!(secret_state.fetch("download_clients").first, secret_field, "private-stale-sonarr-#{secret_field}")
  exercise_secret_change(
    failures, relationship: "Sonarr SABnzbd client", kind: :download_client,
    state: secret_state, field: "fields.#{secret_field}",
    variables: sonarr_variables.merge(
      "arr_installed_reconciliation_fingerprints" => { "servarr_sabnzbd" => "stale" },
      "arr_desired_reconciliation_fingerprints" => { "servarr_sabnzbd" => "desired" }
    ), write_matcher: client_write, projection: method(:download_client_projection),
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
  current: indexer_current, allow_safe_resubmission: true
)
indexer_secret_state = deep_copy(indexer_state)
set_field!(indexer_secret_state.fetch("indexers").first, "apiKey", "private-stale-indexer-secret")
exercise_secret_change(
  failures, relationship: "Prowlarr indexer", kind: :indexer,
  state: indexer_secret_state, field: "fields.apiKey",
  variables: {
    "arr_installed_reconciliation_fingerprints" => { "prowlarr_indexers" => "stale" },
    "arr_desired_reconciliation_fingerprints" => { "prowlarr_indexers" => "desired" }
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
  "sorted languages" => ->(state) { state.dig("bazarr", "languages")["enabled"] = ["fr"] },
  "sorted enabled providers" => ->(state) { state.dig("bazarr", "general")["enabled_providers"] = ["legacy"] }
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
  current: bazarr_current, allow_safe_resubmission: true
)
{
  "auth.password" => ["auth", "password"],
  "radarr.apikey" => ["radarr", "apikey"],
  "sonarr.apikey" => ["sonarr", "apikey"]
}.each do |label, (section, field)|
  secret_state = deep_copy(bazarr_state)
  secret_state.dig("bazarr", section)[field] = "private-stale-#{section}-#{field}"
  exercise_secret_change(
    failures, relationship: "Bazarr connection", kind: :bazarr,
    state: secret_state, field: label,
    variables: {
      "arr_installed_reconciliation_fingerprints" => { "bazarr_providers" => "stale" },
      "arr_desired_reconciliation_fingerprints" => { "bazarr_providers" => "desired" }
    }, write_matcher: bazarr_connection_write, projection: method(:bazarr_projection),
    desired: BAZARR, current: bazarr_current
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
exercise_mutations(
  failures, relationship: "Bazarr provider", kind: :bazarr,
  baseline: provider_state, mutations: provider_mutations, variables: provider_variables,
  write_matcher: provider_write, projection: method(:bazarr_projection),
  desired: BAZARR_WITH_PROVIDER, current: bazarr_current
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
  projection: method(:bazarr_projection), desired: BAZARR_WITH_PROVIDER,
  current: bazarr_current, allow_safe_resubmission: true
)
provider_secret_state = deep_copy(provider_state)
provider_secret_state.dig("bazarr", "providers", "opensubtitlescom")["password"] = "private-stale-provider-secret"
exercise_secret_change(
  failures, relationship: "Bazarr provider", kind: :bazarr,
  state: provider_secret_state, field: "provider.password",
  variables: provider_variables.merge(
    "arr_installed_reconciliation_fingerprints" => { "bazarr_providers" => "stale" },
    "arr_desired_reconciliation_fingerprints" => { "bazarr_providers" => "desired" }
  ), write_matcher: provider_write, projection: method(:bazarr_projection),
  desired: BAZARR_WITH_PROVIDER, current: bazarr_current
)

configarr_state = { "configarr" => deep_copy(CONFIGARR), "configarr_desired" => deep_copy(CONFIGARR) }
configarr_mutations = {}
%w[radarr sonarr].each do |service|
  configarr_mutations["#{service}.quality_profile.name"] = lambda do |state|
    state.dig("configarr", service, "qualityprofile").first["name"] = "Legacy Profile"
  end
  configarr_mutations["#{service}.quality_profile.qualities"] = lambda do |state|
    state.dig("configarr", service, "qualityprofile").first["items"] = []
  end
  configarr_mutations["#{service}.quality_profile.custom_format_score"] = lambda do |state|
    state.dig("configarr", service, "qualityprofile").first["formatItems"].first["score"] = 0
  end
  configarr_mutations["#{service}.quality_definitions"] = lambda do |state|
    state.dig("configarr", service, "qualitydefinition").pop
  end
  configarr_mutations["#{service}.custom_format.name"] = lambda do |state|
    state.dig("configarr", service, "customformat").first["name"] = "Legacy Format"
  end
  configarr_mutations["#{service}.custom_format.specifications"] = lambda do |state|
    state.dig("configarr", service, "customformat").first["specifications"] = []
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
configarr_secret_variables = {
  "arr_installed_reconciliation_fingerprints" => { "configarr" => "stale" },
  "arr_desired_reconciliation_fingerprints" => { "configarr" => "desired" }
}
exercise_secret_change(
  failures, relationship: "Configarr", kind: :configarr,
  state: configarr_state, field: "API key input fingerprint",
  variables: configarr_secret_variables, write_matcher: configarr_write,
  projection: method(:configarr_projection), desired: CONFIGARR, current: configarr_current
)
duplicate_configarr_state = deep_copy(configarr_state)
duplicate_configarr_state.dig("configarr", "radarr", "qualityprofile") <<
  deep_copy(CONFIGARR.dig("radarr", "qualityprofile").first).merge("id" => 103)
exercise_duplicate(
  failures, relationship: "Configarr quality profile", kind: :configarr,
  state: duplicate_configarr_state, variables: {}, write_matcher: configarr_write
)

Dir.mktmpdir("media-acquisition-fingerprint-failure-") do |runtime|
  fingerprint_directory = File.join(runtime, "services", "arr")
  FileUtils.mkdir_p(fingerprint_directory)
  before = FINGERPRINT_FILES.to_h do |filename|
    path = File.join(fingerprint_directory, filename)
    File.write(path, "prior-verified-fingerprint\n", mode: "w", perm: 0o600)
    [filename, File.binread(path)]
  end
  with_api(deep_copy(configarr_state), fail_configarr: true) do |api|
    result = run_tasks(:configarr, api, configarr_secret_variables, runtime: runtime)
    sane = check_sanity(failures, "failed reconciliation fingerprint ordering", result, api)
    if sane
      failures << "failed reconciliation was accepted" if result.fetch("status").success?
      unless mutation_requests(api, configarr_write).length == 1
        failures << "failed reconciliation did not attempt exactly one applicable write"
      end
      after = FINGERPRINT_FILES.to_h do |filename|
        path = File.join(fingerprint_directory, filename)
        [filename, File.file?(path) ? File.binread(path) : nil]
      end
      failures << "failed reconciliation advanced future fingerprint files" unless after == before
    end
  end
end

abort failures.join("\n") unless failures.empty?
puts "media acquisition reconciliation behavior holds"
