#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "json"
require "socket"
require "tmpdir"
require "time"
require "yaml"

require_relative "policy_support"

ROOT = File.expand_path("..", __dir__)
ROLE_TASKS = File.join(ROOT, "roles/beszel/tasks/main.yml")
ROLE_VARS = File.join(ROOT, "roles/beszel/vars/main.yml")

# This test executes real ansible-playbook runs and asserts exact output, so it is
# pinned to the version CI installs rather than tolerating a range. Stated once and
# maintained by Renovate; tests/ci/workflow_test.rb proves it still matches ci.yml.
REQUIRED_ANSIBLE_CORE = "2.21.4" # renovate: datasource=pypi depName=ansible-core

version_output, version_status = Open3.capture2("ansible-playbook", "--version")
abort "Beszel Ansible telemetry test requires ansible-core #{REQUIRED_ANSIBLE_CORE}" unless
  version_status.success? &&
  version_output.start_with?("ansible-playbook [core #{REQUIRED_ANSIBLE_CORE}]")

def run_play(tasks, vars, vars_files: [], check: false)
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
      "-c", "local", *(check ? ["--check"] : []), path
    )
  end
end

failures = []
# Read through static_role_tasks: the role is one stage per file and main.yml is
# an index of static imports, so the capability assertion lives in deploy.yml and
# the telemetry tasks in configure.yml. A bare read of the index finds none of
# them and would report the assertions absent rather than exercising them.
tasks = PolicySupport.flatten_tasks(PolicySupport.static_role_tasks(ROLE_TASKS))
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

# A declared S.M.A.R.T. device that is not a device node on the host renders
# /dev/null in its slot and warns, and the run does not fail: a devices: entry
# naming an absent node stops the agent starting, so failing or passing it
# through would block every deploy. Run through the role's own stat and warning
# tasks and its own env.j2, against one present character device per list, a
# regular file (which Docker refuses as firmly as an absent path) and two
# absent paths. Under --check the stat must still run, or the warning is lost.
smart_stat = tasks.find { |task| task["name"] == "Look for each declared S.M.A.R.T. device node on this host" }
smart_warn = tasks.find { |task| task["name"] == "Warn about declared S.M.A.R.T. devices absent from this host" }
failures << "Beszel S.M.A.R.T. device presence tasks are absent" unless smart_stat && smart_warn
if smart_stat && smart_warn
  Dir.mktmpdir("beszel-smart-slots") do |dir|
    env_path = File.join(dir, "beszel.env")
    render = { "name" => "Render the Beszel environment",
               "ansible.builtin.template" => {
                 "src" => File.join(ROOT, "roles/beszel/templates/env.j2"), "dest" => env_path, "mode" => "0600"
               } }
    smart_vars = {
      "platform_smart_sata_devices" => ["/dev/zero", ROLE_VARS, "/dev/beszel-contract-absent-sata"],
      "platform_smart_nvme_namespaces" => ["/dev/beszel-contract-absent-nvme", "/dev/random"],
      "nas_timezone" => "UTC", "platform_effective_container_cpuset" => "0-2",
      "nas_docker_root" => dir, "nas_media_root" => dir,
      "platform_render_device_path" => "/dev/dri/renderD128", "beszel_app_url" => "http://127.0.0.1:8090",
      "beszel_port" => 8090, "beszel_system_name" => "contract", "platform_project_name" => "",
      "vault_beszel_agent_key" => "contract-key", "vault_beszel_universal_token" => "contract-token"
    }
    expected_slots = {
      "NAS_SMART_SATA_DEVICE_1" => "/dev/zero",
      "NAS_SMART_SATA_DEVICE_2" => "/dev/null",
      "NAS_SMART_SATA_DEVICE_3" => "/dev/null",
      "NAS_SMART_NVME_NAMESPACE_1" => "/dev/null",
      "NAS_SMART_NVME_NAMESPACE_2" => "/dev/random"
    }
    expected_warnings = [
      "#{ROLE_VARS} is declared in inventory for NAS_SMART_SATA_DEVICE_2",
      "/dev/beszel-contract-absent-sata is declared in inventory for NAS_SMART_SATA_DEVICE_3",
      "/dev/beszel-contract-absent-nvme is declared in inventory for NAS_SMART_NVME_NAMESPACE_1"
    ]
    [false, true].each do |check|
      mode = check ? "under --check" : "on a converge"
      stdout, stderr, status = run_play([smart_stat, smart_warn, render], smart_vars,
                                        vars_files: [ROLE_VARS], check: check)
      failures << "an absent S.M.A.R.T. device failed the run #{mode}: #{stderr.lines.last(3).join}" unless status.success?
      expected_warnings.each do |warning|
        failures << "no warning #{mode} that #{warning}" unless stdout.include?("WARNING: #{warning}")
      end
      failures << "a present S.M.A.R.T. device was warned about #{mode}" if
        stdout.match?(%r{WARNING: /dev/(zero|random) })
      next if check

      rendered = File.file?(env_path) ? PolicySupport.environment_assignments(env_path).to_h : {}
      expected_slots.each do |name, value|
        failures << "#{name} rendered #{rendered[name].inspect}, not #{value}" unless rendered[name] == value
      end
    end
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
