#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "socket"
require "timeout"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
NTFY_MAIN = File.join(ROOT, "roles", "ntfy", "tasks", "main.yml")
NTFY_MANAGED = File.join(ROOT, "roles", "ntfy", "tasks", "managed_users.yml")
NTFY_VERIFY_HOOK = File.join(ROOT, "tests", "mac", "hooks", "verify", "15-ntfy.sh")
NTFY_RECREATE_HOOK = File.join(ROOT, "tests", "mac", "hooks", "fixtures-recreate", "15-ntfy.sh")

class FixtureTimeout < StandardError; end

def terminate_process_group(pid, signal)
  Process.kill(signal, -pid)
rescue Errno::ESRCH
  nil
end

def capture3_with_timeout(environment, *command, chdir:, timeout_seconds:)
  Open3.popen3(environment, *command, chdir: chdir, pgroup: true) do |stdin, stdout, stderr, wait_thread|
    stdin.close
    stdout_reader = Thread.new { stdout.read }
    stderr_reader = Thread.new { stderr.read }
    begin
      status = Timeout.timeout(timeout_seconds) { wait_thread.value }
    rescue Timeout::Error
      terminate_process_group(wait_thread.pid, "TERM")
      unless wait_thread.join(1)
        terminate_process_group(wait_thread.pid, "KILL")
        wait_thread.join
      end
      stdout_reader.join
      stderr_reader.join
      unit = timeout_seconds == 1 ? "second" : "seconds"
      raise FixtureTimeout, "Ansible fixture timed out after #{timeout_seconds} #{unit}"
    end
    [stdout_reader.value, stderr_reader.value, status]
  end
end

def run_ansible(playbook, *arguments, timeout_seconds: 20)
  Dir.mktmpdir("nas-platform-ntfy-selection-") do |directory|
    path = File.join(directory, "playbook.yml")
    File.write(path, YAML.dump(playbook), mode: "w", perm: 0o600)
    capture3_with_timeout(
      { "ANSIBLE_NOCOLOR" => "1" }, "ansible-playbook", "-i", "localhost,", "-c", "local",
      path, *arguments, chdir: ROOT, timeout_seconds: timeout_seconds
    )
  end
end

def run_authoritative_probe_fixture(
  probe_tasks, auth_database_exists:, main_running:, failure_sentinel: nil,
  block_stdin: false, timeout_seconds: nil
)
  Dir.mktmpdir("nas-platform-ntfy-compose-probe-") do |directory|
    current = File.join(directory, "current")
    runtime_root = File.join(directory, "runtime-root")
    project = File.join(current, "services", "ntfy")
    runtime = File.join(runtime_root, "services", "ntfy")
    FileUtils.mkdir_p(project, mode: 0o700)
    FileUtils.mkdir_p(runtime, mode: 0o700)
    File.write(File.join(project, "compose.yml"), <<~YAML, mode: "w", perm: 0o600)
      services:
        ntfy:
          image: ntfy-pinned-fixture
          container_name: ntfy
    YAML
    File.write(File.join(runtime, ".env"), "NTFY_AUTH_USERS=fixture-secret\n", mode: "w", perm: 0o600)
    log = File.join(directory, "docker.log")
    state_path = File.join(directory, "docker-state.json")
    File.write(
      state_path,
      JSON.generate("main_running" => main_running, "one_off_runs" => 0, "one_off_active" => false),
      mode: "w", perm: 0o600
    )
    docker = File.join(directory, "docker")
    File.write(docker, <<~RUBY, mode: "w", perm: 0o700)
      #!/usr/bin/env ruby
      require "json"
      File.open(#{log.dump}, "a", 0o600) do |file|
        file.puts(JSON.generate("main_running" => #{main_running}, "argv" => ARGV))
      end
      arguments = ARGV.dup
      arguments.shift(2) if arguments.first == "--host"
      failure_sentinel = #{failure_sentinel.inspect}
      block_stdin = #{block_stdin}
      case
      when arguments == ["version", "--format", "{{ json . }}"]
        puts JSON.generate("Client" => { "Version" => "29.5.3" }, "Server" => { "Version" => "29.6.2" })
      when arguments == ["compose", "version", "--format", "json"]
        puts JSON.generate("version" => "v5.1.4")
      when arguments.include?("run")
        if arguments.include?("--no-interactive")
          warn "pinned Compose rejected an unsupported interaction flag: fixture-secret"
          exit 125
        end
        state = JSON.parse(File.read(#{state_path.dump}))
        if state.fetch("one_off_active") ||
           (state.fetch("main_running") && arguments.each_cons(2).any? { |pair| pair == ["--name", "ntfy"] })
          warn "one-off container state conflicts with the running main service"
          exit 125
        end
        state["one_off_active"] = true
        state["one_off_runs"] += 1
        File.write(#{state_path.dump}, JSON.generate(state), mode: "w", perm: 0o600)
        if failure_sentinel
          puts failure_sentinel
          warn failure_sentinel
          state["one_off_active"] = false
          File.write(#{state_path.dump}, JSON.generate(state), mode: "w", perm: 0o600)
          exit 125
        end
        if block_stdin
          blocked_reader, blocked_writer = IO.pipe
          STDIN.reopen(blocked_reader)
        end
        unless STDIN.read.empty?
          warn "authoritative probe unexpectedly received standard input"
          exit 125
        end
        puts "user * (role: anonymous, tier: none)"
        puts "- no access to any (other) topics (server config)"
        state["one_off_active"] = false
        File.write(#{state_path.dump}, JSON.generate(state), mode: "w", perm: 0o600)
      else
        warn "unexpected Docker CLI operation"
        exit 125
      end
    RUBY

    tasks = Marshal.load(Marshal.dump(probe_tasks))
    tasks.fetch(0).fetch("community.docker.docker_compose_v2_run")["docker_cli"] = docker
    playbook = [{
      "hosts" => "localhost", "gather_facts" => false,
      "vars" => {
        "ntfy_auth_database_stat" => { "stat" => { "exists" => auth_database_exists } },
        "ntfy_prior_provisioned_users" => {},
        "platform_current_dir" => current,
        "platform_runtime_dir" => runtime_root,
        "ntfy_compose_project_name" => "ntfy-authoritative-fixture",
        "platform_service_compose_files" => { "ntfy" => ["compose.yml"] }
      },
      "tasks" => tasks
    }]
    stdout, stderr, status = run_ansible(
      playbook, timeout_seconds: timeout_seconds || 20
    )
    calls = File.exist?(log) ? File.readlines(log, chomp: true).map { |line| JSON.parse(line) } : []
    [stdout + stderr, status, calls, JSON.parse(File.read(state_path))]
  end
end

def with_http_recorder(account_mutator = nil)
  server = TCPServer.new("127.0.0.1", 0)
  requests = []
  stopped = false
  thread = Thread.new do
    until stopped
      next unless IO.select([server], nil, nil, 0.05)

      client = server.accept
      request_line = client.gets&.strip
      method, target, = request_line.to_s.split(" ", 3)
      headers = {}
      while (line = client.gets)
        line = line.chomp
        break if line == "\r" || line.empty?

        key, value = line.split(":", 2)
        headers[key.downcase] = value.to_s.strip
      end
      body = client.read(headers.fetch("content-length", "0").to_i)
      requests << [method, target, body]
      response_body = if target == "/v1/account"
                        username = headers.fetch("authorization", "").delete_prefix("Basic ")
                        username = username.unpack1("m0").to_s.split(":", 2).first
                        host = headers.fetch("host")
                        account = {
                          "username" => username, "role" => "user",
                          "subscriptions" => [{
                            "base_url" => "http://#{host}", "topic" => "nas-critical",
                            "display_name" => nil
                          }]
                        }
                        account = account_mutator.call(account) if account_mutator
                        JSON.generate(account)
                      else
                        ""
                      end
      content_type = target == "/v1/account" ? "application/json" : "text/plain"
      client.write(
        "HTTP/1.1 200 OK\r\nContent-Type: #{content_type}\r\n" \
        "Content-Length: #{response_body.bytesize}\r\nConnection: close\r\n\r\n#{response_body}"
      )
      client.close
    end
  rescue IOError, Errno::EBADF
    nil
  end
  yield server.addr.fetch(1), requests
ensure
  stopped = true
  server&.close
  thread&.join
end

def run_ntfy_verify_hook_fixture(port)
  Dir.mktmpdir("nas-platform-ntfy-hook-") do |directory|
    fake_vault = File.join(directory, "vault.yml")
    fake_password = File.join(directory, "password")
    fake_ansible_vault = File.join(directory, "ansible-vault")
    File.write(fake_password, "fixture\n", mode: "w", perm: 0o600)
    File.write(fake_vault, YAML.dump(
      "vault_managed_users" => {
        "ntfy" => [
          {
            "username" => "reader", "password" => "reader-secret", "role" => "user",
            "access" => [{ "topic" => "nas-critical", "permission" => "read-only" }]
          },
          {
            "username" => "writer", "password" => "writer-secret", "role" => "user",
            "access" => [{ "topic" => "nas-critical", "permission" => "write-only" }]
          },
          {
            "username" => "other", "password" => "other-secret", "role" => "user",
            "access" => [{ "topic" => "other-topic", "permission" => "read-write" }]
          }
        ]
      }
    ), mode: "w", perm: 0o600)
    File.write(fake_ansible_vault, <<~'SH', mode: "w", perm: 0o700)
      #!/bin/sh
      exec /bin/cat "${FAKE_NTFY_VAULT:?}"
    SH
    environment = {
      "PATH" => "#{directory}:#{ENV.fetch('PATH')}",
      "FAKE_NTFY_VAULT" => fake_vault,
      "PLATFORM_MAC_VAULT_FILE" => fake_vault,
      "PLATFORM_MAC_VAULT_PASSWORD_FILE" => fake_password,
      "PLATFORM_NTFY_PORT" => port.to_s
    }
    Open3.capture3(environment, NTFY_VERIFY_HOOK)
  end
end

failures = []
main_tasks = YAML.safe_load_file(NTFY_MAIN, aliases: false)
verify_hook = File.exist?(NTFY_VERIFY_HOOK) ? File.read(NTFY_VERIFY_HOOK) : ""
recreate_hook = File.read(NTFY_RECREATE_HOOK)
failures << "ntfy verification hook is missing or not executable" unless
  File.file?(NTFY_VERIFY_HOOK) && File.executable?(NTFY_VERIFY_HOOK)
failures << "ntfy verification hook does not inspect every eligible account subscription" unless
  verify_hook.include?("vault_managed_users") && verify_hook.include?("nas-critical") &&
    verify_hook.include?("base_url") && verify_hook.include?("subscriptions") &&
    verify_hook.include?("Net::HTTP") && verify_hook.include?("basic_auth")
failures << "ntfy verification hook incorrectly manages browser-local notification state" if
  verify_hook.match?(/web.?push|notification.?permission|local.?storage/i)
failures << "ntfy recreation does not verify synchronized account subscriptions" unless
  recreate_hook.include?("../verify/15-ntfy.sh")

with_http_recorder do |port, hook_requests|
  stdout, stderr, hook_status = run_ntfy_verify_hook_fixture(port)
  failures << "ntfy verification hook fixture failed: #{stderr.lines.last&.strip}" unless
    hook_status.success?
  failures << "ntfy verification hook disclosed a managed password" if
    (stdout + stderr).match?(/reader-secret|writer-secret|other-secret/)
  failures << "ntfy verification hook did not authenticate exactly every eligible account" unless
    hook_requests.map { |method, target, _body| [method, target] } == [["GET", "/v1/account"]]
end

with_http_recorder(proc do |account|
  account.merge("subscriptions" => [account.fetch("subscriptions").first.merge(
    "display_name" => "Critical"
  )])
end) do |port, _requests|
  _stdout, _stderr, hook_status = run_ntfy_verify_hook_fixture(port)
  failures << "ntfy verification hook rejected a string display_name" unless hook_status.success?
end

{
  "wrong username" => proc { |account| account.merge("username" => "other") },
  "administrator role" => proc { |account| account.merge("role" => "admin") },
  "missing display_name" => proc do |account|
    account.merge("subscriptions" => [account.fetch("subscriptions").first.reject do |key, _value|
      key == "display_name"
    end])
  end,
  "extra subscription field" => proc do |account|
    account.merge("subscriptions" => [account.fetch("subscriptions").first.merge("extra" => true)])
  end,
  "wrong subscription field type" => proc do |account|
    account.merge("subscriptions" => [account.fetch("subscriptions").first.merge("display_name" => 7)])
  end
}.each do |label, mutation|
  with_http_recorder(mutation) do |port, _requests|
    _stdout, _stderr, hook_status = run_ntfy_verify_hook_fixture(port)
    failures << "ntfy verification hook accepted #{label}" if hook_status.success?
  end
end
verify_include = main_tasks.find do |task|
  task["name"] == "Verify managed ntfy users and declared access"
end

Dir.mktmpdir("nas-platform-ntfy-list-") do |directory|
  inventory = File.join(directory, "inventory.ini")
  File.write(inventory, "[platform_hosts]\nlocalhost ansible_connection=local\n", mode: "w", perm: 0o600)
  stdout, stderr, status = Open3.capture3(
    { "ANSIBLE_NOCOLOR" => "1" }, "ansible-playbook", "-i", inventory,
    File.join(ROOT, "verify.yml"), "--tags", "platform_verify_ntfy", "--list-tasks", chdir: ROOT
  )
  output = stdout + stderr
  failures << "verify tag list command failed" unless status.success?
  failures << "verify tag list omits the managed-user include" unless
    output.include?("Verify managed ntfy users and declared access")
  %w[
    Inspect\ existing\ ntfy\ declarative\ ownership\ and\ users
    List\ authoritative\ existing\ ntfy\ users
    Resolve\ declarative\ ntfy\ managed-user\ provisioning
  ].each do |name|
    failures << "verify-only tag list includes provisioning task #{name.tr('\\', '')}" if
      output.include?(name.tr("\\", ""))
  end
end

if verify_include
  selected_include = Marshal.load(Marshal.dump(verify_include))
  include_args = selected_include["ansible.builtin.include_tasks"]
  if include_args.is_a?(Hash)
    include_args["file"] = NTFY_MANAGED
  else
    selected_include["ansible.builtin.include_tasks"] = NTFY_MANAGED
  end
  with_http_recorder do |port, requests|
    playbook = [{
      "hosts" => "localhost", "gather_facts" => false,
      "vars" => {
        "ntfy_account_api" => "http://127.0.0.1:#{port}/v1/account",
        "ntfy_account_subscription_api" => "http://127.0.0.1:#{port}/v1/account/subscription",
        "ntfy_base_url" => "http://127.0.0.1:#{port}",
        "ntfy_port" => port,
        "vault_managed_ntfy_users" => [{
          "username" => "auditor", "password" => "plain", "role" => "user",
          "access" => [{ "topic" => "nas-critical", "permission" => "read-write" }]
        }]
      },
      "tasks" => [selected_include]
    }]
    _stdout, stderr, status = run_ansible(playbook, "--tags", "platform_verify_ntfy")
    failures << "normal verify tag fixture failed: #{stderr.lines.last&.strip}" unless status.success?
    failures << "normal verify tag fixture omitted managed authentication/read/write" unless
      requests.map { |method, target, _body| [method, target] } == [
        ["GET", "/v1/account"], ["GET", "/v1/account"],
        ["GET", "/nas-critical/json?poll=1"], ["POST", "/nas-critical"]
      ]
  end

  with_http_recorder do |port, requests|
    direct_include = {
      "name" => "Check managed ntfy verification without tag filtering",
      "ansible.builtin.include_tasks" => NTFY_MANAGED,
      "vars" => { "ntfy_managed_users_phase" => "verify" }
    }
    playbook = [{
      "hosts" => "localhost", "gather_facts" => false,
      "vars" => {
        "ntfy_account_api" => "http://127.0.0.1:#{port}/v1/account",
        "ntfy_account_subscription_api" => "http://127.0.0.1:#{port}/v1/account/subscription",
        "ntfy_base_url" => "http://127.0.0.1:#{port}",
        "ntfy_port" => port,
        "vault_managed_ntfy_users" => [{
          "username" => "auditor", "password" => "plain", "role" => "user",
          "access" => [{ "topic" => "nas-critical", "permission" => "read-write" }]
        }]
      },
      "tasks" => [direct_include]
    }]
    _stdout, stderr, status = run_ansible(playbook, "--check")
    failures << "direct check-mode managed verification failed: #{stderr.lines.last&.strip}" unless
      status.success?
    failures << "direct check-mode managed verification performed HTTP requests" unless requests.empty?
  end

  with_http_recorder do |port, requests|
    playbook = [{
      "hosts" => "localhost", "gather_facts" => false,
      "vars" => {
        "ntfy_account_api" => "http://127.0.0.1:#{port}/v1/account",
        "ntfy_account_subscription_api" => "http://127.0.0.1:#{port}/v1/account/subscription",
        "ntfy_base_url" => "http://127.0.0.1:#{port}",
        "ntfy_port" => port,
        "vault_managed_ntfy_users" => [{
          "username" => "auditor", "password" => "plain", "role" => "user",
          "access" => [{ "topic" => "nas-critical", "permission" => "read-write" }]
        }]
      },
      "tasks" => [selected_include]
    }]
    _stdout, stderr, status = run_ansible(
      playbook, "--check", "--tags", "platform_verify_ntfy"
    )
    failures << "check-mode verify tag fixture failed: #{stderr.lines.last&.strip}" unless status.success?
    failures << "check-mode verify tag fixture performed HTTP requests" unless requests.empty?
  end
else
  failures << "ntfy main tasks omit the managed-user verify include"
end

probe_names = [
  "List authoritative existing ntfy users",
  "Require authoritative ntfy user listing",
  "Resolve authoritative existing ntfy users"
]
probe_tasks = probe_names.filter_map { |name| main_tasks.find { |task| task["name"] == name } }
unless probe_tasks.length == probe_names.length
  failures << "authoritative ntfy probe fixture tasks are incomplete"
end

fresh_output, fresh_status, fresh_calls = run_authoritative_probe_fixture(
  probe_tasks, auth_database_exists: false, main_running: false
)
failures << "fresh install authoritative probe was not a redacted non-mutating skip" unless
  fresh_status.success? && fresh_calls.empty? && !fresh_output.include?("fixture-secret")

[
  [false, "stopped main service"],
  [true, "running main service"]
].each do |main_running, label|
  probe_output, probe_status, calls, fake_state = run_authoritative_probe_fixture(
    probe_tasks, auth_database_exists: true, main_running: main_running
  )
  run_record = calls.find { |record| record.fetch("argv").include?("run") }
  run_call = run_record&.fetch("argv")
  failures << "#{label} authoritative probe failed with redacted diagnostics" unless
    probe_status.success? && !probe_output.include?("fixture-secret")
  failures << "#{label} authoritative probe did not use one non-provisioning user-list call" unless
    run_call && run_call.last(5) == [
      "ntfy", "user", "--auth-file=/var/lib/ntfy/auth.db",
      "--auth-default-access=deny-all", "list"
    ] &&
      run_record.fetch("main_running") == main_running &&
      run_call.include?("--no-TTY") && !run_call.include?("--interactive") &&
      !run_call.include?("--no-interactive") &&
      !run_call.include?("up") && !run_call.include?("create") && !run_call.include?("start")
  failures << "#{label} one-off lifecycle did not preserve the main service state" unless
    fake_state == {
      "main_running" => main_running, "one_off_runs" => 1, "one_off_active" => false
    }
end

redaction_sentinel = "ntfy-probe-secret-sentinel"
failure_output, failure_status, = run_authoritative_probe_fixture(
  probe_tasks,
  auth_database_exists: true,
  main_running: true,
  failure_sentinel: redaction_sentinel
)
failures << "authoritative ntfy probe failure injection did not fail safely" if failure_status.success?
failures << "authoritative ntfy probe no_log leaked injected output" if
  failure_output.include?(redaction_sentinel)

begin
  run_authoritative_probe_fixture(
    probe_tasks,
    auth_database_exists: true,
    main_running: true,
    block_stdin: true,
    timeout_seconds: 1
  )
  failures << "blocked authoritative ntfy probe did not time out diagnostically"
rescue FixtureTimeout => error
  failures << "blocked authoritative ntfy probe timeout diagnostic differs" unless
    error.message == "Ansible fixture timed out after 1 second"
end
probe_playbook = [{
  "hosts" => "localhost", "gather_facts" => false,
  "vars" => {
    "ntfy_auth_database_stat" => { "stat" => { "exists" => true } },
    "ntfy_existing_user_list" => {},
    "ntfy_prior_provisioned_users" => {},
    "platform_current_dir" => "/nonexistent/current",
    "platform_runtime_dir" => "/nonexistent/runtime",
    "ntfy_compose_project_name" => "check-only",
    "platform_service_compose_files" => { "ntfy" => ["compose.yml"] }
  },
  "tasks" => probe_tasks
}]
stdout, stderr, status = run_ansible(probe_playbook, "--check")
output = stdout + stderr
failures << "check-mode authoritative probe fixture failed safely: #{stderr.lines.last&.strip}" unless
  status.success?
failures << "check-mode authoritative probe was not skipped" unless
  output.match?(/skipped=1\b/)

if failures.empty?
  puts "ntfy verification selection: tags and check mode are non-mutating and complete"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} ntfy verification selection violation(s)"
end
