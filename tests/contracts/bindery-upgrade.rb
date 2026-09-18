#!/usr/bin/env ruby
# The upgrade lane's seed-and-verify half for Bindery: a row written through
# Bindery's own HTTP API while the BASE pin is serving, and read back once the
# head pin has opened and migrated the store that row lives in.
#
# usage: bindery-upgrade.rb (seed|verify)
#
# WHY A USER, AND WHY THIS ROUTE.
#
# The seed has to satisfy three things at once, and most of Bindery's surface
# fails one of them. It must be a real row in bindery.db, so that a migration
# that runs and loses data is observable at all. It must survive the SECOND
# converge, or the assertion cannot tell a surviving row from a re-created one.
# And its request shape must be known to work at the pinned version, because a
# seeder that guesses reds the lane for its own reasons and teaches nobody
# anything.
#
#   * roles/bindery/tasks/main.yml POSTs exactly this body to exactly this route
#     on every converge, to declare the vault-authored administrator, and
#     docs/dossier-bindery.md records the same call answering 201 against a live
#     container. So the shape is demonstrated rather than assumed.
#   * That role creates a user only when the read above it proves the identity
#     missing, and it deletes none. An extra user is therefore left exactly as
#     found by the converge that follows -- unlike root folders, settings, the
#     Prowlarr instance and the download client, every one of which the role
#     reconciles.
#
# The username carries a random suffix so the row cannot be confused with
# anything the platform authors, and so a re-run against a surviving sandbox
# cannot collide with its own previous seed (a duplicate user is a 500 here,
# not a no-op).
#
# WHAT VERIFY PROVES, AND WHAT IT DOES NOT. It proves that a row the base image
# wrote is still there, with the same database-assigned id, after the head image
# opened the store. It does not prove the migration preserved anything this
# seeder did not write, and it cannot: a migration that is lossy only for books
# is invisible to a lane that seeds a user. That is the second of the three
# limits issue #773 states, narrowed rather than closed.

require "json"
require "net/http"
require "open3"
require "securerandom"
require "uri"
require "yaml"

READY_TIMEOUT_SECONDS = Integer(ENV.fetch("PLATFORM_BINDERY_READY_TIMEOUT", "120"), 10)
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_BINDERY_PORT'), 10)}")
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

# The same gate the runtime contract uses. An upgrade converge returns as soon as
# Compose reports the container healthy, and the API is reachable a moment later.
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

# The key roles/bindery seeds through BINDERY_API_KEY and resolve_api_key.yml
# reads back. Taken from the vault rather than from the running service for the
# same reason the role prefers it: it is the value the platform authored, so a
# service holding a different one is a finding rather than something to work
# around here.
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
  # The id is read back from the listing rather than from the create response,
  # so the record holds what a later listing has to match rather than what the
  # create happened to echo.
  users = parsed(get("/api/v1/auth/users", headers), "users")
  seeded = users.select { |user| user["username"] == username }
  fail_contract("Bindery did not store exactly one canary user") unless seeded.length == 1
  id = seeded.first["id"]
  fail_contract("Bindery assigned the canary user no id") if id.nil?
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
  # The id is what separates a surviving row from a re-created one. Nothing in
  # this platform re-creates this user -- the role only ever declares its own
  # administrator -- so a changed id means the store was rebuilt rather than
  # migrated.
  fail_contract(
    "the seeded Bindery canary user survived under id #{survivors.first['id']} rather than " \
    "#{record.fetch('id')}, so the store was rebuilt rather than migrated"
  ) unless survivors.first["id"] == record.fetch("id")
  puts "bindery upgrade verify: canary user #{record.fetch('username')} survived as " \
       "id #{record.fetch('id')}"
end
