# frozen_string_literal: true

# The HTTP fixture server and the throwaway playbook runner the behavior tests
# share.
#
# A dozen tests each grew their own copy of the same thirty-five lines: a
# loopback TCPServer on an ephemeral port, an accept loop in a thread, the
# request-line and header parse, the content-length body read, and the teardown
# that has to hand a crash in that thread back to the main thread. The copies
# drifted — tests/paperless_mail_reconciliation_test.rb and
# tests/ntfy_verify_execution_test.rb had both lost the error propagation, so a
# fixture that raised reported a passing test.
#
# What genuinely differs between the tests is the response, so that is all a
# caller supplies: a responder block answering [status, payload]. The transport,
# the shutdown and the error propagation are stated once, here.
#
# The shutdown uses a pipe rather than closing the listening socket alone.
# Closing it relies on the interpreter waking a thread blocked in IO.select on
# that descriptor, which not every platform delivers; the pipe makes the select
# return by itself, so the server thread always unwinds.

require "open3"
require "socket"
require "timeout"
require "tmpdir"
require "yaml"

module HttpFixtureSupport
  # Resolved from this file rather than from the caller, so a test nested under
  # tests/ci/ or tests/mac/ gets the same repository root as one directly in
  # tests/.
  REPOSITORY_ROOT = File.expand_path("..", __dir__)

  # The reason phrases the fixtures used to spell out one map at a time. A
  # caller states its own with reason:, as a literal phrase, a status-to-phrase
  # mapping falling back to UNKNOWN_REASON, or anything callable with a status.
  # Several fixtures answer a phrase of their own — the phrase reaches the role
  # through Ansible's HTTP diagnostics, so it is preserved rather than
  # standardised.
  REASONS = {
    200 => "OK", 201 => "Created", 202 => "Accepted", 204 => "No Content",
    400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden",
    404 => "Not Found", 409 => "Conflict", 500 => "Internal Server Error"
  }.freeze
  UNKNOWN_REASON = "Error"
  # How long the caller's block may leave the server thread running after it
  # returns. A fixture thread that will not stop is a defect worth reporting
  # rather than a hang worth waiting out.
  JOIN_SECONDS = 10

  # Raised for a fault in the fixture itself, so it is never mistaken for the
  # behavior under test.
  class FixtureError < StandardError; end

  module_function

  # Serves one loopback HTTP fixture for the duration of +client+.
  #
  #   with_http_fixture(->(port) { ... }) do |method, target, headers, body|
  #     [200, JSON.generate("ok" => true)]
  #   end
  #
  # The responder answers a bare status, or [status, payload], or
  # [status, payload, content_type]. A three-element answer states the
  # Content-Type outright, and a nil there omits the header — which is how a
  # 204 stays a 204.
  #
  # Anything the responder raises is re-raised in the calling thread once the
  # fixture is down. That is the whole point of the helper: a fixture that
  # crashes must fail its test, not answer nothing and let the assertion blame
  # the role.
  def with_http_fixture(client, content_type: "application/json", reason: nil, &responder)
    raise ArgumentError, "an HTTP fixture needs a responder block" unless responder

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
          serve_request(socket, responder, content_type, reason)
        ensure
          socket.close unless socket.closed?
        end
      end
    rescue IOError, Errno::EBADF
      nil
    rescue StandardError => caught
      error = caught
    end

    client.call(server.addr.fetch(1))
  ensure
    begin
      shutdown_writer&.write("x")
    rescue IOError, Errno::EPIPE
      nil
    end
    shutdown_writer&.close unless shutdown_writer&.closed?
    server&.close unless server&.closed?
    if thread && !thread.join(JOIN_SECONDS)
      thread.kill
      thread.join
      error ||= FixtureError.new("HTTP fixture thread did not stop within #{JOIN_SECONDS}s")
    end
    shutdown_reader&.close unless shutdown_reader&.closed?
    raise error if error
  end

  def serve_request(socket, responder, default_content_type, reason)
    request_line = socket.gets
    raise FixtureError, "HTTP fixture received an empty request" unless request_line

    method, target, = request_line.strip.split(" ", 3)
    headers = read_headers(socket)
    body = socket.read(headers.fetch("content-length", "0").to_i).to_s.force_encoding("UTF-8")

    answer = responder.call(method, target, headers, body)
    if answer.is_a?(Array)
      status, payload, explicit_type = answer
      content_type = answer.length >= 3 ? explicit_type : default_content_type
    else
      status = answer
      payload = nil
      content_type = default_content_type
    end
    write_response(socket, status, payload, content_type, reason)
  end

  def read_headers(socket)
    headers = {}
    while (line = socket.gets)
      line = line.chomp
      break if line == "\r" || line.empty?

      key, value = line.split(":", 2)
      headers[key.downcase] = value.to_s.strip
    end
    headers
  end

  def write_response(socket, status, payload, content_type, reason)
    body = payload.to_s
    socket.write("HTTP/1.1 #{status} #{reason_for(status, reason)}\r\n")
    socket.write("Content-Type: #{content_type}\r\n") if content_type
    socket.write("Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
  end

  def reason_for(status, reason)
    case reason
    when nil then REASONS.fetch(status, UNKNOWN_REASON)
    when String then reason
    when Hash then reason.fetch(status, UNKNOWN_REASON)
    else reason.call(status)
    end
  end

  # Runs +tasks+ as a one-play playbook against the local connection, the way
  # every behavior test reaches a role's task file without a real inventory.
  #
  # The playbook is written mode 0600 inside a temporary directory that is
  # removed afterwards, because the variables these tests pass routinely include
  # fixture credentials.
  def run_playbook(tasks, variables, *arguments, environment: {}, chdir: REPOSITORY_ROOT,
                   hosts: "localhost", gather_facts: false, prefix: "nas-platform-playbook-")
    Dir.mktmpdir(prefix) do |directory|
      playbook = File.join(directory, "playbook.yml")
      File.write(
        playbook,
        YAML.dump([{ "hosts" => hosts, "gather_facts" => gather_facts,
                     "vars" => variables, "tasks" => tasks }]),
        mode: "w", perm: 0o600
      )
      Open3.capture3(
        { "ANSIBLE_NOCOLOR" => "1" }.merge(environment),
        "ansible-playbook", "-i", "localhost,", "-c", "local", playbook, *arguments,
        chdir: chdir
      )
    end
  end
end
