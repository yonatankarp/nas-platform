#!/usr/bin/env ruby
# Runtime half of the Pinchflat service contract: health, that only the vault's
# administrator is admitted, and that state landed in the config root (#147).
# Takes no arguments; its input is the environment tests/contracts/pinchflat.sh exports.
require "json"
require "net/http"
require "open3"
require "timeout"
require "uri"
require "yaml"

READY_TIMEOUT_SECONDS = 120
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_PINCHFLAT_PORT'), 10)}")
CONTAINER = ENV.fetch("PLATFORM_PINCHFLAT_CONTAINER")
# The SQLite database under the config root is Pinchflat's whole state; its absence
# means a wrongly owned or mounted config bind.
DATABASE = File.join(ENV.fetch("PLATFORM_DOCKER_ROOT"), "pinchflat", "config", "db", "pinchflat.db")

def fail_contract(message)
  warn "Pinchflat contract failed: #{message}"
  exit 1
end

def request(path, credentials: nil)
  request = Net::HTTP::Get.new(URI.join(BASE, path))
  request.basic_auth(*credentials) if credentials
  Net::HTTP.start(BASE.host, BASE.port, read_timeout: 15) { |http| http.request(request) }
end

def wait_for_health
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READY_TIMEOUT_SECONDS
  loop do
    begin
      response = request("/healthcheck")
      return response if response.code == "200"
    rescue StandardError
      nil
    end
    fail_contract("Pinchflat never answered its health endpoint") if
      Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    sleep 2
  end
end

health = wait_for_health
begin
  document = JSON.parse(health.body)
rescue JSON::ParserError
  fail_contract("Pinchflat health endpoint did not answer JSON")
end
fail_contract("Pinchflat did not report a healthy status") unless document == { "status" => "ok" }

state, _error, status = Open3.capture3(
  "docker", "inspect", CONTAINER, "--format", "{{.State.Health.Status}}"
)
fail_contract("the Pinchflat container could not be inspected") unless status.success?
fail_contract("the Pinchflat container is not healthy") unless state.strip == "healthy"

vault_yaml, vault_error, vault_status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file",
  ENV.fetch("PLATFORM_CONTRACT_VAULT_PASSWORD_FILE"),
  ENV.fetch("PLATFORM_CONTRACT_VAULT_FILE")
)
fail_contract("encrypted vault could not be read") unless vault_status.success?
vault = YAML.safe_load(vault_yaml)
vault_yaml.replace("\0" * vault_yaml.bytesize)
vault_error.replace("\0" * vault_error.bytesize)
credentials = [
  vault.fetch("vault_pinchflat_admin_username"), vault.fetch("vault_pinchflat_admin_password")
]

# Refused without a credential, refused with the wrong one, accepted with the vault's.
fail_contract("Pinchflat served its interface to an anonymous request") unless
  request("/").code == "401"
fail_contract("Pinchflat served its interface to a wrong password") unless
  request("/", credentials: [credentials.first, "contract-wrong-password"]).code == "401"
fail_contract("Pinchflat refused the vault-authored administrator") unless
  request("/", credentials: credentials).code == "200"

fail_contract("Pinchflat did not persist its database in the declared config root") unless
  File.file?(DATABASE) && File.size?(DATABASE)

puts "pinchflat contract: health, exclusive basic-auth identity, and persisted state hold"
