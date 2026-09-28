#!/usr/bin/env ruby
# frozen_string_literal: true

# Runs tests/contracts/<service>-upgrade.rb seed and verify against stub services
# over a real socket; every case is a planted loss the program must refuse (#773).

require "json"
require "open3"
require "socket"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)

# No arguments: every case below already is a planted loss, so --self-test is refused.
unless ARGV.empty?
  warn "usage: contract_upgrade_seed_test.rb (no arguments; its cases are already planted losses)"
  exit 2
end

failures = []

def check(failures, condition, message)
  failures << message unless condition
end

# The subject roster, stated and closed both ways, because the classifier and
# integration.sh derive it and an emptied derivation passes silently. Each
# basename must also be a services/ dir, a contracts .sh and a manifest dir.
EXPECTED_UPGRADE_SUBJECTS = %w[bindery kapowarr].freeze

observed_subjects = Dir.glob(File.join(ROOT, "tests", "contracts", "*-upgrade.rb"))
                       .map { |path| File.basename(path, ".rb").delete_suffix("-upgrade") }
                       .sort
check(failures, observed_subjects == EXPECTED_UPGRADE_SUBJECTS,
      "the upgrade lane's subjects are #{observed_subjects.inspect}, expected " \
      "#{EXPECTED_UPGRADE_SUBJECTS.inspect}: both readers derive this set from the same " \
      "directory, so a subject added or lost without this line moving changes what the lane " \
      "can run with nothing to say so")

# Read from the suite table, not imported from the classifier, so this is not
# agreement by construction.
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

# Stop here: every case below runs one of these programs.
unless failures.empty?
  failures.each { |message| warn "FAIL #{message}" }
  warn "#{failures.length} upgrade subject roster failure(s)"
  exit 1
end

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

# The programs read the vault through `ansible-vault view`, so that command is stubbed.
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
    "PLATFORM_BINDERY_READY_TIMEOUT" => "5",
    "PLATFORM_KAPOWARR_READY_TIMEOUT" => "5"
  }.merge(extra)
  Open3.capture3(environment,
                 "ruby", File.join(ROOT, "tests", "contracts", "#{service}-upgrade.rb"), mode)
end

def install_vault_stub_cached(root)
  @vault_stubs ||= {}
  @vault_stubs[root] ||= install_vault_stub(root, <<~VAULT)
    vault_bindery_api_key: fixture-bindery-api-key
    vault_kapowarr_admin_username: fixture-administrator
    vault_kapowarr_admin_password: fixture-password
  VAULT
end

# Bindery: a canary user, written through the route roles/bindery uses.

# `store` is the user rows the stub serves.
def bindery_stub(store, next_id: [2])
  StubService.new do |method, path, body|
    case [method, path.split("?").first]
    when %w[GET /api/v1/health] then [200, { "status" => "ok" }]
    when %w[GET /api/v1/auth/users] then [200, store]
    when %w[POST /api/v1/auth/users]
      submitted = JSON.parse(body)
      id = next_id[0]
      next_id[0] += 1
      store << { "id" => id, "username" => submitted.fetch("username"),
                 "role" => submitted.fetch("role") }
      [201, { "id" => id }]
    else [404, { "error" => "unexpected #{method} #{path}" }]
    end
  end
end

Dir.mktmpdir("upgrade-seed-bindery-") do |root|
  store = [{ "id" => 1, "username" => "platform", "role" => "admin" }]
  service = bindery_stub(store)
  begin
    out, err, status = run_program("bindery", "seed", root, service.port)
    check(failures, status.success?, "bindery seed failed: #{err}#{out}")
    check(failures, out.include?("canary user"), "bindery seed reported nothing: #{out}")
    seeded = JSON.parse(File.read(File.join(root, "upgrade-bindery.json")))
    check(failures, store.any? { |user| user["username"] == seeded["username"] },
          "bindery seed wrote no row into the store")

    _out, _err, status = run_program("bindery", "verify", root, service.port)
    check(failures, status.success?, "bindery verify refused a store that kept the row")

    # THE PLANT: the migration dropped the row.
    store.reject! { |user| user["username"] == seeded["username"] }
    _out, lost_error, status = run_program("bindery", "verify", root, service.port)
    check(failures, !status.success?,
          "bindery verify ACCEPTED a store that lost the seeded row")
    check(failures, lost_error.include?("did not survive the migration"),
          "bindery verify refused a lost row without naming it: #{lost_error}")

    # Same username, different id: the store was rebuilt rather than migrated.
    store << { "id" => 99, "username" => seeded.fetch("username"), "role" => "admin" }
    _out, renumbered_error, status = run_program("bindery", "verify", root, service.port)
    check(failures, !status.success?,
          "bindery verify ACCEPTED a re-created row under a different id")
    check(failures, renumbered_error.include?("rather than"),
          "bindery verify refused a re-created row without naming the id: #{renumbered_error}")
  ensure
    service.stop
  end
end

# Kapowarr: the application-generated API key, which the platform cannot author.

# `rotates: false` is a Kapowarr ignoring POST /api/settings/api_key; the seed must refuse it.
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

    # THE PLANT: the stored key is gone after the head image opened the store.
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

# Both programs refuse unknown modes and a verify with no seed record.
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
