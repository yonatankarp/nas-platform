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

# Exact output is asserted, so pinned to CI's version (tests/ci/workflow_test.rb checks).
REQUIRED_ANSIBLE_CORE = "2.21.5" # renovate: datasource=pypi depName=ansible-core

version_output, version_status = Open3.capture2("ansible-playbook", "--version")
abort "Beszel Ansible telemetry test requires ansible-core #{REQUIRED_ANSIBLE_CORE}" unless
  version_status.success? &&
  version_output.start_with?("ansible-playbook [core #{REQUIRED_ANSIBLE_CORE}]")

def run_play(tasks, vars, vars_files: [], check: false, tags: nil)
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
      "-c", "local", *(check ? ["--check"] : []), *(tags ? ["--tags", tags] : []), path
    )
  end
end

failures = []
# static_role_tasks: main.yml is only an index of stage imports.
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

# An absent or non-device S.M.A.R.T. node renders /dev/null and warns rather than failing
# (a missing devices: entry stops the agent). The stat must still run under --check.
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
      "vault_beszel_agent_key" => "contract-key", "vault_beszel_universal_token" => "contract-token",
      # The inventory's own expression: env.j2 renders it.
      "platform_alert_relay_network" =>
        YAML.safe_load_file(File.join(ROOT, "inventory/group_vars/all/main.yml"),
                            aliases: true).fetch("platform_alert_relay_network")
    }
    expected_slots = {
      "PLATFORM_ALERT_RELAY_NETWORK" => "alert-relay",
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
      unless status.success?
        output = stdout + stderr
        reason = output.lines.grep(/fatal:|ERROR!/).last(3)
        failures << "an absent S.M.A.R.T. device failed the run #{mode}: " \
                    "#{(reason.empty? ? output.lines.last(3) : reason).join}"
      end
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

# Remote systems through the role's own tasks against injected hub answers; the lane only
# ever meets the absent case.
remote_names = ["Read the remote managed systems", "Require the complete remote system result set",
                "Refuse remote systems outside the managed user relation",
                "Start the remote system renames empty",
                "Resolve remote systems still under a former name",
                "Refuse duplicate remote managed systems",
                "Report planned remote system renames",
                "Rename remote systems to their current name",
                "Report remote systems left under a former name",
                "Report remote systems that have not registered yet"]
remote_tasks = remote_names.map { |name| tasks.find { |task| task["name"] == name } }
remote_include = tasks.find { |task| task["name"] == "Reconcile each remote managed alert" }
if remote_tasks.all? && remote_include
  pair_task = remote_include.slice("loop", "loop_control", "vars").merge(
    "name" => "Print each remote alert pair",
    "ansible.builtin.debug" => {
      "msg" => "PAIR={{ beszel_alert_system_name }}:{{ beszel_alert_system_id }}:{{ beszel_alert.name }}"
    }
  )
  golem = [{ "name" => "Golem", "former_names" => ["golem"],
             "alerts" => [{ "name" => "Status", "value" => 0, "min" => 0 },
                          { "name" => "CPU", "value" => 90, "min" => 10 }] }]
  owned = ->(id, name = "Golem") { { "id" => id, "name" => name, "users" => ["user-safe"] } }
  [
    ["absent", golem, [], 1, true, [], true],
    ["present", golem, [owned.call("sys-golem"), { "id" => "sys-other", "name" => "other", "users" => [] }],
     1, true, ["PAIR=Golem:sys-golem:Status", "PAIR=Golem:sys-golem:CPU"], false],
    # The hub keeps the registered name; the record is renamed and its alerts follow its id.
    ["former name", golem, [owned.call("sys-golem", "golem")], 1, true,
     ["Would rename Beszel system golem (sys-golem) to Golem", "PAIR=Golem:sys-golem:Status"], false, true],
    # A fresh registration beside the old record: the new one is monitored, the old reported.
    ["former name lingering", golem, [owned.call("sys-old", "golem"), owned.call("sys-new")], 1, true,
     ["PAIR=Golem:sys-new:Status", "Beszel system record sys-old still carries a former name"], false, true],
    ["two former records", golem, [owned.call("sys-a", "golem"), owned.call("sys-b", "golem")], 1, false,
     ["Golem:sys-a,Golem:sys-b"], false, true],
    ["duplicate", golem, [owned.call("sys-a"), owned.call("sys-b")], 1, false, ["Golem:sys-a,Golem:sys-b"], false],
    ["wrong owner", golem, [{ "id" => "sys-foreign", "name" => "golem", "users" => ["someone"] }],
     1, false, ["sys-foreign"], false],
    ["incomplete", golem, [], 2, false, [], false],
    ["none declared", [], nil, 0, true, [], false]
  ].each do |label, declared, items, pages, expected_success, expected_lines, expect_absence, check = false|
    vars = { "beszel_user_id" => "user-safe", "beszel_remote_systems" => declared }
    play_tasks = items.nil? ? remote_tasks : remote_tasks.drop(1)
    vars["beszel_remote_systems_read"] = { "json" => { "items" => items, "totalPages" => pages } } unless items.nil?
    stdout, stderr, status = run_play(play_tasks + [pair_task], vars, vars_files: [ROLE_VARS], check: check)
    output = stdout + stderr
    failures << "remote systems #{label}: #{expected_success ? 'failed' : 'was accepted'}: " \
                "#{output.lines.grep(/fatal:|ERROR!/).last(3).join}" unless status.success? == expected_success
    expected_lines.each do |line|
      failures << "remote systems #{label}: output lacks #{line}" unless output.include?(line)
    end
    failures << "remote systems #{label}: absence report #{expect_absence ? 'missing' : 'unexpected'}" unless
      output.include?("Golem has not") == expect_absence
    failures << "remote systems #{label}: reconciled alerts it should not have" if
      expected_lines.none? { |line| line.start_with?("PAIR") } && output.include?("PAIR=")
  end
  rename_task = tasks.find { |task| task["name"] == "Rename remote systems to their current name" }
  failures << "remote system rename runs under verify.yml" if Array(rename_task&.fetch("tags", nil)).any?
else
  failures << "Beszel remote-system tasks are absent"
end

# Alert reconciliation against a fake hub. Under verify an absent alert on a remote system
# is pending the next converge, never a failure (#911); a duplicate or wrong value is.
def with_fake_alert_hub(alerts, keep_creates: true)
  server = TCPServer.new("127.0.0.1", 0)
  requests = []
  thread = Thread.new do
    loop do
      client = server.accept
      request_line = client.gets.to_s
      length = 0
      loop do
        header = client.gets
        break if header.nil? || header == "\r\n"

        length = header.split(":", 2).last.to_i if header.downcase.start_with?("content-length:")
      end
      body = length.positive? ? JSON.parse(client.read(length)) : {}
      method, path = request_line.split
      requests << method
      reply = case method
              when "POST"
                created = body.merge("id" => "alert-#{alerts.length}")
                alerts << created if keep_creates
                created
              when "PATCH" then alerts.find { |a| path.end_with?("/#{a['id']}") }.merge!(body)
              else { "items" => alerts, "totalPages" => 1 }
              end
      payload = JSON.generate(reply)
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
      client.write("Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF
    nil
  end
  yield server.local_address.ip_port, requests
ensure
  server&.close
  thread&.join(5)
end

alert_includes = ["Reconcile each managed alert", "Reconcile each remote managed alert"].map do |name|
  include_task = tasks.find { |task| task["name"] == name }
  include_task&.merge("ansible.builtin.include_tasks" => File.join(ROOT, "roles/beszel/tasks/alert.yml"))
end
if alert_includes.all?
  nas_include, remote_include_task = alert_includes
  status_alert = { "name" => "Status", "value" => 1, "min" => 2 }
  record = ->(id, system, value = 1) { { "id" => id, "system" => system, "name" => "Status", "value" => value, "min" => 2 } }
  verify = "platform_verify_beszel"
  # [label, system, run tags, alerts on the hub, success, output line, POSTs, hub keeps creates]
  [
    ["remote absent under verify", :remote, verify, [], true, "pending the next converge", 0],
    ["remote absent under a converge", :remote, nil, [], true, nil, 1],
    ["remote create lost under a converge", :remote, nil, [], false, "is absent, duplicated, or differs", 1, false],
    ["remote present under verify", :remote, verify, [record.call("a1", "sys-golem")], true, nil, 0],
    ["remote duplicate under verify", :remote, verify,
     [record.call("a1", "sys-golem"), record.call("a2", "sys-golem")], false, "a1,a2", 0],
    ["remote mismatch under verify", :remote, verify, [record.call("a1", "sys-golem", 9)], false,
     "differs from threshold", 0],
    ["NAS absent under verify", :nas, verify, [], false, "is absent, duplicated, or differs", 0],
    ["NAS absent under a converge", :nas, nil, [], true, nil, 1]
  ].each do |label, system, tags, alerts, expected_success, expected_line, expected_posts, keep_creates = true|
    with_fake_alert_hub(alerts, keep_creates: keep_creates) do |port, requests|
      vars = {
        "beszel_port" => port, "beszel_auth" => { "json" => { "token" => "token-safe" } },
        "beszel_user_id" => "user-safe", "beszel_system_name" => "nas", "beszel_alerts" => [status_alert],
        "beszel_systems" => { "json" => { "items" => [{ "id" => "sys-nas", "name" => "nas", "users" => ["user-safe"] }] } },
        "beszel_remote_systems" => [{ "name" => "Golem", "alerts" => [status_alert] }],
        "beszel_remote_systems_read" => {
          "json" => { "items" => [{ "id" => "sys-golem", "name" => "Golem", "users" => ["user-safe"] }], "totalPages" => 1 }
        }
      }
      stdout, stderr, status = run_play([system == :nas ? nas_include : remote_include_task], vars,
                                        vars_files: [ROLE_VARS], tags: tags)
      output = stdout + stderr
      failures << "alerts #{label}: #{expected_success ? 'failed' : 'was accepted'}: " \
                  "#{output.lines.grep(/fatal:|ERROR!/).last(3).join}" unless status.success? == expected_success
      failures << "alerts #{label}: output lacks #{expected_line}" if expected_line && !output.include?(expected_line)
      failures << "alerts #{label}: reported a pending alert it should not have" if
        expected_line != "pending the next converge" && output.include?("pending the next converge")
      failures << "alerts #{label}: #{requests.count('POST')} creations, wanted #{expected_posts}" unless
        requests.count("POST") == expected_posts
      failures << "alerts #{label}: patched an alert under verify" if tags && requests.include?("PATCH")
    end
  end
else
  failures << "Beszel alert include tasks are absent"
end

# The rename against a fake hub: one PATCH of the name alone, on the record's id.
if remote_tasks.all?
  hub_records = [{ "id" => "sys-golem", "name" => "golem", "users" => ["user-safe"] }]
  with_fake_alert_hub(hub_records) do |port, requests|
    vars = {
      "beszel_port" => port, "beszel_auth" => { "json" => { "token" => "token-safe" } },
      "beszel_user_id" => "user-safe",
      "beszel_remote_systems" => [{ "name" => "Golem", "former_names" => ["golem"], "alerts" => [] }],
      "beszel_remote_systems_read" => { "json" => { "items" => hub_records.map(&:dup), "totalPages" => 1 } }
    }
    stdout, stderr, status = run_play(remote_tasks.drop(1), vars, vars_files: [ROLE_VARS])
    failures << "remote rename failed: #{(stdout + stderr).lines.grep(/fatal:|ERROR!/).last(3).join}" unless
      status.success?
    failures << "remote rename sent #{requests.inspect}, wanted one PATCH" unless requests == ["PATCH"]
    failures << "remote rename left #{hub_records.inspect}" unless
      hub_records == [{ "id" => "sys-golem", "name" => "Golem", "users" => ["user-safe"] }]
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
        "missing_categories" => %w[core disk gpu],
        # Returned by the probe on every path (#658); tells an unreadable hub from an idle agent.
        "transient_failures" => 4
      }
    }
  }
  stdout, stderr, status = run_play([resolve_evidence, verify_evidence], vars)
  output = stdout + stderr
  failures << "Ansible malformed telemetry unexpectedly verified" if status.success?
  failures << "Ansible malformed telemetry omitted safe category diagnostics" unless
    output.include?("core,disk,gpu")
  failures << "Ansible malformed telemetry omitted the retried-away fetch count" unless
    output.include?("fetch failures=4")
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
