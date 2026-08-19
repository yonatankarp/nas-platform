#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "json"
require "socket"
require "tmpdir"
require "time"
require "yaml"

ROOT = File.expand_path("..", __dir__)
ROLE_TASKS = File.join(ROOT, "roles/beszel/tasks/main.yml")
ROLE_VARS = File.join(ROOT, "roles/beszel/vars/main.yml")

version_output, version_status = Open3.capture2("ansible-playbook", "--version")
abort "Beszel Ansible telemetry test requires ansible-core 2.21.3" unless
  version_status.success? && version_output.start_with?("ansible-playbook [core 2.21.3]")

def flatten_tasks(tasks)
  Array(tasks).flat_map do |task|
    [task] + flatten_tasks(task.is_a?(Hash) ? task["block"] : nil) +
      flatten_tasks(task.is_a?(Hash) ? task["rescue"] : nil) +
      flatten_tasks(task.is_a?(Hash) ? task["always"] : nil)
  end
end

def run_play(tasks, vars, vars_files: [])
  play = [{
    "hosts" => "localhost",
    "gather_facts" => false,
    "vars_files" => vars_files,
    "vars" => vars,
    "tasks" => tasks
  }]
  Dir.mktmpdir("beszel-ansible-policy") do |dir|
    path = File.join(dir, "play.yml")
    File.write(path, YAML.dump(play), mode: "w", perm: 0o600)
    Open3.capture3(
      { "ANSIBLE_NOCOLOR" => "1" }, "ansible-playbook", "-i", "localhost,",
      "-c", "local", path
    )
  end
end

failures = []
tasks = flatten_tasks(YAML.safe_load_file(ROLE_TASKS))
capability = tasks.find { |task| task["name"] == "Require the selected Beszel telemetry capability" }
cardinality = tasks.find { |task| task["name"] == "Require exactly one managed Beszel system for telemetry" }
resolve_evidence = tasks.find { |task| task["name"] == "Resolve persisted Beszel telemetry evidence" }
verify_evidence = tasks.find { |task| task["name"] == "Verify persisted Beszel telemetry categories" }
failures << "Beszel telemetry capability assertion is absent" unless capability
failures << "Beszel telemetry system cardinality assertion is absent" unless cardinality
failures << "Beszel telemetry safe evidence tasks are absent" unless resolve_evidence && verify_evidence

if capability
  cases = [
    ["valid Mac", "mac", %w[core disk containers], false, "portable", false, true],
    ["valid NAS", "nas", %w[core disk containers gpu], true, "intel", true, true],
    ["valid integration", "nas", %w[core disk containers], false, "portable", false, true,
     "/dev/dri/renderD128", true, "integration", true],
    ["integration without test mode", "nas", %w[core disk containers], false, "portable", false, false,
     "/dev/dri/renderD128", true, "integration", false],
    ["test mode outside integration", "nas", %w[core disk containers], false, "portable", false, false,
     "/dev/dri/renderD128", true, "nas", true],
    ["integration with NAS GPU policy", "nas", %w[core disk containers gpu], true, "intel", true, false,
     "/dev/dri/renderD128", true, "integration", true],
    ["Mac core-only", "mac", %w[core], false, "portable", false, false],
    ["Mac missing disk", "mac", %w[core containers], false, "portable", false, false],
    ["Mac missing containers", "mac", %w[core disk], false, "portable", false, false],
    ["Mac extra GPU", "mac", %w[core disk containers gpu], false, "portable", false, false],
    ["NAS missing GPU", "nas", %w[core disk containers], true, "intel", true, false],
    ["NAS duplicate category", "nas", %w[core disk containers gpu gpu], true, "intel", true, false],
    ["NAS wrong render path", "nas", %w[core disk containers gpu], true, "intel", true, false, "/dev/dri/card0"],
    ["NAS unavailable agent", "nas", %w[core disk containers gpu], true, "intel", true, true, "/dev/dri/renderD128", false],
    ["Mac unavailable agent", "mac", %w[core disk containers], false, "portable", false, true,
     "/dev/dri/card0", false],
    ["NAS wrong agent kind", "nas", %w[core disk containers gpu], true, "portable", true, false],
    ["NAS GPU flag mismatch", "nas", %w[core disk containers gpu], false, "intel", true, false],
    ["Mac GPU flag mismatch", "mac", %w[core disk containers], true, "portable", false, false],
    ["unknown category", "mac", %w[core disk containers mystery], false, "portable", false, false],
    ["unknown platform", "other", %w[core disk containers], false, "portable", false, false]
  ]
  cases.each do |name, platform, categories, require_gpu, kind, gpu_available, expected_success,
                 render_path, agent_available, compose_kind, test_mode|
    vars = {
      "platform_kind" => platform,
      "platform_beszel_agent_available" => agent_available.nil? ? true : agent_available,
      "platform_beszel_agent_kind" => kind,
      "platform_render_device_path" => render_path || (platform == "nas" ? "/dev/dri/renderD128" : "/dev/dri/card0"),
      "preflight_gpu_available" => gpu_available,
      "beszel_required_telemetry_categories" => categories,
      "beszel_require_gpu_telemetry" => require_gpu,
      "beszel_effective_required_telemetry_categories" => categories,
      "beszel_effective_require_gpu_telemetry" => require_gpu,
      "beszel_integration_test_capability" =>
        (compose_kind == "integration" && test_mode == true),
      "beszel_telemetry_freshness_seconds" => 180,
      "beszel_telemetry_poll_timeout_seconds" => 90,
      "beszel_telemetry_poll_delay_seconds" => 3,
      "beszel_telemetry_request_timeout_seconds" => 3,
      "platform_compose_kind" => compose_kind || platform,
      "deployment_bundle_test_mode" => test_mode || false
    }
    _stdout, _stderr, status = run_play([capability], vars)
    failures << "#{name} capability policy #{expected_success ? 'failed' : 'was accepted'}" unless
      status.success? == expected_success
  end

  [[59, 90, 5, 3], [180, 59, 5, 3], [180, 90, 0, 3],
   [180, 10, 10, 3], [180, 90, 3, 0], [180, 90, 3, 30]].each do |freshness, timeout, delay, request_timeout|
    vars = {
      "platform_kind" => "mac", "platform_beszel_agent_available" => true,
      "platform_beszel_agent_kind" => "portable", "platform_render_device_path" => "/dev/dri/card0",
      "preflight_gpu_available" => false, "beszel_required_telemetry_categories" => %w[core disk containers],
      "beszel_require_gpu_telemetry" => false, "beszel_effective_required_telemetry_categories" => %w[core disk containers],
      "beszel_effective_require_gpu_telemetry" => false,
      "beszel_integration_test_capability" => false,
      "beszel_telemetry_freshness_seconds" => freshness,
      "beszel_telemetry_poll_timeout_seconds" => timeout,
      "beszel_telemetry_poll_delay_seconds" => delay,
      "beszel_telemetry_request_timeout_seconds" => request_timeout,
      "platform_compose_kind" => "mac",
      "deployment_bundle_test_mode" => false
    }
    _stdout, _stderr, status = run_play([capability], vars)
    timing = "freshness=#{freshness} timeout=#{timeout} delay=#{delay} request=#{request_timeout}"
    failures << "invalid timing policy #{timing} was accepted" if status.success?
  end
end

if cardinality
  [[0, false], [1, true], [2, false]].each do |count, expected_success|
    systems = count.times.map { |index| { "id" => "system-safe-#{index}" } }
    stdout, stderr, status = run_play([cardinality], { "beszel_matching_systems" => systems })
    failures << "managed-system count #{count} #{expected_success ? 'failed' : 'was accepted'}" unless
      status.success? == expected_success
    output = stdout + stderr
    failures << "cardinality failure leaked unsafe content" if
      !expected_success && output.downcase.include?("password")
    failures << "cardinality failure omitted safe system IDs" if
      count == 2 && !output.include?("system-safe-0,system-safe-1")
  end
end

created = (Time.now.utc - 30).strftime("%Y-%m-%d %H:%M:%S.%LZ")
valid_system_stats = {
  "id" => "system-stats-safe", "system" => "system-safe", "type" => "1m", "created" => created,
  "stats" => {
    "cpu" => 0.0, "m" => 8.0, "mu" => 2.0, "mp" => 25.0,
    "d" => 100.0, "du" => 40.0, "dp" => 40.0,
    "g" => { "0" => { "n" => "Intel", "u" => 0.0 } }
  }
}
valid_container_stats = {
  "id" => "container-stats-safe", "system" => "system-safe", "type" => "1m", "created" => created,
  "stats" => [{ "n" => "hub", "c" => 0.0, "m" => 0.1 }]
}

predicate_cases = []
%w[first last].each do |position|
  valid_gpu = { "n" => "Intel", "u" => 0.0 }
  invalid_gpu = { "n" => "Intel" }
  gpu_entries = position == "first" ? [invalid_gpu, valid_gpu] : [valid_gpu, invalid_gpu]
  system_stats = Marshal.load(Marshal.dump(valid_system_stats))
  system_stats.fetch("stats")["g"] = gpu_entries.each_with_index.to_h { |gpu, index| [index.to_s, gpu] }
  predicate_cases << ["GPU malformed #{position}", system_stats, valid_container_stats, "beszel_gpu_telemetry_ready", false]

  valid_container = { "n" => "hub", "c" => 0.0, "m" => 0.1 }
  invalid_container = { "n" => "hub", "m" => 0.1 }
  containers = position == "first" ? [invalid_container, valid_container] : [valid_container, invalid_container]
  container_stats = Marshal.load(Marshal.dump(valid_container_stats))
  container_stats["stats"] = containers
  predicate_cases << ["container malformed #{position}", valid_system_stats, container_stats,
                      "beszel_containers_telemetry_ready", false]
end
predicate_cases.concat([
  ["valid GPU", valid_system_stats, valid_container_stats, "beszel_gpu_telemetry_ready", true],
  ["valid containers", valid_system_stats, valid_container_stats, "beszel_containers_telemetry_ready", true]
])

record_mutations = {
  "missing system record ID" => ->(system, _container) { system.delete("id") },
  "invalid system record ID" => ->(system, _container) { system["id"] = "bad id" },
  "whitespace system record ID" => ->(system, _container) { system["id"] = "  " },
  "typed system record ID" => ->(system, _container) { system["id"] = 123 },
  "missing container record ID" => ->(_system, container) { container.delete("id") },
  "invalid container record ID" => ->(_system, container) { container["id"] = "bad id" },
  "whitespace container record ID" => ->(_system, container) { container["id"] = "  " },
  "typed container record ID" => ->(_system, container) { container["id"] = 123 },
  "wrong system" => ->(system, _container) { system["system"] = "wrong" },
  "missing system" => ->(system, _container) { system.delete("system") },
  "wrong container system" => ->(_system, container) { container["system"] = "wrong" },
  "missing container system" => ->(_system, container) { container.delete("system") },
  "wrong type" => ->(system, _container) { system["type"] = "10m" },
  "missing type" => ->(system, _container) { system.delete("type") },
  "wrong container type" => ->(_system, container) { container["type"] = "10m" },
  "missing container type" => ->(_system, container) { container.delete("type") },
  "boolean core" => ->(system, _container) { system.fetch("stats")["cpu"] = true },
  "boolean disk" => ->(system, _container) { system.fetch("stats")["d"] = true },
  "boolean GPU" => ->(system, _container) { system.fetch("stats").fetch("g").fetch("0")["u"] = true },
  "boolean container CPU" => ->(_system, container) { container.fetch("stats").fetch(0)["c"] = true },
  "boolean container memory" => ->(_system, container) { container.fetch("stats").fetch(0)["m"] = true },
  "malformed system stats" => ->(system, _container) { system["stats"] = [] },
  "malformed container stats" => ->(_system, container) { container["stats"] = {} },
  "invalid timestamp" => ->(system, _container) { system["created"] = "bad" },
  "naive system timestamp" => ->(system, _container) { system["created"] = "2026-08-12T11:59:00" },
  "naive container timestamp" => ->(_system, container) { container["created"] = "2026-08-12T11:59:00" },
  "typed system timestamp" => ->(system, _container) { system["created"] = 123 },
  "typed container timestamp" => ->(_system, container) { container["created"] = 123 },
  "future timestamp" => ->(system, _container) { system["created"] = (Time.now.utc + 60).strftime("%Y-%m-%d %H:%M:%S.%LZ") },
  "whitespace GPU name" => ->(system, _container) { system.fetch("stats").fetch("g").fetch("0")["n"] = "  " },
  "whitespace container name" => ->(_system, container) { container.fetch("stats").fetch(0)["n"] = "  " }
}
record_mutations.each do |name, mutate|
  system = Marshal.load(Marshal.dump(valid_system_stats))
  container = Marshal.load(Marshal.dump(valid_container_stats))
  mutate.call(system, container)
  predicate_cases << [name, system, container, "beszel_missing_telemetry_categories | length == 0", false]
end
predicate_cases << ["malformed system record", [], valid_container_stats,
                    "beszel_missing_telemetry_categories | length == 0", false]
predicate_cases << ["malformed container record", valid_system_stats, [],
                    "beszel_missing_telemetry_categories | length == 0", false]

predicate_cases.each do |name, system_stats, container_stats, predicate, expected|
  vars = {
    "beszel_system_stats" => { "json" => { "items" => [system_stats] } },
    "beszel_container_stats" => { "json" => { "items" => [container_stats] } },
    "beszel_telemetry_freshness_seconds" => 180,
    "beszel_required_telemetry_categories" => %w[core disk containers gpu],
    "beszel_require_gpu_telemetry" => true,
    "beszel_systems" => {
      "json" => { "items" => [{ "id" => "system-safe", "name" => "managed", "users" => ["user-safe"] }] }
    },
    "beszel_system_name" => "managed",
    "beszel_user_id" => "user-safe"
  }
  assertion = {
    "name" => "Evaluate #{name}",
    "ansible.builtin.assert" => { "that" => ["(#{predicate} | bool) == #{expected.to_s.downcase}"] }
  }
  _stdout, _stderr, status = run_play([assertion], vars, vars_files: [ROLE_VARS])
  failures << "Ansible #{name} predicate differs" unless status.success?
end

if resolve_evidence && verify_evidence
  vars = {
    "beszel_telemetry_probe_result" => {
      "evidence" => {
        "system_id" => "system-safe", "system_stats_id" => "[invalid]",
        "container_stats_id" => "container-stats-safe",
        "missing_categories" => %w[core disk gpu]
      }
    }
  }
  stdout, stderr, status = run_play([resolve_evidence, verify_evidence], vars)
  output = stdout + stderr
  failures << "Ansible malformed telemetry unexpectedly verified" if status.success?
  failures << "Ansible malformed telemetry omitted safe category diagnostics" unless
    output.include?("core,disk,gpu")
  failures << "Ansible malformed telemetry omitted safe system ID" unless output.include?("system-safe")
  failures << "Ansible malformed telemetry did not sanitize the record ID" unless output.include?("[invalid]")
  failures << "Ansible malformed telemetry leaked an unsafe record ID" if output.include?("sensitive password")
  failures << "Ansible malformed telemetry emitted a template traceback" if output.include?("Traceback")
end

server = TCPServer.new("127.0.0.1", 0)
server_thread = Thread.new do
  2.times do
    client = server.accept
    request_line = client.gets.to_s
    loop do
      header = client.gets
      break if header.nil? || header == "\r\n"
    end
    record = request_line.include?("system_stats") ? valid_system_stats : valid_container_stats
    body = JSON.generate("items" => [record])
    client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
    client.write("Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    client.close
  end
ensure
  server.close
end
probe_task = {
  "name" => "Run the production deadline-aware telemetry probe",
  "beszel_telemetry_probe" => {
    "api_url" => "http://127.0.0.1:#{server.local_address.ip_port}",
    "auth_token" => "test-token", "system_id" => "system-safe",
    "required_categories" => %w[core disk containers gpu], "freshness_seconds" => 180,
    "timeout_seconds" => 90, "request_timeout_seconds" => 3, "delay_seconds" => 3
  },
  "register" => "probe_result", "no_log" => true
}
probe_assertion = {
  "name" => "Require the production probe evidence",
  "ansible.builtin.assert" => { "that" => ["probe_result.evidence.missing_categories | length == 0"] }
}
stdout, stderr, status = run_play([probe_task, probe_assertion], {})
probe_output = stdout + stderr
unless server_thread.join(5)
  server.close
  server_thread.kill
  failures << "production telemetry module did not request both persisted collections: #{probe_output}"
end
failures << "production telemetry module failed under real Ansible: #{probe_output}" unless status.success?

abort failures.join("\n") unless failures.empty?
puts "Beszel Ansible telemetry policy passed"
