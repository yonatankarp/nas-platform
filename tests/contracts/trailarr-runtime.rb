#!/usr/bin/env ruby
# Runtime half of the Trailarr service contract, against a deployed Trailarr.
#
# usage: trailarr-runtime.rb (no arguments; inputs come from tests/contracts/trailarr.sh)
#
require "json"
require "net/http"
require "open3"
require "uri"
require "yaml"

READY_TIMEOUT_SECONDS = Integer(ENV.fetch("PLATFORM_TRAILARR_READY_TIMEOUT_SECONDS", "120"), 10)
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_TRAILARR_PORT'), 10)}")
CONTAINER = ENV.fetch("PLATFORM_TRAILARR_CONTAINER")
ARRS_EXPECTED = ENV.fetch("PLATFORM_TRAILARR_ARRS") == "true"
# The application's own .env, sourced with `set -o allexport` at every start.
APPLICATION_ENV = File.join(ENV.fetch("PLATFORM_DOCKER_ROOT"), "trailarr", "config", ".env")
DATABASE = File.join(ENV.fetch("PLATFORM_DOCKER_ROOT"), "trailarr", "config", "trailarr.db")
# Persisted on every boot by the config constructor; any other key is a hand edit.
HAND_WRITTEN_KEYS = %w[
  WEBUI_USERNAME WEBUI_PASSWORD WEBUI_DISABLE_AUTH MONITOR_ENABLED
  DOWNLOADS_ENABLED CREATE_MISSING_FOLDERS DELETE_TRAILER_CONNECTION
  DELETE_TRAILER_MEDIA URL_BASE
].freeze

def fail_contract(message)
  warn "Trailarr contract failed: #{message}"
  exit 1
end

def request(message)
  Net::HTTP.start(BASE.host, BASE.port, read_timeout: 15) { |http| http.request(message) }
end

def get(path, key: nil)
  message = Net::HTTP::Get.new(URI.join(BASE, path))
  message["X-API-KEY"] = key if key
  request(message)
end

def wait_for_health
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READY_TIMEOUT_SECONDS
  loop do
    begin
      response = get("/status")
      return response if response.code == "200"
    rescue StandardError
      nil
    end
    # A 404 is the hourly nvidia probe; up with nothing listening is a failed alembic migration.
    fail_contract("Trailarr never answered its status route") if
      Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    sleep 2
  end
end

health = wait_for_health
begin
  document = JSON.parse(health.body)
rescue JSON::ParserError
  fail_contract("Trailarr status route did not answer JSON")
end
fail_contract("Trailarr did not report a healthy status") unless
  document == { "status" => "healthy" }

state, _error, status = Open3.capture3(
  "docker", "inspect", CONTAINER, "--format", "{{.State.Health.Status}}"
)
fail_contract("the Trailarr container could not be inspected") unless status.success?
fail_contract("the Trailarr container is not healthy") unless state.strip == "healthy"

vault_yaml, vault_error, vault_status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file",
  ENV.fetch("PLATFORM_CONTRACT_VAULT_PASSWORD_FILE"),
  ENV.fetch("PLATFORM_CONTRACT_VAULT_FILE")
)
fail_contract("encrypted vault could not be read") unless vault_status.success?
vault = YAML.safe_load(vault_yaml)
vault_yaml.replace("\0" * vault_yaml.bytesize)
vault_error.replace("\0" * vault_error.bytesize)
api_key = vault.fetch("vault_trailarr_api_key")
username = vault.fetch("vault_trailarr_admin_username")
password = vault.fetch("vault_trailarr_admin_password")

fail_contract("Trailarr served a protected route to an anonymous request") unless
  get("/api/v1/settings/").code == "401"

def login(username, password)
  message = Net::HTTP::Post.new(URI.join(BASE, "/api/v1/auth/login"))
  message["Content-Type"] = "application/json"
  message.body = JSON.dump("username" => username, "password" => password)
  request(message)
end

fail_contract("Trailarr accepted the published default administrator") unless
  login("admin", "trailarr").code == "401"
fail_contract("Trailarr refused the vault-authored administrator") unless
  login(username, password).code == "200"

settings = get("/api/v1/settings/", key: api_key)
fail_contract("Trailarr refused the vault-authored API key") unless settings.code == "200"
declared = JSON.parse(settings.body)
fail_contract("Trailarr does not serve the vault-authored administrator name") unless
  declared["webui_username"] == username
{
  "webui_disable_auth" => false, "create_missing_folders" => false,
  "delete_trailer_connection" => false, "delete_trailer_media" => false,
  "update_ytdlp" => false, "ytdlp_nightly" => false,
  "monitor_enabled" => false, "downloads_enabled" => false
}.each do |field, expected|
  fail_contract("Trailarr does not report #{field} as the platform declares it") unless
    declared[field] == expected
end

# /config/.env overrides the Compose environment permanently, so a hand-written
# key must be absent; removing it is the repair.
fail_contract("Trailarr did not write its own application environment") unless
  File.file?(APPLICATION_ENV)
application_env = File.readlines(APPLICATION_ENV, chomp: true).filter_map do |line|
  stripped = line.strip
  next unless stripped.match?(/\A[A-Z][A-Z0-9_]*=/)

  name, _separator, value = stripped.partition("=")
  [name, value]
end.to_h
# python-dotenv writes KEY='value'; not $-doubled, because bash sources this file.
fail_contract("Trailarr does not carry the vault-authored API key in its own environment") unless
  application_env["API_KEY"] == "'#{api_key}'"
# WEBUI_PASSWORD is only persisted when empty, so a line here is a hand-changed login.
HAND_WRITTEN_KEYS.each do |key|
  fail_contract("Trailarr's application environment carries a hand-written #{key}") if
    application_env.key?(key)
end

profiles = get("/api/v1/trailerprofiles/", key: api_key)
fail_contract("the Trailarr trailer profiles could not be read") unless profiles.code == "200"
seeded = JSON.parse(profiles.body).select { |profile| [1, 2].include?(profile["id"]) }
fail_contract("Trailarr does not hold both seeded trailer profiles") unless seeded.length == 2
seeded.each do |profile|
  {
    "folder_enabled" => true, "folder_name" => "Trailers",
    "custom_folder" => "{media_folder}", "file_format" => "mp4",
    "video_format" => "h264", "audio_format" => "aac"
  }.each do |field, expected|
    fail_contract("Trailarr trailer profile #{profile['id']} does not declare #{field}") unless
      profile[field] == expected
  end
end

connections = get("/api/v1/connections/", key: api_key)
fail_contract("the Trailarr connections could not be read") unless connections.code == "200"
declared_connections = JSON.parse(connections.body)
if ARRS_EXPECTED
  %w[Radarr Sonarr].each do |name|
    matches = declared_connections.select { |entry| entry["name"] == name }
    # The create route has no duplicate check.
    fail_contract("Trailarr does not hold exactly one #{name} connection") unless
      matches.length == 1
    connection = matches.first
    fail_contract("the Trailarr #{name} connection is not addressed by service alias") unless
      connection["url"] == "http://#{name.downcase}:#{name == 'Radarr' ? 7878 : 8989}"
    # A declared mapping reads back with a trailing slash and drifts forever.
    fail_contract("the Trailarr #{name} connection declares a path mapping") unless
      Array(connection["path_mappings"]).empty?
    fail_contract("the Trailarr #{name} connection monitors new media before acceptance") if
      connection["monitor_new_media"]
  end
else
  fail_contract("Trailarr declared an arr connection with no transport enabled") unless
    declared_connections.empty?
end

fail_contract("Trailarr did not persist its database in the declared config root") unless
  File.file?(DATABASE) && File.size?(DATABASE)

puts "trailarr contract: health, exclusive identity, owned application environment, " \
     "declared profiles and connections, and persisted state hold"
