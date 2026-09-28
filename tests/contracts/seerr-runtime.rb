#!/usr/bin/env ruby
# Runtime half of the Seerr contract, against a deployed Seerr, its database
# and the encrypted vault. No arguments: every input comes from the environment
# tests/contracts/seerr.sh exports.
require "json"
require "net/http"
require "open3"
require "uri"
require "yaml"

# An environment input so a caller facing a port nothing answers can shorten it.
READY_TIMEOUT_SECONDS = Integer(ENV.fetch("PLATFORM_SEERR_READY_TIMEOUT_SECONDS", "180"), 10)
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_SEERR_PORT'), 10)}")
CONTAINER = ENV.fetch("PLATFORM_SEERR_CONTAINER")
ARRS_EXPECTED = ENV.fetch("PLATFORM_SEERR_ARRS") == "true"
# "true" where the converge blanked the Pushover pair (the Mac lane, whose real
# vault cannot be redirected).
PUSHOVER_BLANKED = ENV.fetch("PLATFORM_SEERR_PUSHOVER_BLANKED") == "true"
# The user table closes the anonymous takeover window; settings.json alone would not.
DATABASE = File.join(ENV.fetch("PLATFORM_DOCKER_ROOT"), "seerr", "config", "db", "db.sqlite3")

def fail_contract(message)
  warn "Seerr contract failed: #{message}"
  exit 1
end

def request(path, key: nil, user: nil)
  message = Net::HTTP::Get.new(URI.join(BASE, path))
  message["X-Api-Key"] = key if key
  message["X-API-User"] = user.to_s if user
  Net::HTTP.start(BASE.host, BASE.port, read_timeout: 20) { |http| http.request(message) }
end

def json(response, label)
  JSON.parse(response.body)
rescue JSON::ParserError
  fail_contract("#{label} did not answer JSON")
end

def wait_for_status
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READY_TIMEOUT_SECONDS
  loop do
    begin
      response = request("/api/v1/status")
      return response if response.code == "200"
    rescue StandardError
      nil
    end
    fail_contract("Seerr never answered its status endpoint") if
      Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    sleep 2
  end
end

status = json(wait_for_status, "the Seerr status endpoint")
fail_contract("Seerr did not report a version") unless status["version"].to_s.length.positive?

state, _error, inspect_status = Open3.capture3(
  "docker", "inspect", CONTAINER, "--format", "{{.State.Health.Status}}"
)
fail_contract("the Seerr container could not be inspected") unless inspect_status.success?
fail_contract("the Seerr container is not healthy") unless state.strip == "healthy"

vault_yaml, vault_error, vault_status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file",
  ENV.fetch("PLATFORM_CONTRACT_VAULT_PASSWORD_FILE"),
  ENV.fetch("PLATFORM_CONTRACT_VAULT_FILE")
)
fail_contract("encrypted vault could not be read") unless vault_status.success?
vault = YAML.safe_load(vault_yaml)
vault_yaml.replace("\0" * vault_yaml.bytesize)
vault_error.replace("\0" * vault_error.bytesize)
key = vault.fetch("vault_seerr_api_key")
household = Array(vault["vault_managed_jellyfin_users"]).map { |entry| entry.fetch("username") }

fail_contract("Seerr served a protected route to an anonymous request") unless
  request("/api/v1/user").code == "401"
fail_contract("Seerr accepted a key the platform never authored") unless
  request("/api/v1/user", key: "0" * 32).code == "403"
users_response = request("/api/v1/user", key: key)
fail_contract("Seerr refused the vault-authored API key") unless users_response.code == "200"

users = json(users_response, "the Seerr user list").fetch("results")
owner = users.find { |user| user["id"] == 1 }
fail_contract("Seerr has no owner row, so its takeover window is open") if owner.nil?
fail_contract("the Seerr owner does not hold exactly ADMIN") unless owner["permissions"] == 2

household.each do |username|
  row = users.find { |user| user["jellyfinUsername"] == username }
  fail_contract("Seerr never imported the managed Jellyfin user #{username}") if row.nil?
  fail_contract("#{username} does not hold exactly REQUEST and AUTO_APPROVE") unless
    row["permissions"] == 160
  fail_contract("#{username} carries a request quota the design does not grant") unless
    row["movieQuotaLimit"].nil? && row["tvQuotaLimit"].nil?

  # X-API-User impersonates, proving the split without holding that user's password.
  as_user = json(request("/api/v1/auth/me", key: key, user: row.fetch("id")), "the impersonated identity")
  fail_contract("#{username} sees a different identity than Seerr stored") unless
    as_user["id"] == row.fetch("id") && as_user["permissions"] == 160
end

public_settings = json(request("/api/v1/settings/public"), "the Seerr public settings")
fail_contract("Seerr still redirects visitors to its setup wizard") unless
  public_settings["initialized"] == true
fail_contract("Seerr left a local password login path open") unless
  public_settings["localLogin"] == false
fail_contract("Seerr would silently create any Jellyfin user who signs in") unless
  public_settings["newPlexLogin"] == false
# mediaServerLogin enables Jellyfin sign-in at all; false would lock out both identities.
fail_contract("Seerr disabled Jellyfin sign-in for its own identities") unless
  public_settings["mediaServerLogin"] == true
fail_contract("Seerr is not pointed at a Jellyfin media server") unless
  public_settings["mediaServerType"] == 2

main = json(request("/api/v1/settings/main", key: key), "the Seerr main settings")
fail_contract("Seerr is not serving the vault-authored API key") unless main["apiKey"] == key
fail_contract("a newly discovered Seerr user would inherit request permissions") unless
  main["defaultPermissions"] == 0

jellyfin = json(request("/api/v1/settings/jellyfin", key: key), "the Seerr Jellyfin settings")
fail_contract("Seerr does not name the platform's Jellyfin server") unless
  jellyfin["ip"] == "jellyfin" && jellyfin["port"] == 8096

# The takeover window: this route must refuse a Jellyfin server the platform never named.
takeover = Net::HTTP::Post.new(URI.join(BASE, "/api/v1/auth/jellyfin"))
takeover["Content-Type"] = "application/json"
takeover.body = JSON.dump(
  "username" => "contract-intruder", "password" => "contract-intruder",
  "hostname" => "jellyfin.contract.invalid", "port" => 8096, "useSsl" => false, "serverType" => 2
)
refusal = Net::HTTP.start(BASE.host, BASE.port, read_timeout: 20) { |http| http.request(takeover) }
fail_contract("Seerr accepted a foreign Jellyfin server after bootstrap") unless
  refusal.code == "500" && refusal.body.include?("already configured")

%w[radarr sonarr].each do |kind|
  rows = json(request("/api/v1/settings/#{kind}", key: key), "the Seerr #{kind} servers")
  if ARRS_EXPECTED
    fail_contract("Seerr declares no #{kind} server") unless rows.length == 1
    row = rows.first
    fail_contract("Seerr's #{kind} server does not carry that arr's own API key") unless
      row["apiKey"] == vault.fetch("vault_arr_#{kind}_api_key")
    fail_contract("Seerr's #{kind} server is not addressed by service alias") unless
      row["hostname"] == kind
  else
    fail_contract("Seerr declared a #{kind} server on a host with no transport") unless rows.empty?
  end
end

pushover = json(request("/api/v1/settings/notifications/pushover", key: key), "the Seerr Pushover agent")
fail_contract("Seerr's Pushover agent is disabled") unless pushover["enabled"] == true
fail_contract("Seerr's Pushover agent does not send request events") unless pushover["types"] == 152
# Seerr's agent posts to a hardcoded Pushover address, so the Mac lane blanks the pair.
expected_pair = if PUSHOVER_BLANKED
                  ["", ""]
                else
                  [vault.fetch("vault_pushover_media_token"), vault.fetch("vault_pushover_user_key")]
                end
fail_contract("Seerr's Pushover agent does not carry the declared Pushover pair") unless
  [pushover.dig("options", "accessToken"), pushover.dig("options", "userToken")] == expected_pair

ntfy = json(request("/api/v1/settings/notifications/ntfy", key: key), "the Seerr ntfy agent")
fail_contract("Seerr's ntfy agent still publishes beside Pushover") unless ntfy["enabled"] == false

fail_contract("Seerr did not persist its database in the declared config root") unless
  File.file?(DATABASE) && File.size?(DATABASE)

puts "seerr contract: bootstrapped owner, permission split, sign-in policy, and persisted state hold"
