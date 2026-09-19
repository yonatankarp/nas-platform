#!/usr/bin/env ruby
# frozen_string_literal: true

# What tests/contracts/<service>-upgrade.rb *does*, proved by running it.
#
# The upgrade lane (#773) is the one lane that does not start from an empty
# store, and the whole of what it proves over the fresh-install lanes comes down
# to two programs: a seed that writes through the service's own HTTP API while
# the base pin is serving, and a verify that reads back after the head pin has
# migrated the store. A lane whose verify cannot fail is a lane that converges
# two versions and asserts nothing -- green, and faster than not having it.
#
# So the evidence here is a REFUSAL, not a passing run. Each service gets a
# happy path and at least one planted loss, and the planted loss must be
# refused. This repository's own history is why: case_pool_locals_test.rb passed
# its own self-test while carrying two bugs, and the shard-partition guard's
# first three plants landed on rows the checker does not read.
#
# The services are stubbed over a real socket rather than mocked, because what
# these programs are is HTTP clients: the shapes they send and the fields they
# read are the thing under test, and a mock would be written from the same
# reading of the API that the program was. What a stub CANNOT do is tell us the
# real Bindery and Kapowarr answer these routes this way -- that comes from
# roles/bindery and roles/kapowarr, which send the same requests on every
# converge, and from the two dossiers, and it is stated in each program's own
# header. This file proves the programs' logic, not the API.

require "json"
require "open3"
require "socket"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)

# No arguments, and `--self-test` in particular is refused rather than ignored.
# Accepting it silently would print this file's ordinary success line in answer
# to a request for its planted-regression proof, which is the vacuous pass this
# repository keeps closing, in miniature. There is no self-test to implement
# here for a reason worth stating: every case below IS a planted loss -- the row
# deleted, the row re-created under another id, the key that did not survive,
# the rotation that changed nothing -- and each requires the program under test
# to refuse. The plants are the body, not a mode.
unless ARGV.empty?
  warn "usage: contract_upgrade_seed_test.rb (no arguments; its cases are already planted losses)"
  exit 2
end

failures = []

def check(failures, condition, message)
  failures << message unless condition
end

# ---------------------------------------------------------------------------
# The subject roster, stated here and closed in both directions.
#
# tests/ci/classify_changes.rb and tests/integration.sh both DERIVE which
# services the upgrade lane can take as a subject, from which ones carry a
# seed-and-verify program. A derivation is the right shape -- it makes adding a
# service one new file rather than two list edits -- but it has the failure
# every derivation has: a list that quietly empties satisfies every loop in
# both readers and reports a pass, with the lane simply never dispatching
# again. So the set is stated once, here, and asserted both ways.
#
# The three properties under it are what stop a subject from being ADDED into a
# silently dead lane, which is a real hazard rather than a hypothetical one:
# the basename of the program is used as three different names at once.
#
#   * services/<name>/compose.yml       -- what the classifier compares pins in
#                                          and what the controller repins
#   * tests/contracts/<name>.sh         -- what run_contract dispatches seed and
#                                          verify through
#   * a manifest service directory      -- what deployment_target_service takes
#
# Those coincide for every service here and for most of the platform, but NOT
# for all of it: paperless-ngx's contract is tests/contracts/paperless.sh, so a
# future paperless-upgrade.rb would name a compose path that does not exist and
# the lane would resolve no subject and never dispatch -- green, and invisible.
# Rather than plumb a name map through a POSIX shell launcher for a case that
# does not exist yet, the divergence is made impossible: a program whose
# basename is not all three of those names fails here, at the gate, before
# anything is wired to it.
EXPECTED_UPGRADE_SUBJECTS = %w[bindery kapowarr].freeze

observed_subjects = Dir.glob(File.join(ROOT, "tests", "contracts", "*-upgrade.rb"))
                       .map { |path| File.basename(path, ".rb").delete_suffix("-upgrade") }
                       .sort
check(failures, observed_subjects == EXPECTED_UPGRADE_SUBJECTS,
      "the upgrade lane's subjects are #{observed_subjects.inspect}, expected " \
      "#{EXPECTED_UPGRADE_SUBJECTS.inspect}: both readers derive this set from the same " \
      "directory, so a subject added or lost without this line moving changes what the lane " \
      "can run with nothing to say so")

# Read out of the suite table rather than imported from the classifier, like
# every other list this repository holds against a reader: importing the
# constant would make this agree with the classifier by construction, and what
# is being asserted is that a subject HAS a lane with tags, not that the
# classifier thinks so. This is the fourth of the four things
# ClassifyChanges.upgrade_subject requires, and it was the one nothing checked:
# dropping its `next unless` left a subject resolving to nil with no diagnostic
# anywhere.
tagged_suite_rows = File.readlines(File.join(ROOT, "tests", "ci", "suites.conf"), chomp: true)
                        .filter_map do |line|
  fields = line.sub(/#.*/, "").split
  next if fields.length != 3
  next unless %w[acquisition service].include?(fields[1])
  next if fields[2] == "-"

  [fields[0], fields[2].split(",")]
end.to_h

manifest_services = YAML.safe_load_file(File.join(ROOT, "services", "manifest.yml"))
                        .fetch("services")
                        .select { |entry| entry["status"] == "implemented" }
                        .map { |entry| entry.fetch("name") }
EXPECTED_UPGRADE_SUBJECTS.each do |subject|
  check(failures, manifest_services.include?(subject),
        "upgrade subject #{subject} is not an implemented service directory in " \
        "services/manifest.yml, so tests/ci/classify_changes.rb would compare pins in a " \
        "services/#{subject}/compose.yml that does not exist and the lane would never dispatch")
  check(failures, File.file?(File.join(ROOT, "services", subject, "compose.yml")),
        "upgrade subject #{subject} has no services/#{subject}/compose.yml to repin")
  check(failures, File.file?(File.join(ROOT, "tests", "contracts", "#{subject}.sh")),
        "upgrade subject #{subject} has no tests/contracts/#{subject}.sh, which is what " \
        "run_contract dispatches its seed and verify through")
  check(failures, tagged_suite_rows.key?(subject),
        "upgrade subject #{subject} is not a tagged row in tests/ci/suites.conf, so the lane " \
        "would have no tags of its own and could only be converged by converging the whole " \
        "site -- which is the idempotence lane's cost for a one-service proof")
end

# Reported and stopped here rather than accumulated, because every case below
# runs one of these programs: an emptied roster otherwise surfaces as an
# Errno::ENOENT backtrace from the first case, which is loud but says nothing
# about the roster that emptied. Measured -- removing both programs did exactly
# that before this exit was added.
unless failures.empty?
  failures.each { |message| warn "FAIL #{message}" }
  warn "#{failures.length} upgrade subject roster failure(s)"
  exit 1
end

# A one-connection-at-a-time HTTP/1.1 server. Enough for two programs that make
# a handful of sequential requests, and small enough to read.
class StubService
  attr_reader :port

  def initialize(&handler)
    @handler = handler
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new { serve }
    @thread.abort_on_exception = false
  end

  def stop
    @server.close
    @thread.kill
  end

  private

  def serve
    loop do
      session = @server.accept
      begin
        request_line = session.gets.to_s.split
        method = request_line[0].to_s
        path = request_line[1].to_s
        length = 0
        while (line = session.gets) && line.strip != ""
          length = Regexp.last_match(1).to_i if line =~ /\AContent-Length:\s*(\d+)/i
        end
        body = length.positive? ? session.read(length) : ""
        status, payload = @handler.call(method, path, body)
        encoded = JSON.generate(payload)
        session.print("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\n" \
                      "Content-Length: #{encoded.bytesize}\r\nConnection: close\r\n\r\n")
        session.print(encoded)
      rescue StandardError
        nil
      ensure
        session.close rescue nil
      end
    end
  rescue IOError, Errno::EBADF
    nil
  end
end

# The programs read the vault through `ansible-vault view`, so the fixture is a
# stub of that command rather than a patched constant: it is how they reach a
# credential in production too.
def install_vault_stub(root, plaintext)
  vault_file = File.join(root, "vault.yml")
  password_file = File.join(root, "vault-password")
  File.write(vault_file, plaintext)
  File.write(password_file, "fixture\n")
  bin = File.join(root, "bin")
  Dir.mkdir(bin)
  stub = File.join(bin, "ansible-vault")
  File.write(stub, <<~STUB)
    #!/bin/sh
    # `view --vault-password-file <file> <vault>` is the one form these programs use.
    exec cat "$4"
  STUB
  File.chmod(0o755, stub)
  [vault_file, password_file, bin]
end

def run_program(service, mode, root, port, extra = {})
  vault_file, password_file, bin = install_vault_stub_cached(root)
  environment = {
    "PATH" => "#{bin}:#{ENV.fetch('PATH')}",
    "PLATFORM_REPORT_ROOT" => root,
    "PLATFORM_CONTRACT_VAULT_FILE" => vault_file,
    "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => password_file,
    "PLATFORM_BINDERY_PORT" => port.to_s,
    "PLATFORM_KAPOWARR_PORT" => port.to_s,
    # The readiness gates default to 120 seconds each. Every stub here answers
    # immediately or not at all, so a wait would only ever be a wait.
    "PLATFORM_BINDERY_READY_TIMEOUT" => "5",
    "PLATFORM_KAPOWARR_READY_TIMEOUT" => "5"
  }.merge(extra)
  Open3.capture3(environment,
                 "ruby", File.join(ROOT, "tests", "contracts", "#{service}-upgrade.rb"), mode)
end

# One vault fixture per sandbox directory, created on first use.
def install_vault_stub_cached(root)
  @vault_stubs ||= {}
  @vault_stubs[root] ||= install_vault_stub(root, <<~VAULT)
    vault_bindery_api_key: fixture-bindery-api-key
    vault_kapowarr_admin_username: fixture-administrator
    vault_kapowarr_admin_password: fixture-password
  VAULT
end

# ---------------------------------------------------------------------------
# Bindery: a canary user, written through the route roles/bindery uses to
# declare its own administrator.
# ---------------------------------------------------------------------------

# `store` is the list of user rows the stub serves, and the cases below are the
# ways a migration can lose one: the row vanishes, or it comes back under a
# different database-assigned id because the store was rebuilt rather than
# migrated.
# `settings` is the second table (#781), served in the shape roles/bindery reads
# on every converge: a list of {key, value} pairs, upserted one key at a time.
# `upserts` is what separates a Bindery that honours the write from one that
# answers 200 and stores nothing -- the seed is required to refuse the second.
def bindery_stub(store, settings: [], next_id: [2], upserts: true)
  StubService.new do |method, path, body|
    route = path.split("?").first
    case [method, route]
    when %w[GET /api/v1/health] then [200, { "status" => "ok" }]
    when %w[GET /api/v1/auth/users] then [200, store]
    when %w[GET /api/v1/setting] then [200, settings]
    when %w[POST /api/v1/auth/users]
      submitted = JSON.parse(body)
      id = next_id[0]
      next_id[0] += 1
      store << { "id" => id, "username" => submitted.fetch("username"),
                 "role" => submitted.fetch("role") }
      [201, { "id" => id }]
    else
      if method == "PUT" && route.start_with?("/api/v1/setting/")
        key = route.delete_prefix("/api/v1/setting/")
        if upserts
          row = settings.find { |entry| entry["key"] == key }
          if row
            row["value"] = JSON.parse(body).fetch("value")
          else
            settings << { "key" => key, "value" => JSON.parse(body).fetch("value") }
          end
        end
        [200, { "key" => key }]
      else
        [404, { "error" => "unexpected #{method} #{path}" }]
      end
    end
  end
end

Dir.mktmpdir("upgrade-seed-bindery-") do |root|
  store = [{ "id" => 1, "username" => "platform", "role" => "admin" }]
  settings = [{ "key" => "autoGrab.enabled", "value" => "false" }]
  service = bindery_stub(store, settings: settings)
  begin
    out, err, status = run_program("bindery", "seed", root, service.port)
    check(failures, status.success?, "bindery seed failed: #{err}#{out}")
    check(failures, out.include?("canary user"), "bindery seed reported nothing: #{out}")
    seeded = JSON.parse(File.read(File.join(root, "upgrade-bindery.json")))
    check(failures, store.any? { |user| user["username"] == seeded["username"] },
          "bindery seed wrote no row into the store")
    canary = settings.find { |entry| entry["key"] == "platform.upgradeCanary" }
    check(failures, canary && canary["value"] == seeded["setting_value"],
          "bindery seed wrote no settings row into the store")

    _out, _err, status = run_program("bindery", "verify", root, service.port)
    check(failures, status.success?, "bindery verify refused a store that kept the row")

    # THE PLANT. A migration that runs and drops the row is the failure this
    # lane exists for, and it is invisible to every other lane in the
    # repository.
    store.reject! { |user| user["username"] == seeded["username"] }
    _out, lost_error, status = run_program("bindery", "verify", root, service.port)
    check(failures, !status.success?,
          "bindery verify ACCEPTED a store that lost the seeded row")
    check(failures, lost_error.include?("did not survive the migration"),
          "bindery verify refused a lost row without naming it: #{lost_error}")

    # The second loss, and the one a presence check alone would miss: the row is
    # there, but it is a different row. Nothing in this platform re-creates this
    # user, so a changed id means the store was rebuilt rather than migrated.
    store << { "id" => 99, "username" => seeded.fetch("username"), "role" => "admin" }
    _out, renumbered_error, status = run_program("bindery", "verify", root, service.port)
    check(failures, !status.success?,
          "bindery verify ACCEPTED a re-created row under a different id")
    check(failures, renumbered_error.include?("rather than"),
          "bindery verify refused a re-created row without naming the id: #{renumbered_error}")

    # THE THIRD LOSS, and the one a single-table seed cannot see (#781): the
    # users table is intact and the settings table is not. Restored to the
    # passing state first -- the two plants above deleted the seeded row and
    # then re-created it under another id -- so the refusal below can only be
    # the settings row.
    store.reject! { |user| user["username"] == seeded.fetch("username") }
    store << { "id" => seeded.fetch("id"), "username" => seeded.fetch("username"),
               "role" => "admin" }
    _out, _err, status = run_program("bindery", "verify", root, service.port)
    check(failures, status.success?,
          "bindery verify refused a store that kept both rows")
    settings.reject! { |entry| entry["key"] == "platform.upgradeCanary" }
    _out, setting_error, status = run_program("bindery", "verify", root, service.port)
    check(failures, !status.success?,
          "bindery verify ACCEPTED a store that kept the user and lost the setting")
    check(failures, setting_error.include?("platform.upgradeCanary did not survive"),
          "bindery verify refused a lost setting without naming it: #{setting_error}")
  ensure
    service.stop
  end
end

# The settings write's own self-validation, which is what keeps the seed from
# recording a value it never wrote: an upsert route that answers 200 and stores
# nothing must fail the seed rather than leave the verify with nothing to check.
Dir.mktmpdir("upgrade-seed-bindery-inert-") do |root|
  service = bindery_stub([{ "id" => 1, "username" => "platform", "role" => "admin" }],
                         upserts: false)
  begin
    _out, inert_error, status = run_program("bindery", "seed", root, service.port)
    check(failures, !status.success?,
          "bindery seed ACCEPTED an upsert route that stored nothing")
    check(failures, inert_error.include?("did not store the canary setting"),
          "bindery seed refused an inert upsert without naming it: #{inert_error}")
    check(failures, !File.exist?(File.join(root, "upgrade-bindery.json")),
          "bindery seed recorded a setting it never wrote")
  ensure
    service.stop
  end
end

# ---------------------------------------------------------------------------
# Kapowarr: the application-generated API key, which the platform provably
# cannot author and therefore cannot put back.
# ---------------------------------------------------------------------------

# `key` is the value a login returns. `rotates` is what separates a Kapowarr
# that honours POST /api/settings/api_key from one that does not -- the seed is
# required to refuse the second, because a seed that recorded an unrotated key
# would be recording a value it never wrote.
def kapowarr_stub(key, rotates: true)
  StubService.new do |method, path, body|
    route = path.split("?").first
    case [method, route]
    when %w[GET /api/public]
      [200, { "result" => { "authentication_method" => 2 } }]
    when %w[POST /api/auth]
      submitted = JSON.parse(body.empty? ? "{}" : body)
      if submitted["username"] == "fixture-administrator" &&
         submitted["password"] == "fixture-password"
        [200, { "result" => { "api_key" => key[0] } }]
      else
        [401, { "error" => "PasswordInvalid" }]
      end
    when %w[POST /api/settings/api_key]
      key[0] = format("%032x", rand(2**128)) if rotates
      [200, { "result" => { "api_key" => key[0] } }]
    else [404, { "error" => "unexpected #{method} #{path}" }]
    end
  end
end

Dir.mktmpdir("upgrade-seed-kapowarr-") do |root|
  key = ["0" * 32]
  service = kapowarr_stub(key)
  begin
    before = key[0]
    out, err, status = run_program("kapowarr", "seed", root, service.port)
    check(failures, status.success?, "kapowarr seed failed: #{err}#{out}")
    check(failures, key[0] != before, "kapowarr seed did not rotate the stored key")

    _out, _err, status = run_program("kapowarr", "verify", root, service.port)
    check(failures, status.success?, "kapowarr verify refused a store that kept the key")

    # THE PLANT: the head image opened a store it could not carry, so the value
    # the base image wrote is gone and a login answers something else.
    key[0] = "f" * 32
    _out, rebuilt_error, status = run_program("kapowarr", "verify", root, service.port)
    check(failures, !status.success?,
          "kapowarr verify ACCEPTED a store whose API key did not survive")
    check(failures, rebuilt_error.include?("did not survive the migration"),
          "kapowarr verify refused a lost key without naming it: #{rebuilt_error}")
  ensure
    service.stop
  end
end

# The seed's own self-validation, which is what lets that program depend on no
# response shape at all: a rotation route that answers 200 and changes nothing
# must fail the seed rather than record a key it never wrote.
Dir.mktmpdir("upgrade-seed-kapowarr-inert-") do |root|
  service = kapowarr_stub(["a" * 32], rotates: false)
  begin
    _out, inert_error, status = run_program("kapowarr", "seed", root, service.port)
    check(failures, !status.success?,
          "kapowarr seed ACCEPTED a rotation route that changed nothing")
    check(failures, inert_error.include?("did not rotate"),
          "kapowarr seed refused an inert rotation without naming it: #{inert_error}")
    check(failures, !File.exist?(File.join(root, "upgrade-kapowarr.json")),
          "kapowarr seed recorded a key it never rotated")
  ensure
    service.stop
  end
end

# Both programs refuse a mode they do not implement, and a verify with no seed
# record: a verify that treated a missing record as nothing to check would be
# the same green-proving-nothing lane in miniature.
Dir.mktmpdir("upgrade-seed-modes-") do |root|
  %w[bindery kapowarr].each do |service_name|
    _out, mode_error, status = run_program(service_name, "run", root, 1)
    check(failures, !status.success?, "#{service_name} upgrade accepted an unknown mode")
    check(failures, mode_error.include?("expected seed or verify"),
          "#{service_name} upgrade refused an unknown mode without naming it: #{mode_error}")
  end
end

Dir.mktmpdir("upgrade-seed-recordless-") do |root|
  store = [{ "id" => 1, "username" => "platform", "role" => "admin" }]
  service = bindery_stub(store)
  begin
    _out, recordless_error, status = run_program("bindery", "verify", root, service.port)
    check(failures, !status.success?, "bindery verify ACCEPTED a run with no seed record")
    check(failures, recordless_error.include?("no Bindery upgrade seed record"),
          "bindery verify refused a missing record without naming it: #{recordless_error}")
  ensure
    service.stop
  end
end

if failures.empty?
  puts "upgrade seed-and-verify contracts: every planted loss was refused"
else
  failures.each { |message| warn "FAIL #{message}" }
  warn "#{failures.length} upgrade seed-and-verify failure(s)"
  exit 1
end
