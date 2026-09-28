#!/usr/bin/env ruby
# The upgrade lane's seed-and-verify half for Bindery: a user written through the API
# under the BASE pin, read back after the head pin migrated the store.
#
# usage: bindery-upgrade.rb (seed|verify)
#
# A user because roles/bindery POSTs this exact shape and never deletes users, so the
# row survives the second converge. A settings canary was tried (#785) and refused:
# PUT /setting/<unknown key> answers 400. The random suffix avoids colliding with a
# previous seed (a duplicate user is a 500). Proves only the seeded row survived (#773).

require "fileutils"
require "json"
require "net/http"
require "open3"
require "securerandom"
require "uri"
require "yaml"

READY_TIMEOUT_SECONDS = Integer(ENV.fetch("PLATFORM_BINDERY_READY_TIMEOUT", "120"), 10)
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_BINDERY_PORT'), 10)}")
# tests/integration.sh creates this directory; the mkdir below is kept for other callers.
RECORD = File.join(ENV.fetch("PLATFORM_REPORT_ROOT"), "upgrade-bindery.json")

def fail_contract(message)
  warn "Bindery upgrade contract failed: #{message}"
  exit 1
end

mode = ARGV[0]
fail_contract("expected seed or verify, got #{mode.inspect}") unless
  %w[seed verify].include?(mode)

def request(message)
  Net::HTTP.start(BASE.host, BASE.port, read_timeout: 15) { |http| http.request(message) }
end

def get(path, headers)
  request(Net::HTTP::Get.new(URI.join(BASE, path), headers))
end

def post(path, payload, headers)
  message = Net::HTTP::Post.new(URI.join(BASE, path),
                                headers.merge("Content-Type" => "application/json"))
  message.body = JSON.generate(payload)
  request(message)
end

def parsed(response, what)
  JSON.parse(response.body)
rescue JSON::ParserError
  fail_contract("Bindery did not answer JSON for #{what}")
end

# An upgrade converge returns on healthy; the API answers a moment later.
def wait_for_readiness
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READY_TIMEOUT_SECONDS
  loop do
    begin
      return if get("/api/v1/health", {}).code == "200"
    rescue StandardError
      nil
    end
    fail_contract("Bindery never answered its health endpoint") if
      Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    sleep 2
  end
end

# The vault's key, not the service's: a service holding another one is a finding.
def vault_api_key
  yaml, error, status = Open3.capture3(
    "ansible-vault", "view", "--vault-password-file",
    ENV.fetch("PLATFORM_CONTRACT_VAULT_PASSWORD_FILE"),
    ENV.fetch("PLATFORM_CONTRACT_VAULT_FILE")
  )
  fail_contract("encrypted vault could not be read") unless status.success?
  vault = YAML.safe_load(yaml)
  yaml.replace("\0" * yaml.bytesize)
  error.replace("\0" * error.bytesize)
  vault.fetch("vault_bindery_api_key")
end

wait_for_readiness
headers = { "X-Api-Key" => vault_api_key }

case mode
when "seed"
  username = "upgrade-canary-#{SecureRandom.hex(8)}"
  password = SecureRandom.hex(24)
  created = post("/api/v1/auth/users",
                 { "username" => username, "password" => password, "role" => "admin" },
                 headers)
  fail_contract("Bindery refused the seeded canary user (HTTP #{created.code})") unless
    created.code == "201"
  # Read back from the listing, which is what a later listing must match.
  users = parsed(get("/api/v1/auth/users", headers), "users")
  seeded = users.select { |user| user["username"] == username }
  fail_contract("Bindery did not store exactly one canary user") unless seeded.length == 1
  id = seeded.first["id"]
  fail_contract("Bindery assigned the canary user no id") if id.nil?
  FileUtils.mkdir_p(File.dirname(RECORD))
  File.write(RECORD, JSON.generate("username" => username, "id" => id))
  puts "bindery upgrade seed: canary user #{username} stored as id #{id}"
when "verify"
  fail_contract("no Bindery upgrade seed record at #{RECORD}") unless File.file?(RECORD)

  record = JSON.parse(File.read(RECORD))
  users = parsed(get("/api/v1/auth/users", headers), "users")
  survivors = users.select { |user| user["username"] == record.fetch("username") }
  fail_contract(
    "the seeded Bindery canary user #{record.fetch('username')} did not survive the " \
    "migration: the store now holds #{survivors.length} row(s) with that username, out of " \
    "#{users.length} user(s) in total"
  ) unless survivors.length == 1
  # Nothing re-creates this user, so a changed id means the store was rebuilt.
  fail_contract(
    "the seeded Bindery canary user survived under id #{survivors.first['id']} rather than " \
    "#{record.fetch('id')}, so the store was rebuilt rather than migrated"
  ) unless survivors.first["id"] == record.fetch("id")
  puts "bindery upgrade verify: canary user #{record.fetch('username')} survived as " \
       "id #{record.fetch('id')}"
end
