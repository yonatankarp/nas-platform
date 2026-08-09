#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "socket"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
NTFY_MAIN = File.join(ROOT, "roles", "ntfy", "tasks", "main.yml")
NTFY_MANAGED = File.join(ROOT, "roles", "ntfy", "tasks", "managed_users.yml")

def run_ansible(playbook, *arguments)
  Dir.mktmpdir("nas-platform-ntfy-selection-") do |directory|
    path = File.join(directory, "playbook.yml")
    File.write(path, YAML.dump(playbook), mode: "w", perm: 0o600)
    Open3.capture3(
      { "ANSIBLE_NOCOLOR" => "1" }, "ansible-playbook", "-i", "localhost,", "-c", "local",
      path, *arguments, chdir: ROOT
    )
  end
end

def with_http_recorder
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
      client.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
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

failures = []
main_tasks = YAML.safe_load_file(NTFY_MAIN, aliases: false)
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
        "ntfy_port" => port,
        "vault_managed_ntfy_users" => [{
          "username" => "auditor", "password" => "plain", "role" => "admin",
          "access" => [{ "topic" => "admin-topic", "permission" => "read-write" }]
        }]
      },
      "tasks" => [selected_include]
    }]
    _stdout, stderr, status = run_ansible(playbook, "--tags", "platform_verify_ntfy")
    failures << "normal verify tag fixture failed: #{stderr.lines.last&.strip}" unless status.success?
    failures << "normal verify tag fixture omitted managed authentication/read/write" unless
      requests.map { |method, target, _body| [method, target] } == [
        ["GET", "/v1/account"], ["GET", "/admin-topic/json?poll=1"], ["POST", "/admin-topic"]
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
        "ntfy_port" => port,
        "vault_managed_ntfy_users" => [{
          "username" => "auditor", "password" => "plain", "role" => "admin",
          "access" => [{ "topic" => "admin-topic", "permission" => "read-write" }]
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
        "ntfy_port" => port,
        "vault_managed_ntfy_users" => [{
          "username" => "auditor", "password" => "plain", "role" => "admin",
          "access" => [{ "topic" => "admin-topic", "permission" => "read-write" }]
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
probe_playbook = [{
  "hosts" => "localhost", "gather_facts" => false,
  "vars" => {
    "ntfy_auth_database_stat" => { "stat" => { "exists" => true } },
    "ntfy_existing_user_list" => {},
    "ntfy_prior_provisioned_users" => {},
    "platform_current_dir" => "/nonexistent/current",
    "platform_runtime_dir" => "/nonexistent/runtime",
    "ntfy_compose_project_name" => "check-only",
    "ntfy_compose_files" => ["compose.yml"]
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
