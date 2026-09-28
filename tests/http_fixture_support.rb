# frozen_string_literal: true

# The HTTP fixture server and the throwaway playbook runner the behavior tests share.
# A pipe, not only closing the listener, ends the accept loop: not every platform
# wakes a thread blocked in IO.select when its descriptor is closed.

require "open3"
require "socket"
require "tmpdir"
require "yaml"

module HttpFixtureSupport
  # Resolved from this file, so tests under tests/ci/ or tests/mac/ get the same root.
  REPOSITORY_ROOT = File.expand_path("..", __dir__)
  # Default reason phrases; a caller may pass reason: as a phrase, a map, or a callable.
  # Fixture-specific phrases reach the role via Ansible's HTTP diagnostics, so keep them.
  REASONS = {
    200 => "OK", 201 => "Created", 202 => "Accepted", 204 => "No Content",
    400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden",
    404 => "Not Found", 409 => "Conflict", 500 => "Internal Server Error"
  }.freeze
  UNKNOWN_REASON = "Error"
  # How long the server thread may outlive the caller's block before it is a defect.
  JOIN_SECONDS = 10

  class FixtureError < StandardError; end

  # Pinned to the ansible-core wording controller-requirements.txt installs. If a core
  # release rephrases it, update it here rather than dropping the anchor.
  TASK_REFUSAL_PREFIX = "Task failed: Action failed: "

  module_function

  # True when +output+ shows the run refused with +diagnostic+ (the task's fail_msg).
  # Never match the task name: "TASK [<name>]" prints whenever the task merely runs (#419).
  def refused_with?(output, diagnostic)
    output.include?("#{TASK_REFUSAL_PREFIX}#{diagnostic}")
  end

  # A loopback port nothing listens on, for rows testing a REFUSED connection.
  # The port is probed refused before it is returned, narrowing (not closing) the
  # reuse race. Releasing it is right here only because callers need nothing bound
  # there; a helper whose caller then binds the port must hold it instead (#736).
  def refusing_port(attempts: 32)
    attempts.times do
      port = begin
        probe = TCPServer.new("127.0.0.1", 0)
        probe.addr.fetch(1)
      ensure
        probe&.close
      end

      begin
        TCPSocket.new("127.0.0.1", port).close
      rescue Errno::ECONNREFUSED
        return port
      rescue SystemCallError
        next
      end
    end

    raise "no loopback port refused a connection in #{attempts} attempts: something on " \
          "this host is answering on every ephemeral port the kernel handed out"
  end

  # Serves one loopback HTTP fixture for the duration of +client+.
  # The responder answers status, [status, payload] or [status, payload, content_type]
  # (nil omits Content-Type, so a 204 stays a 204). Anything it raises is re-raised in
  # the caller once the fixture is down, so a crashing fixture fails its test.
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

  # Platform facts from inventory/group_vars/all/main.yml, which a one-play playbook
  # never loads. Read at run time (contract fixtures copy this file without inventory);
  # fetch so a renamed key fails here.
  def platform_fixture_variables
    vars = YAML.safe_load_file(File.join(REPOSITORY_ROOT, "inventory", "group_vars", "all", "main.yml"))
    { "platform_safe_api_identifier_pattern" => vars.fetch("platform_safe_api_identifier_pattern") }
  end

  # Runs +tasks+ as a one-play local playbook. Written 0600 in a temp dir that is
  # removed afterwards, because the variables often carry fixture credentials.
  def run_playbook(tasks, variables, *arguments, environment: {}, chdir: REPOSITORY_ROOT,
                   hosts: "localhost", gather_facts: false, prefix: "nas-platform-playbook-")
    Dir.mktmpdir(prefix) do |directory|
      playbook = File.join(directory, "playbook.yml")
      File.write(
        playbook,
        YAML.dump([{ "hosts" => hosts, "gather_facts" => gather_facts,
                     "vars" => platform_fixture_variables.merge(variables), "tasks" => tasks }]),
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
