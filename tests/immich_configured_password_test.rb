#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "timeout"
require "tmpdir"
require "yaml"

require_relative "policy_support"
require_relative "http_fixture_support"

include HttpFixtureSupport
include TestScaffold

TASK_FILE = File.join(ROOT, "roles", "immich", "tasks", "configured_password.yml")
TOKEN = "configured-password-fixture-token"
MUTATION_METHODS = %w[POST PUT PATCH DELETE].freeze
FORBIDDEN_BODY_KEYS = %w[password isAdmin].freeze
# A hang bound, not a performance assertion: the gate's pool runs checks
# concurrently, so boots are slow under load (#462). Overridable.
PLAYBOOK_TIMEOUT_SECONDS = Float(ENV.fetch("IMMICH_PLAYBOOK_TIMEOUT", "120"))

class FixtureTimeout < StandardError; end

ADMIN_ID = "11111111-1111-4111-8111-111111111111"
READER_ID = "22222222-2222-4222-8222-222222222222"
EDITOR_ID = "33333333-3333-4333-8333-333333333333"
UNMANAGED_ID = "44444444-4444-4444-8444-444444444444"
REPLACEMENT_READER_ID = "55555555-5555-4555-8555-555555555555"

MANAGED_USERS = [
  { "email" => "reader@example.invalid", "password" => "reader-password" },
  { "email" => "editor@example.invalid", "password" => "editor-password" }
].freeze

def user(id, email, admin:, should_change_password: true)
  {
    "id" => id,
    "email" => email,
    "status" => "active",
    "deletedAt" => nil,
    "isAdmin" => admin,
    "shouldChangePassword" => should_change_password
  }
end

def complete_users
  [
    user(ADMIN_ID, "Admin@Example.Invalid", admin: true),
    user(READER_ID, " reader@example.invalid ", admin: false),
    user(EDITOR_ID, "EDITOR@example.invalid", admin: false),
    user(UNMANAGED_ID, "unmanaged@example.invalid", admin: false)
  ]
end

# The most bytes one stream of one capture may accumulate before the capture is
# abandoned. A bare `read` runs to EOF, so a child that never stops writing is
# read into this process in its entirety, and the timeout below does not bound
# that -- it bounds how long the child lives, and a runaway emits gigabytes in
# the seconds it is given. A per-check prefix would be wrong here the way it is
# right for the playbook timeouts: the right timeout depends on how long one
# fixture takes and the right memory bound does not, so all four copies of this
# helper read one environment input. The largest healthy capture measured across
# the fifty-nine these four checks make was 6151 bytes; 8 MiB is over a thousand
# times that, and small enough that eight concurrent captures cannot matter.
CAPTURE_LIMIT_BYTES = Integer(ENV.fetch("FIXTURE_CAPTURE_LIMIT_BYTES", "8388608"))

class FixtureCaptureOverflow < StandardError; end

def terminate_process_group(pid, signal)
  Process.kill(signal, -pid)
rescue Errno::ESRCH
  nil
end

# Closing the stream at the limit is the half that bounds memory in real time:
# the reader stops at limit + 1 bytes and the producer takes EPIPE on its next
# write rather than going on filling a pipe nobody drains. The + 1 is what
# distinguishes a capture that filled the limit exactly from one that overran
# it. Returning the bytes rather than raising here is deliberate; the caller
# below says why.
def bounded_capture(stream, limit_bytes)
  bytes = stream.read(limit_bytes + 1) || ""
  stream.close if bytes.bytesize > limit_bytes
  bytes
end

# Every join on the timeout path is bounded: a grandchild that left the process
# group can hold the pipe open forever. report_on_exception is off because the
# parked readers die with IOError when popen3 closes the pipe (#470).
def capture3_with_timeout(environment, *command, chdir:, timeout_seconds:,
                          capture_limit_bytes: CAPTURE_LIMIT_BYTES)
  Open3.popen3(environment, *command, chdir: chdir, pgroup: true) do |stdin, stdout, stderr, wait_thread|
    stdin.close
    stdout_reader = Thread.new { bounded_capture(stdout, capture_limit_bytes) }
    stderr_reader = Thread.new { bounded_capture(stderr, capture_limit_bytes) }
    stdout_reader.report_on_exception = false
    stderr_reader.report_on_exception = false
    begin
      status = Timeout.timeout(timeout_seconds) { wait_thread.value }
    rescue Timeout::Error
      terminate_process_group(wait_thread.pid, "TERM")
      unless wait_thread.join(1)
        terminate_process_group(wait_thread.pid, "KILL")
        wait_thread.join(1)
      end
      stdout_reader.join(1)
      stderr_reader.join(1)
      unit = timeout_seconds == 1 ? "second" : "seconds"
      raise FixtureTimeout, "Ansible fixture timed out after #{timeout_seconds} #{unit}"
    end
    # Overflow is reported from here rather than raised inside a reader thread on
    # purpose: the timeout path above joins those threads and Thread#join
    # re-raises as Thread#value does, so an exception raised inside a reader
    # would surface there in place of FixtureTimeout. This is the only path that
    # consumes the output; the timeout path discards it.
    captured = { "stdout" => stdout_reader.value, "stderr" => stderr_reader.value }
    overrun = captured.select { |_stream, bytes| bytes.bytesize > capture_limit_bytes }.keys
    unless overrun.empty?
      raise FixtureCaptureOverflow,
            "Ansible fixture #{overrun.join(' and ')} exceeded the " \
            "#{capture_limit_bytes}-byte capture limit"
    end
    [captured.fetch("stdout"), captured.fetch("stderr"), status]
  end
end

def run_configured_password(port, phases, *arguments,
                            timeout_seconds: PLAYBOOK_TIMEOUT_SECONDS)
  variables = {
    "immich_api" => "http://127.0.0.1:#{port}/api",
    "vault_immich_admin_email" => "admin@example.invalid",
    "vault_immich_admin_password" => "admin-password",
    "vault_managed_immich_users" => MANAGED_USERS,
    "immich_configured_password_token" => TOKEN
  }
  tasks = phases.map do |phase|
    {
      "name" => "Exercise configured-password #{phase}",
      "ansible.builtin.include_tasks" => TASK_FILE,
      "vars" => { "immich_configured_password_phase" => phase }
    }
  end
  playbook = [{
    "hosts" => "localhost", "gather_facts" => false,
    "vars" => variables, "tasks" => tasks
  }]

  Dir.mktmpdir("nas-platform-immich-configured-password-") do |directory|
    path = File.join(directory, "playbook.yml")
    File.write(path, YAML.dump(playbook), mode: "w", perm: 0o600)
    capture3_with_timeout(
      { "ANSIBLE_NOCOLOR" => "1" }, "ansible-playbook", "-i", "localhost,",
      "-c", "local", path, *arguments, chdir: ROOT,
      timeout_seconds: timeout_seconds
    )
  end
end

def send_response(status, response)
  [status, JSON.generate(response)]
end

# Unwind bound for the blocked fixture; outlasting it is a fault, not a kill.
BLOCKED_JOIN_SECONDS = 5

# Reads the request and answers nothing, so the refusal case is deterministic.
# Not with_http_fixture: writing to a SIGKILLed peer raises EPIPE and flakes.
def with_blocked_immich_fixture
  server = TCPServer.new("127.0.0.1", 0)
  shutdown_reader, shutdown_writer = IO.pipe
  error = nil
  thread = Thread.new do
    Thread.current.report_on_exception = false
    loop do
      ready = IO.select([server, shutdown_reader], nil, nil, 0.05)
      next unless ready
      break if ready.first.include?(shutdown_reader)

      socket = server.accept
      begin
        socket.gets
        HttpFixtureSupport.read_headers(socket)
        IO.select([shutdown_reader], nil, nil, nil)
      ensure
        socket.close unless socket.closed?
      end
    end
  # A peer signalled mid-request is the case under test, not a fixture fault.
  rescue IOError, Errno::EBADF, Errno::ECONNRESET, Errno::EPIPE
    nil
  rescue StandardError => caught
    error = caught
  end

  yield server.addr.fetch(1)
ensure
  begin
    shutdown_writer&.write("x")
  rescue IOError, Errno::EPIPE
    nil
  end
  shutdown_writer&.close unless shutdown_writer&.closed?
  server&.close unless server&.closed?
  if thread && !thread.join(BLOCKED_JOIN_SECONDS)
    thread.kill
    thread.join
    error ||= HttpFixtureSupport::FixtureError.new(
      "blocked Immich fixture thread did not stop within #{BLOCKED_JOIN_SECONDS}s"
    )
  end
  shutdown_reader&.close unless shutdown_reader&.closed?
  raise error if error
end

def with_immich_users(initial_users, persist_patches: true, replace_after_patches: nil,
                      blocked: false, &block)
  users = Marshal.load(Marshal.dump(initial_users))
  requests = []
  return with_blocked_immich_fixture { |port| block.call(port, requests, users) } if blocked

  patch_count = 0
  replacement_pending = false
  with_http_fixture(->(port) { block.call(port, requests, users) },
                    reason: "Fixture") do |method, target, headers, body|
    parsed = body.empty? ? nil : JSON.parse(body)
    request = {
      "method" => method, "target" => target, "headers" => headers, "json" => parsed
    }
    requests << request

    authorized = headers["authorization"] == "Bearer #{TOKEN}"
    if authorized && method == "GET" && target == "/api/admin/users?withDeleted=true"
      if replacement_pending
        record = users.find { |candidate| candidate["id"] == replace_after_patches.fetch("id") }
        record.replace(replace_after_patches.fetch("replacement"))
        replacement_pending = false
      end
      send_response(200, users)
    elsif authorized && method == "PATCH" &&
          (match = target.match(
            %r{\A/api/admin/users/([0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})\z}
          ))
      id = match[1]
      record = users.find { |candidate| candidate["id"] == id }
      if record && parsed == { "shouldChangePassword" => false }
        response_record = record.merge("shouldChangePassword" => false)
        record["shouldChangePassword"] = false if persist_patches
        patch_count += 1
        replacement_pending = true if replace_after_patches && patch_count == 3
        send_response(200, response_record)
      else
        send_response(400, { "message" => "invalid configured-password patch" })
      end
    else
      send_response(400, { "message" => "unexpected fixture request" })
    end
  end
end

def patches(requests)
  requests.select { |request| request["method"] == "PATCH" }
end

def mutations(requests)
  requests.select { |request| MUTATION_METHODS.include?(request["method"]) }
end

def contains_forbidden_body_key?(value)
  case value
  when Hash
    value.keys.any? { |key| FORBIDDEN_BODY_KEYS.include?(key.to_s) } ||
      value.values.any? { |nested| contains_forbidden_body_key?(nested) }
  when Array
    value.any? { |nested| contains_forbidden_body_key?(nested) }
  else
    false
  end
end

def check_no_mutation(failures, requests, message)
  failures << message unless mutations(requests).empty?
end

failures = []

# The capture limit is the only bound on how much of a runaway child this process
# reads, and nothing else here exercises it: every fixture below emits
# single-digit kilobytes. `yes` never stops writing, so a capture that read to
# EOF would sit here until its timeout instead of refusing -- which is what
# removing the cap turns this check into, a FixtureTimeout rather than a pass.
# The limit is injected rather than set through the environment so the child
# stays cheap, and ten seconds is a hang bound rather than a budget: overflow is
# detected the moment the child has emitted limit + 1 bytes, under any load.
overflow = begin
  capture3_with_timeout({}, "sh", "-c", "yes capture-overflow", chdir: ROOT,
                        timeout_seconds: 10, capture_limit_bytes: 2048)
  nil
rescue FixtureCaptureOverflow, FixtureTimeout => error
  error
end
check(failures, overflow.is_a?(FixtureCaptureOverflow) &&
                overflow.message.include?("stdout exceeded the 2048-byte capture limit"),
      "a capture past its limit was not refused as an overflow: #{overflow.inspect}")
captured_request_sets = []

with_immich_users(complete_users) do |port, requests, users|
  captured_request_sets << requests
  stdout, stderr, status = run_configured_password(port, ["reconcile"])
  failures << "initial reconciliation failed: #{failure_tail(stdout + stderr, 12)}" unless status.success?

  lifecycle_mutations = mutations(requests)
  expected_targets = [ADMIN_ID, READER_ID, EDITOR_ID].map do |id|
    ["PATCH", "/api/admin/users/#{id}"]
  end
  failures << "configured true users did not receive exactly one PATCH each" unless
    lifecycle_mutations.map { |request| request.values_at("method", "target") }.sort ==
      expected_targets.sort
  failures << "configured-password PATCH was not the exact minimal false projection" if
    lifecycle_mutations.any? do |request|
      !request["json"].is_a?(Hash) || request["json"] != { "shouldChangePassword" => false }
    end
  last_patch_index = requests.rindex { |request| request["method"] == "PATCH" }
  final_listing_index = requests.rindex do |request|
    request.values_at("method", "target") == ["GET", "/api/admin/users?withDeleted=true"]
  end
  failures << "initial reconciliation omitted authoritative post-mutation user readback" unless
    last_patch_index && final_listing_index && final_listing_index > last_patch_index
  configured_ids = [ADMIN_ID, READER_ID, EDITOR_ID]
  failures << "configured users did not finish with shouldChangePassword=false" unless
    users.select { |entry| configured_ids.include?(entry["id"]) }
         .all? { |entry| entry["shouldChangePassword"] == false }
  failures << "configured-password reconciliation altered an unmanaged record" unless
    users.find { |entry| entry["id"] == UNMANAGED_ID }["shouldChangePassword"] == true

  mutation_count = lifecycle_mutations.length
  repeat_stdout, repeat_stderr, repeat_status = run_configured_password(port, ["reconcile"])
  failures << "second reconciliation failed: #{failure_tail(repeat_stdout + repeat_stderr, 12)}" unless
    repeat_status.success?
  failures << "second reconciliation was not idempotent" unless patches(requests).length == mutation_count

  verify_stdout, verify_stderr, verify_status = run_configured_password(port, ["verify"])
  failures << "verification of reconciled users failed: #{failure_tail(verify_stdout + verify_stderr, 12)}" unless
    verify_status.success?
  failures << "verification mutated configured-password state" unless
    patches(requests).length == mutation_count
end

with_immich_users(complete_users, persist_patches: false) do |port, requests, _users|
  captured_request_sets << requests
  _stdout, _stderr, status = run_configured_password(port, ["reconcile"])
  failures << "reconciliation accepted acknowledged but unpersisted password state" if status.success?

  expected_patches = [ADMIN_ID, READER_ID, EDITOR_ID].map do |id|
    ["PATCH", "/api/admin/users/#{id}"]
  end
  actual_patches = patches(requests)
  failures << "unpersisted-password fixture omitted expected PATCH requests" unless
    actual_patches.map { |request| request.values_at("method", "target") }.sort ==
      expected_patches.sort
  failures << "unpersisted-password fixture sent a forbidden request field" if
    requests.any? { |request| contains_forbidden_body_key?(request["json"]) }
end

replacement_reader = user(
  REPLACEMENT_READER_ID, "reader@example.invalid", admin: false,
  should_change_password: false
)
with_immich_users(
  complete_users,
  replace_after_patches: { "id" => READER_ID, "replacement" => replacement_reader }
) do |port, requests, _users|
  captured_request_sets << requests
  _stdout, _stderr, status = run_configured_password(port, ["reconcile"])
  failures << "reconciliation accepted a same-email configured identity replacement" if status.success?

  expected_patches = [ADMIN_ID, READER_ID, EDITOR_ID].map do |id|
    ["PATCH", "/api/admin/users/#{id}"]
  end
  actual_patches = patches(requests)
  failures << "identity-replacement fixture omitted expected PATCH requests" unless
    actual_patches.map { |request| request.values_at("method", "target") }.sort ==
      expected_patches.sort
  failures << "identity-replacement fixture sent a forbidden request field" if
    requests.any? { |request| contains_forbidden_body_key?(request["json"]) }
end

[ADMIN_ID, READER_ID].each do |malformed_id|
  malformed_users = complete_users
  malformed_users.find { |entry| entry["id"] == malformed_id }["shouldChangePassword"] = "true"
  with_immich_users(malformed_users) do |port, requests, _users|
    captured_request_sets << requests
    _stdout, _stderr, status = run_configured_password(port, ["reconcile"])
    failures << "malformed shouldChangePassword for #{malformed_id} unexpectedly succeeded" if
      status.success?
    check_no_mutation(
      failures, requests, "malformed shouldChangePassword for #{malformed_id} reached mutation"
    )
  end
end

{
  "inactive" => ->(record) { record["status"] = "disabled" },
  "missing" => ->(record) { record.delete("status") },
  "malformed" => ->(record) { record["status"] = false }
}.each do |scenario, mutate_status|
  unsafe_users = complete_users
  mutate_status.call(unsafe_users.find { |entry| entry["id"] == READER_ID })
  with_immich_users(unsafe_users) do |port, requests, _users|
    captured_request_sets << requests
    _stdout, _stderr, status = run_configured_password(port, ["reconcile"])
    failures << "#{scenario} configured target status unexpectedly succeeded" if status.success?
    check_no_mutation(
      failures, requests, "#{scenario} configured target status reached mutation"
    )
  end
end

duplicate_users = complete_users
duplicate_users << user(
  "66666666-6666-4666-8666-666666666666", " READER@EXAMPLE.INVALID ", admin: false
)
with_immich_users(duplicate_users) do |port, requests, _users|
  captured_request_sets << requests
  _stdout, _stderr, status = run_configured_password(port, ["reconcile"])
  failures << "duplicate normalized configured target unexpectedly succeeded" if status.success?
  check_no_mutation(failures, requests, "duplicate normalized configured target reached mutation")
end

duplicate_id_users = complete_users
duplicate_id_users.find { |entry| entry["id"] == EDITOR_ID }["id"] = READER_ID
with_immich_users(duplicate_id_users) do |port, requests, _users|
  captured_request_sets << requests
  _stdout, _stderr, status = run_configured_password(port, ["reconcile"])
  failures << "duplicate configured target UUID unexpectedly succeeded" if status.success?
  check_no_mutation(failures, requests, "duplicate configured target UUID reached mutation")
end

missing_users = complete_users.reject { |entry| entry["id"] == EDITOR_ID }
with_immich_users(missing_users) do |port, requests, _users|
  captured_request_sets << requests
  _stdout, _stderr, status = run_configured_password(port, ["reconcile"])
  failures << "missing configured target unexpectedly succeeded" if status.success?
  check_no_mutation(failures, requests, "missing configured target reached mutation")
end

managed_admin_users = complete_users
managed_admin_users.find { |entry| entry["id"] == READER_ID }["isAdmin"] = true
with_immich_users(managed_admin_users) do |port, requests, _users|
  captured_request_sets << requests
  _stdout, _stderr, status = run_configured_password(port, ["reconcile"])
  failures << "managed isAdmin=true target unexpectedly succeeded" if status.success?
  check_no_mutation(failures, requests, "managed isAdmin=true target reached mutation")
end

with_immich_users(complete_users) do |port, requests, _users|
  captured_request_sets << requests
  stdout, stderr, status = run_configured_password(port, ["reconcile"], "--check")
  failures << "configured-password check mode failed: #{failure_tail(stdout + stderr, 12)}" unless
    status.success?
  plan_lines = stdout.lines.select do |line|
    line.match?(/^\s*"msg": "IMMICH_PLAN_CONFIGURED_PASSWORD"\s*$/)
  end
  failures << "configured-password check mode did not plan all three drifted targets" unless
    plan_lines.length == 3
  failures << "configured-password plan marker appeared in an Ansible task name" if
    stdout.lines.any? do |line|
      line.start_with?("TASK [") && line.include?("IMMICH_PLAN_CONFIGURED_PASSWORD")
    end
  check_no_mutation(failures, requests, "configured-password check mode sent a mutation")
end

with_immich_users(complete_users) do |port, requests, _users|
  captured_request_sets << requests
  _stdout, _stderr, status = run_configured_password(port, ["verify"])
  failures << "verification accepted shouldChangePassword=true" if status.success?
  check_no_mutation(failures, requests, "verification mutated shouldChangePassword=true")
end

# The refusal path of capture3_with_timeout: the process group is signalled and
# the budget named. One second, never the default, so a wrapper that stopped
# refusing cannot sit on a long budget.
with_immich_users(complete_users, blocked: true) do |port, _requests, _users|
  run_configured_password(port, ["reconcile"], timeout_seconds: 1)
  failures << "blocked configured-password fixture did not time out diagnostically"
rescue FixtureTimeout => error
  failures << "blocked configured-password fixture timeout diagnostic differs: " \
              "#{error.message.inspect}" unless
    error.message == "Ansible fixture timed out after 1 second"
end

captured_requests = captured_request_sets.flatten
failures << "configured-password lifecycle used an unexpected mutation method" if
  mutations(captured_requests).any? { |request| request["method"] != "PATCH" }
failures << "a configured-password request body contained password or isAdmin" if
  captured_requests.any? { |request| contains_forbidden_body_key?(request["json"]) }

unless failures.empty?
  warn failures.map { |failure| "Immich configured-password test failed: #{failure}" }.join("\n")
  exit 1
end

puts "Immich configured-password lifecycle fixtures passed"
