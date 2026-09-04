#!/usr/bin/env ruby
# The runtime half of the Seerr service contract: what can only be decided
# against a deployed Seerr, its database and the encrypted vault.
#
# usage: seerr-runtime.rb
#
# It takes NO arguments. Every input arrives in the environment, exported by
# tests/contracts/seerr.sh: PLATFORM_SEERR_PORT, PLATFORM_SEERR_CONTAINER,
# PLATFORM_SEERR_ARRS, PLATFORM_DOCKER_ROOT, PLATFORM_CONTRACT_VAULT_FILE and
# PLATFORM_CONTRACT_VAULT_PASSWORD_FILE.
#
require "json"
require "net/http"
require "open3"
require "uri"
require "yaml"

# How long a real Seerr is given to answer its status endpoint. Like every other
# input to this half it arrives in the environment rather than as a constant,
# which is what let #319 shorten it for the one caller that ever wanted a
# different budget: the run-mode environment rows in tests/seerr_contract_test.rb
# reached this program when a planted regression let a refusal through, and there
# was no Seerr behind the port at all.
#
# #331 removed that caller instead of shortening it -- those rows now substitute
# a stub for this program, so reaching it is the regression rather than a wait --
# and nothing in the tree sets this name any more. The override is kept because a
# caller that must not sit out three minutes against a port nothing answers is a
# recurring shape, and because a deployment reads the default either way.
READY_TIMEOUT_SECONDS = Integer(ENV.fetch("PLATFORM_SEERR_READY_TIMEOUT_SECONDS", "180"), 10)
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_SEERR_PORT'), 10)}")
CONTAINER = ENV.fetch("PLATFORM_SEERR_CONTAINER")
ARRS_EXPECTED = ENV.fetch("PLATFORM_SEERR_ARRS") == "true"
# The user table is Seerr's real state and the only thing that closes its
# anonymous takeover window: a restore that brought back settings.json without
# this file would reopen it.
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
household = Array(vault.dig("vault_managed_users", "jellyfin")).map { |entry| entry.fetch("username") }

# Three access outcomes on a protected route: refused anonymously, refused with
# a wrong key, accepted with exactly the vault's.
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

  # X-API-User impersonates, so the second identity's own view proves the split
  # from the outside without the contract ever holding that user's password.
  as_user = json(request("/api/v1/auth/me", key: key, user: row.fetch("id")), "the impersonated identity")
  fail_contract("#{username} sees a different identity than Seerr stored") unless
    as_user["id"] == row.fetch("id") && as_user["permissions"] == 160
end

# The anonymous public settings are what a visitor sees before signing in, and
# they carry the three switches the design's clause about newly discovered
# users rests on.
public_settings = json(request("/api/v1/settings/public"), "the Seerr public settings")
fail_contract("Seerr still redirects visitors to its setup wizard") unless
  public_settings["initialized"] == true
fail_contract("Seerr left a local password login path open") unless
  public_settings["localLogin"] == false
fail_contract("Seerr would silently create any Jellyfin user who signs in") unless
  public_settings["newPlexLogin"] == false
# Not an oversight: mediaServerLogin is the switch that enables Jellyfin
# sign-in at all, so with it false the two imported identities could not reach
# the service either.
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

# The takeover window: the same anonymous route that created the owner must now
# refuse to be pointed at a Jellyfin server the platform never named.
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
    # Neither arr runs on a host without the transport, so a declared row would
    # name a host that does not resolve.
    fail_contract("Seerr declared a #{kind} server on a host with no transport") unless rows.empty?
  end
end

ntfy = json(request("/api/v1/settings/notifications/ntfy", key: key), "the Seerr ntfy agent")
fail_contract("Seerr's ntfy agent is disabled") unless ntfy["enabled"] == true
fail_contract("Seerr's ntfy agent publishes without authenticating") unless
  ntfy.dig("options", "authMethodToken") == true &&
  ntfy.dig("options", "token") == vault.fetch("vault_ntfy_seerr_token")

fail_contract("Seerr did not persist its database in the declared config root") unless
  File.file?(DATABASE) && File.size?(DATABASE)

puts "seerr contract: bootstrapped owner, permission split, sign-in policy, and persisted state hold"
