#!/usr/bin/env ruby
# The runtime half of the Pinchflat service contract: what only a deployed
# Pinchflat can answer -- its health, that its interface admits exactly the
# vault-authored administrator and nobody else, and that its state landed in
# the declared config root.
#
# usage: pinchflat-runtime.rb
#
# Takes no arguments. Its whole input is the environment
# tests/contracts/pinchflat.sh exports: PLATFORM_PINCHFLAT_PORT,
# PLATFORM_PINCHFLAT_CONTAINER, PLATFORM_DOCKER_ROOT and the two
# PLATFORM_CONTRACT_VAULT_* paths. On failure it writes one
# `Pinchflat contract failed: ...` line to stderr and exits 1.
#
# Until #147 this was a `<<'RUBY'` heredoc inside tests/contracts/pinchflat.sh,
# invisible to every static check and reachable by no test short of a full
# integration lane. The body below is byte-identical to what that heredoc
# rendered; the heredoc carried no `-r` preloads and no arguments, so neither
# does the invocation that replaced it.
require "json"
require "net/http"
require "open3"
require "timeout"
require "uri"
require "yaml"

READY_TIMEOUT_SECONDS = 120
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_PINCHFLAT_PORT'), 10)}")
CONTAINER = ENV.fetch("PLATFORM_PINCHFLAT_CONTAINER")
# Pinchflat's whole state is one SQLite database beneath the declared config
# root. It is what has to survive a container recreation, and its absence is
# what a wrongly owned or wrongly mounted config bind looks like.
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

# The interface is the writer, so all three outcomes are asserted: refused with
# no credential, refused with the wrong one, accepted with exactly the vault's.
fail_contract("Pinchflat served its interface to an anonymous request") unless
  request("/").code == "401"
fail_contract("Pinchflat served its interface to a wrong password") unless
  request("/", credentials: [credentials.first, "contract-wrong-password"]).code == "401"
fail_contract("Pinchflat refused the vault-authored administrator") unless
  request("/", credentials: credentials).code == "200"

fail_contract("Pinchflat did not persist its database in the declared config root") unless
  File.file?(DATABASE) && File.size?(DATABASE)

puts "pinchflat contract: health, exclusive basic-auth identity, and persisted state hold"
