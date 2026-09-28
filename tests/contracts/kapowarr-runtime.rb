#!/usr/bin/env ruby
# Runtime half of the Kapowarr service contract, against a deployed Kapowarr.
#
# usage: kapowarr-runtime.rb
#
require "json"
require "net/http"
require "open3"
require "uri"
require "yaml"

READY_TIMEOUT_SECONDS = 120
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_KAPOWARR_PORT'), 10)}")
CONTAINER = ENV.fetch("PLATFORM_KAPOWARR_CONTAINER")
# Its absence is what a wrongly owned or mounted config bind looks like.
DATABASE = File.join(ENV.fetch("PLATFORM_DOCKER_ROOT"), "kapowarr", "config", "Kapowarr.db")
# An offset of the one Books bind mount, shared with staging to keep imports renames.
LIBRARY_ROOT = "/data/books/Comics"

def fail_contract(message)
  warn "Kapowarr contract failed: #{message}"
  exit 1
end

def get(path)
  request = Net::HTTP::Get.new(URI.join(BASE, path))
  Net::HTTP.start(BASE.host, BASE.port, read_timeout: 15) { |http| http.request(request) }
end

def post(path, payload)
  request = Net::HTTP::Post.new(URI.join(BASE, path), "Content-Type" => "application/json")
  request.body = JSON.generate(payload)
  Net::HTTP.start(BASE.host, BASE.port, read_timeout: 15) { |http| http.request(request) }
end

def wait_for_readiness
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READY_TIMEOUT_SECONDS
  loop do
    begin
      response = get("/api/public")
      return response if response.code == "200"
    rescue StandardError
      nil
    end
    fail_contract("Kapowarr never answered its public endpoint") if
      Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    sleep 2
  end
end

public_response = wait_for_readiness
begin
  document = JSON.parse(public_response.body)
rescue JSON::ParserError
  fail_contract("Kapowarr public endpoint did not answer JSON")
end
# Mode 2 is username and password; below 2 is an open writer.
fail_contract("Kapowarr does not enforce the username and password pair") unless
  document.dig("result", "authentication_method") == 2

state, _error, status = Open3.capture3(
  "docker", "inspect", CONTAINER, "--format", "{{.State.Health.Status}}"
)
fail_contract("the Kapowarr container could not be inspected") unless status.success?
fail_contract("the Kapowarr container is not healthy") unless state.strip == "healthy"

vault_yaml, vault_error, vault_status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file",
  ENV.fetch("PLATFORM_CONTRACT_VAULT_PASSWORD_FILE"),
  ENV.fetch("PLATFORM_CONTRACT_VAULT_FILE")
)
fail_contract("encrypted vault could not be read") unless vault_status.success?
vault = YAML.safe_load(vault_yaml)
vault_yaml.replace("\0" * vault_yaml.bytesize)
vault_error.replace("\0" * vault_error.bytesize)
username = vault.fetch("vault_kapowarr_admin_username")
password = vault.fetch("vault_kapowarr_admin_password")

fail_contract("Kapowarr logged in a caller with no credential") unless
  post("/api/auth", {}).code == "401"
fail_contract("Kapowarr logged in a caller with a wrong password") unless
  post("/api/auth", "username" => username, "password" => "contract-wrong-password").code == "401"
login = post("/api/auth", "username" => username, "password" => password)
fail_contract("Kapowarr refused the vault-authored administrator") unless login.code == "200"
api_key = JSON.parse(login.body).dig("result", "api_key")
fail_contract("Kapowarr returned no API key to the vault administrator") unless
  api_key.is_a?(String) && api_key.match?(/\A[0-9a-f]{32}\z/)

roots = get("/api/rootfolder?api_key=#{api_key}")
fail_contract("Kapowarr refused to list its library roots") unless roots.code == "200"
declared = JSON.parse(roots.body).fetch("result").map do |entry|
  entry.fetch("folder").sub(%r{/+\z}, "")
end
fail_contract("Kapowarr does not own exactly the declared comics library root") unless
  declared == [LIBRARY_ROOT]

fail_contract("Kapowarr did not persist its database in the declared config root") unless
  File.file?(DATABASE) && File.size?(DATABASE)

# The only place the application's own validation meets the declared settings.
settings = get("/api/settings?api_key=#{api_key}")
fail_contract("Kapowarr refused to report its settings") unless settings.code == "200"
deployed_settings = JSON.parse(settings.body).fetch("result")
role_defaults = YAML.safe_load_file(
  File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "roles/kapowarr/defaults/main.yml")
)
mismatched = role_defaults.fetch("kapowarr_settings").reject do |key, value|
  deployed_settings[key] == value
end
unless mismatched.empty?
  fail_contract(
    "Kapowarr does not hold the declared application settings: #{mismatched.keys.join(', ')}"
  )
end

# The service order is on the single GetComics indexer since v1.3.2 (#671).
indexers = get("/api/indexers?api_key=#{api_key}")
fail_contract("Kapowarr refused to list its indexers") unless indexers.code == "200"
getcomics = Array(JSON.parse(indexers.body).fetch("result")).select do |entry|
  entry.is_a?(Hash) && entry["client_type"] == "GetComics"
end
fail_contract("Kapowarr does not hold exactly one GetComics indexer") unless getcomics.length == 1

# A partial order: compare only services both lists name. Empty is refused first.
declared_order = Array(role_defaults.fetch("kapowarr_service_preference"))
deployed_order = Array(getcomics.first["gc_service_preference"])
fail_contract("Kapowarr does not hold the declared download service order") unless
  !deployed_order.empty? &&
  deployed_order.select { |service| declared_order.include?(service) } ==
    declared_order.select { |service| deployed_order.include?(service) }

puts "kapowarr contract: health, exclusive administrator identity, comics root ownership, " \
     "declared application settings, and persisted state hold"
