#!/usr/bin/env ruby
# The upgrade lane's seed-and-verify half for Bindery: a row written through
# Bindery's own HTTP API while the BASE pin is serving, and read back once the
# head pin has opened and migrated the store that row lives in.
#
# usage: bindery-upgrade.rb (seed|verify)
#
# TWO ROWS IN TWO TABLES (#781). A user, and a settings row. One row proves the
# store opened and was not rebuilt; it does not prove a migration that rewrites
# one table kept the others, which is the shape both recorded incidents had --
# #671's migration 47 moved a value between tables and deleted the row it came
# from.
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
#     reconciles. Checked across the whole of roles/bindery/tasks/ rather than
#     its main.yml alone, because that is where a prune would hide: the one
#     DELETE the role issues is against Audiobookshelf's /api/api-keys, in
#     reconcile_audiobookshelf.yml, and reaches no Bindery user at all.
#
# The username carries a random suffix so the row cannot be confused with
# anything the platform authors, and so a re-run against a surviving sandbox
# cannot collide with its own previous seed (a duplicate user is a 500 here,
# not a no-op).
#
# WHY A SETTINGS ROW BESIDE IT, AND WHY A KEY BINDERY HAS NO OPINION ABOUT.
#
# `settings` is a different table reached by a different route, and both halves
# of its shape are demonstrated rather than assumed: roles/bindery reads
# `GET /setting` as a list of {key, value} pairs and writes
# `PUT /setting/<key> {"value": ...}` on every converge, and
# docs/dossier-bindery.md records that PUT as a 200 upsert.
#
# The key is one this platform invents. An observed key such as
# `authors.bulkRefresh` would carry a false-red risk that has already happened
# once on this platform: a version that legitimately drops a setting it no
# longer has is indistinguishable from a migration that lost the row, and this
# lane gates automerge, so that red would land on a Renovate pull request and
# send its reader hunting for corruption. A key no Bindery version has ever
# heard of cannot be dropped for a reason of its own.
#
# The write is SELF-VALIDATING for the reason the Kapowarr seed's rotation is:
# it is read back and refused unless the store actually holds it, so a route
# that has moved, or a key Bindery declines to upsert, fails at seed with a
# message saying so instead of producing a verify that had nothing to check.
#
# THAT SECOND CASE IS NOT HYPOTHETICAL, and this is the one risk on a first
# dispatch worth naming before it is met. Nothing in the tree demonstrates that
# this route accepts an INVENTED key: the platform has only ever written
# `autoGrab.enabled` and `telemetry.enabled` through it, both keys Bindery
# knows, and docs/dossier-bindery.md's "Reproducing the confirmations" lists no
# settings handler among the upstream sources read, so an unknown-key write was
# never probed. What the tree DOES record is that the route is not a blind
# upsert: roles/bindery/tasks/reconcile_audiobookshelf.yml and the dossier both
# confirm `PUT /setting/abs.api_key` answering 403 with a 404 on the GET,
# because secret settings live behind their own route. That is a narrower
# refusal than per-key validation of arbitrary keys -- it says secrets are
# special, not that unknown keys are rejected -- but it is enough that "this
# route upserts anything" is an assumption rather than a finding.
#
# If it turns out to be rejected, or if GET serializes a known-key struct rather
# than dumping the table, this reds at SEED on every Bindery Renovate pull
# request until the key is changed or this half is dropped -- on the very lane
# whose purpose is gating that automerge. The read-back is what makes that a
# loud, named failure at the seed rather than a hollow verify, and the failure
# message below names the 403 so its reader starts in the right place instead of
# hunting a migration that did nothing wrong.
#
# Two roots folders would have been the third table and are not reachable:
# roles/bindery's own verification asserts the root list equals exactly the two
# declared destinations, and it runs inside the upgrade converge.
#
# WHAT VERIFY PROVES, AND WHAT IT DOES NOT. It proves that two rows the base
# image wrote, in two tables, are still there -- the user with the same
# database-assigned id -- after the head image opened the store. It does not
# prove the migration preserved anything this seeder did not write, and it
# cannot: a migration that is lossy only for books is invisible to a lane that
# seeds a user and a setting. That is the second of the three limits issue #773
# states, narrowed rather than closed.

require "fileutils"
require "json"
require "net/http"
require "open3"
require "securerandom"
require "uri"
require "yaml"

READY_TIMEOUT_SECONDS = Integer(ENV.fetch("PLATFORM_BINDERY_READY_TIMEOUT", "120"), 10)
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_BINDERY_PORT'), 10)}")
# tests/integration.sh creates $sandbox/reports at mode 0777 and run_contract
# exports it as PLATFORM_REPORT_ROOT, so this directory exists for the one
# caller there is. The mkdir below is still taken: nothing that runs outside a
# real lane exercises this write, so a caller that set the variable somewhere
# else would find out only after a full base converge.
RECORD = File.join(ENV.fetch("PLATFORM_REPORT_ROOT"), "upgrade-bindery.json")

# The settings key this program owns. Namespaced under a prefix no Bindery
# version uses, so that a version which legitimately retires one of its own
# settings cannot be mistaken here for a migration that lost a row.
SETTING_KEY = "platform.upgradeCanary"

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

def put(path, payload, headers)
  message = Net::HTTP::Put.new(URI.join(BASE, path),
                               headers.merge("Content-Type" => "application/json"))
  message.body = JSON.generate(payload)
  request(message)
end

# The settings list, as roles/bindery reads it on every converge: a list of
# {key, value} pairs, reduced here to the one key this program owns. `nil` means
# absent, which is what a lost row looks like and is reported as such by the
# caller rather than raising here.
def canary_setting(headers, key)
  settings = parsed(get("/api/v1/setting", headers), "settings")
  fail_contract("Bindery did not answer a list of settings") unless settings.is_a?(Array)
  row = settings.find { |entry| entry.is_a?(Hash) && entry["key"] == key }
  row && row["value"]
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

  # The second table. SETTING_KEY is this platform's own, so nothing but a lost
  # row can remove it.
  setting_value = SecureRandom.hex(16)
  written = put("/api/v1/setting/#{SETTING_KEY}", { "value" => setting_value }, headers)
  stored = canary_setting(headers, SETTING_KEY)
  fail_contract(
    "Bindery did not store the canary setting #{SETTING_KEY} (the upsert answered HTTP " \
    "#{written.code} and a read back returned #{stored.inspect}), so this lane would have " \
    "nothing in that table the base image wrote. READ THIS BEFORE BLAMING THE BUMP: the " \
    "generic settings route is known not to be a blind upsert -- PUT /setting/abs.api_key " \
    "answers 403 with a 404 on the GET, because secret settings sit behind their own route " \
    "-- and no probe recorded in docs/dossier-bindery.md has ever written a key Bindery does " \
    "not itself define. So an HTTP 4xx here, or a 200 whose value does not read back, is " \
    "most likely this seeder's invented key being refused or not surfaced by GET /setting, " \
    "not a migration that lost a row. If that is what happened, the fix is to this seed, and " \
    "it is not a reason to hold the image"
  ) unless stored == setting_value

  FileUtils.mkdir_p(File.dirname(RECORD))
  File.write(RECORD, JSON.generate("username" => username, "id" => id,
                                   "setting_value" => setting_value))
  puts "bindery upgrade seed: canary user #{username} stored as id #{id}, and " \
       "#{SETTING_KEY} stored beside it"
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

  # The second table, asserted separately: a migration that rewrites `settings`
  # and leaves `users` alone passes every assertion above it.
  stored = canary_setting(headers, SETTING_KEY)
  fail_contract(
    "the seeded Bindery canary setting #{SETTING_KEY} did not survive the migration: the " \
    "store now holds #{stored.inspect} for that key rather than the value the base image " \
    "wrote. No Bindery version knows this key, so it cannot have been dropped for a reason " \
    "of its own -- the users table above it survived, so this is one table lost and not the " \
    "store"
  ) unless stored == record.fetch("setting_value")
  puts "bindery upgrade verify: canary user #{record.fetch('username')} survived as " \
       "id #{record.fetch('id')}, and #{SETTING_KEY} survived beside it"
end
