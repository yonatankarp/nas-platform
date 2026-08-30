#!/usr/bin/env ruby

require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

require_relative "policy_support"

include TestScaffold

TASKS_PATH = File.join(ROOT, "roles", "host_prep", "tasks", "verify_media_acquisition.yml")
VERIFY_PATH = File.join(ROOT, "verify.yml")

EXPECTED_CLASSES = { "cache" => 10, "user" => 7, "critical" => 11 }.freeze
EXPECTED_READERS = %w[audiobookshelf jellyfin].freeze

def reader_name_expression(reader)
  "{{ #{reader}_container_name | default((platform_project_name ~ '-#{reader}') if platform_project_name | default('') | length > 0 else '#{reader}', true) }}"
end

def reader_project_expression(reader)
  "{{ #{reader}_compose_project_name | default((platform_project_name ~ '-#{reader}') if platform_project_name | default('') | length > 0 else '#{reader}', true) }}"
end

def reader_default_network_expression(reader)
  "{{ (#{reader}_compose_project_name | default((platform_project_name ~ '-#{reader}') if platform_project_name | default('') | length > 0 else '#{reader}', true)) ~ '_default' }}"
end

def normalize_expression(value)
  value.to_s.gsub(/\s+/, " ").strip
end

def verifier_problems(tasks, verify_play)
  problems = []
  flat = PolicySupport.flatten_tasks(tasks)
  selector = flat.find { |task| task["name"] == "Select media acquisition foundation storage" }
  selected = selector&.dig("ansible.builtin.set_fact", "host_prep_media_acquisition_storage")
  problems << "verifier must select only entries with the literal foundation marker" unless
    selected.to_s.include?("selectattr('media_acquisition_foundation', 'defined') |") &&
      selected.to_s.include?("selectattr('media_acquisition_foundation', 'equalto', true)")

  stat = flat.find { |task| task["ansible.builtin.stat"] }
  problems << "verifier must inspect every selected path without following symlinks" unless
    stat&.dig("ansible.builtin.stat", "path") == "{{ item.path }}" &&
      stat&.dig("ansible.builtin.stat", "follow") == false &&
      stat["loop"] == "{{ host_prep_media_acquisition_storage }}"

  assertions = flat.select { |task| task["ansible.builtin.assert"] }
  conditions = assertions.flat_map { |task| Array(task.dig("ansible.builtin.assert", "that")) }
  required = [
    "host_prep_media_acquisition_storage | length == 28",
    "host_prep_media_acquisition_storage | map(attribute='path') | unique | length == 28",
    "host_prep_media_acquisition_storage | selectattr('recovery', 'equalto', 'cache') | list | length == 10",
    "host_prep_media_acquisition_storage | selectattr('recovery', 'equalto', 'user') | list | length == 7",
    "host_prep_media_acquisition_storage | selectattr('recovery', 'equalto', 'critical') | list | length == 11",
    "host_prep_media_acquisition_storage | map(attribute='mode') | unique | list == ['0755']",
    "host_prep_media_acquisition_storage_stats.results | length == 28",
    # Usenet is deliberately absent: the NAS enabled it through Phase 1, and a
    # verifier that required it off would fail the host that completed the
    # handoff. Torrent remains inert on every host.
    "not (media_torrent_enabled | bool)"
  ]
  required.each { |condition| problems << "verifier omits exact assertion: #{condition}" unless conditions.include?(condition) }
  problems << "verifier must require each path to be an existing real directory with mode 0755" unless
    conditions.include?("item.stat.exists") && conditions.include?("item.stat.isdir") &&
      conditions.include?("not item.stat.islnk") && conditions.include?("item.stat.mode == '0755'")

  network_info = flat.find { |task| task["community.docker.docker_network_info"] }
  problems << "verifier must inspect the exact derived media-control network" unless
    network_info&.dig("community.docker.docker_network_info", "name") == "{{ platform_media_control_network }}"
  network_conditions = conditions.grep(/host_prep_media_acquisition_network/)
  %w[exists Name Driver nas.platform.purpose nas.platform.project].each do |token|
    problems << "verifier omits exact network proof for #{token}" unless network_conditions.any? { |item| item.include?(token) }
  end

  readers = flat.select { |task| task["community.docker.docker_container_info"] }
  problems << "verifier must inspect exactly the two derived reader containers" unless
    readers.length == 1 && readers.first["loop"] == "{{ host_prep_media_acquisition_readers }}" &&
      readers.first.dig("community.docker.docker_container_info", "name") == "{{ item.name }}"
  declared_readers = selector&.dig("ansible.builtin.set_fact", "host_prep_media_acquisition_readers")
  EXPECTED_READERS.each do |reader|
    declared_reader = Array(declared_readers).find { |item| item["service"] == reader }
    exact_identity = declared_reader &&
      normalize_expression(declared_reader["name"]) == reader_name_expression(reader) &&
      normalize_expression(declared_reader["project"]) == reader_project_expression(reader) &&
      Array(declared_reader["networks"]).map { |network| normalize_expression(network) } == [
        reader_default_network_expression(reader),
        "{{ platform_media_control_network }}"
      ]
    problems << "verifier must pin reader #{reader} name, service, project and two network keys" unless
      exact_identity
  end
  problems << "verifier must compare reader network keys exactly" unless
    conditions.any? { |item| item.include?("NetworkSettings.Networks.keys() | sort") && item.include?("item.item.networks | sort") }
  problems << "verifier must use the production project-label fallback" unless
    conditions.include?("host_prep_media_acquisition_network.network.Labels['nas.platform.project'] == (platform_project_name | default('nas-platform', true))")

  mutating_modules = %w[ansible.builtin.file community.docker.docker_network community.docker.docker_container community.docker.docker_compose_v2]
  problems << "verifier tasks must remain read-only" if flat.any? { |task| mutating_modules.any? { |mod| task.key?(mod) } }
  problems << "verifier tasks must be explicitly unchanged" unless
    flat.all? { |task| task["changed_when"] == false }

  play = Array(verify_play).first || {}
  includes = Array(play["tasks"]).select { |task| task.dig("ansible.builtin.include_role", "name") == "host_prep" }
  include_task = includes.one? ? includes.first : nil
  include_role = include_task ? include_task.fetch("ansible.builtin.include_role", {}) : {}
  problems << "verify.yml must explicitly include only the standalone host_prep verifier" unless
    include_role["tasks_from"] == "verify_media_acquisition" &&
      Array(include_role.dig("apply", "tags")) == ["platform_verify_media_acquisition_foundation"] &&
      Array(include_task["tags"]) == %w[never platform_verify_media_acquisition_foundation]
  problems << "verify.yml must never load host_prep as a plain role" if
    Array(play["roles"]).any? { |role| role == "host_prep" || role.is_a?(Hash) && role["role"] == "host_prep" }
  problems
end

def run_selector_probe(tasks, directory)
  selector = deep_copy(Array(tasks).find { |task| task["name"] == "Select media acquisition foundation storage" })
  play = {
    "name" => "Evaluate mixed media acquisition storage selection",
    "hosts" => "localhost",
    "gather_facts" => false,
    "vars" => {
      "platform_project_name" => "probe",
      "platform_media_control_network" => "probe-media-control",
      "nas_storage" => [
        { "path" => "/marked", "media_acquisition_foundation" => true },
        { "path" => "/unmarked" },
        { "path" => "/false", "media_acquisition_foundation" => false }
      ]
    },
    "tasks" => [
      selector,
      {
        "name" => "Require only the marked entry",
        "ansible.builtin.assert" => {
          "that" => [
            "host_prep_media_acquisition_storage | length == 1",
            "host_prep_media_acquisition_storage[0].path == '/marked'"
          ]
        }
      }
    ]
  }
  path = File.join(directory, "selector-probe.yml")
  File.write(path, YAML.dump([play]))
  Open3.capture3("ansible-playbook", "-i", "localhost,", "-c", "local", path)
end

def selector_probe_problems(tasks)
  Dir.mktmpdir("media-acquisition-selector.") do |directory|
    stdout, stderr, status = run_selector_probe(tasks, directory)
    problems = []
    problems << "mixed marked/unmarked selector fails real Ansible evaluation: #{(stdout + stderr).lines.last}" unless status.success?

    mutation = deep_copy(tasks)
    selector = mutation.find { |task| task["name"] == "Select media acquisition foundation storage" }
    expression = selector.dig("ansible.builtin.set_fact", "host_prep_media_acquisition_storage")
    selector["ansible.builtin.set_fact"]["host_prep_media_acquisition_storage"] =
      expression.gsub(/\s*selectattr\('media_acquisition_foundation', 'defined'\) \|/, "")
    mutant_stdout, mutant_stderr, mutant_status = run_selector_probe(mutation, directory)
    if mutant_status.success? || !(mutant_stdout + mutant_stderr).match?(/undefined|has no attribute/i)
      problems << "selector accepts removal of the defined-attribute guard"
    end
    problems
  end
rescue Errno::ENOENT
  ["ansible-playbook is required for the selector evaluation probe"]
end

def run_identity_probe(tasks, directory, namespace)
  selector = deep_copy(Array(tasks).find { |task| task["name"] == "Select media acquisition foundation storage" })
  network_assertion = Array(tasks).find { |task| task["name"] == "Require the exact isolated media control bridge" }
  network_project_condition = Array(network_assertion&.dig("ansible.builtin.assert", "that")).find do |condition|
    condition.include?("Labels['nas.platform.project']")
  end
  prefix = namespace == :mac ? "probe" : nil
  expected_project_label = prefix || "nas-platform"
  vars = {
    "platform_media_control_network" => prefix ? "#{prefix}-media-control" : "media-control",
    "host_prep_media_acquisition_network" => {
      "network" => { "Labels" => { "nas.platform.project" => expected_project_label } }
    },
    "nas_storage" => []
  }
  vars["platform_project_name"] = prefix if prefix
  assertions = EXPECTED_READERS.flat_map do |reader|
    expected = prefix ? "#{prefix}-#{reader}" : reader
    index = EXPECTED_READERS.index(reader)
    [
      "host_prep_media_acquisition_readers[#{index}].name == '#{expected}'",
      "host_prep_media_acquisition_readers[#{index}].project == '#{expected}'",
      "host_prep_media_acquisition_readers[#{index}].networks == ['#{expected}_default', '#{vars.fetch('platform_media_control_network')}']"
    ]
  end
  assertions << network_project_condition
  play = {
    "name" => "Evaluate #{namespace} media reader identities",
    "hosts" => "localhost",
    "gather_facts" => false,
    "vars" => vars,
    "tasks" => [
      selector,
      {
        "name" => "Require exact #{namespace} media reader identities",
        "ansible.builtin.assert" => { "that" => assertions }
      }
    ]
  }
  path = File.join(directory, "#{namespace}-identity-probe.yml")
  File.write(path, YAML.dump([play]))
  Open3.capture3("ansible-playbook", "-i", "localhost,", "-c", "local", path)
end

def identity_probe_problems(tasks)
  Dir.mktmpdir("media-acquisition-identities.") do |directory|
    problems = []
    %i[nas mac].each do |namespace|
      stdout, stderr, status = run_identity_probe(tasks, directory, namespace)
      problems << "#{namespace} identity probe fails real Ansible evaluation: #{(stdout + stderr).lines.last}" unless status.success?
    end
    problems
  end
rescue Errno::ENOENT
  ["ansible-playbook is required for the identity evaluation probes"]
end

def load_yaml(path)
  YAML.safe_load_file(path, aliases: true)
rescue Errno::ENOENT
  nil
end

def deep_copy(value)
  Marshal.load(Marshal.dump(value))
end

def run_include_probe(play, directory)
  path = File.join(directory, "probe.yml")
  File.write(path, YAML.dump([play]))
  Open3.capture3(
    { "ANSIBLE_ROLES_PATH" => File.join(directory, "roles") },
    "ansible-playbook", "-i", "localhost,", "-c", "local", path,
    "--tags", "platform_verify_media_acquisition_foundation"
  )
end

def include_probe_problems(verify_play)
  problems = []
  source_play = Array(verify_play).first
  include_task = deep_copy(Array(source_play["tasks"]).find do |task|
    task.dig("ansible.builtin.include_role", "name") == "host_prep"
  end)
  return ["standalone include probe cannot find the host_prep verifier include"] unless include_task

  Dir.mktmpdir("media-acquisition-verifier.") do |directory|
    tasks_dir = File.join(directory, "roles", "host_prep", "tasks")
    FileUtils.mkdir_p(tasks_dir)
    File.write(File.join(tasks_dir, "verify_media_acquisition.yml"), YAML.dump([
      { "name" => "Standalone verifier selected", "ansible.builtin.debug" => { "msg" => "selected" } }
    ]))
    File.write(File.join(tasks_dir, "main.yml"), YAML.dump([
      { "name" => "MUTATING MAIN SENTINEL", "ansible.builtin.fail" => { "msg" => "mutating main loaded" } }
    ]))
    base_play = {
      "name" => "Probe standalone verifier selection",
      "hosts" => "localhost",
      "gather_facts" => false,
      "tasks" => [include_task]
    }
    stdout, stderr, status = run_include_probe(base_play, directory)
    problems << "standalone verifier tag loaded host_prep main: #{(stdout + stderr).lines.last}" unless status.success?

    mutants = {
      "tasks_from removal" => proc { |play| play["tasks"].first["ansible.builtin.include_role"].delete("tasks_from") },
      "tasks_from main" => proc { |play| play["tasks"].first["ansible.builtin.include_role"]["tasks_from"] = "main" },
      "tasks_from change" => proc { |play| play["tasks"].first["ansible.builtin.include_role"]["tasks_from"] = "missing_verifier" },
      "plain role" => proc do |play|
        play.delete("tasks")
        play["roles"] = [{ "role" => "host_prep", "tags" => ["platform_verify_media_acquisition_foundation"] }]
      end
    }
    mutants.each do |label, mutate|
      mutation = deep_copy(base_play)
      mutate.call(mutation)
      _mutant_stdout, _mutant_stderr, mutant_status = run_include_probe(mutation, directory)
      problems << "standalone verifier accepts #{label} mutant" if mutant_status.success?
    end
  end
  problems
rescue Errno::ENOENT
  ["ansible-playbook is required for the standalone include probe"]
end

tasks = load_yaml(TASKS_PATH)
verify_play = load_yaml(VERIFY_PATH)
failures = verifier_problems(tasks, verify_play)
failures.concat(selector_probe_problems(tasks)) if tasks
failures.concat(identity_probe_problems(tasks)) if tasks
failures.concat(include_probe_problems(verify_play)) if failures.empty?

unless failures.any?
  selector = tasks.find { |task| task["name"] == "Select media acquisition foundation storage" }
  readers = selector.dig("ansible.builtin.set_fact", "host_prep_media_acquisition_readers")
  mutation_cases = {
    "missing storage leaf assertion" => proc do |copy|
      assertion = copy.find { |task| task["name"] == "Require every media acquisition path to be a real mode 0755 directory" }
      assertion.dig("ansible.builtin.assert", "that").delete("item.stat.exists")
    end,
    "audiobookshelf missing default network" => proc do |copy|
      copy.first.dig("ansible.builtin.set_fact", "host_prep_media_acquisition_readers").first["networks"].shift
    end,
    "audiobookshelf missing control network" => proc do |copy|
      copy.first.dig("ansible.builtin.set_fact", "host_prep_media_acquisition_readers").first["networks"].pop
    end,
    "jellyfin missing default network" => proc do |copy|
      copy.first.dig("ansible.builtin.set_fact", "host_prep_media_acquisition_readers").last["networks"].shift
    end,
    "jellyfin missing control network" => proc do |copy|
      copy.first.dig("ansible.builtin.set_fact", "host_prep_media_acquisition_readers").last["networks"].pop
    end,
    "deceptive reader name" => proc do |copy|
      copy.first.dig("ansible.builtin.set_fact", "host_prep_media_acquisition_readers").first["name"] += "-lookalike"
    end,
    "deceptive reader service" => proc do |copy|
      copy.first.dig("ansible.builtin.set_fact", "host_prep_media_acquisition_readers").first["service"] += "-lookalike"
    end,
    "deceptive reader project" => proc do |copy|
      copy.first.dig("ansible.builtin.set_fact", "host_prep_media_acquisition_readers").first["project"] += "-lookalike"
    end,
    "direct Mac-only reader identity assumption" => proc do |copy|
      copy.first.dig("ansible.builtin.set_fact", "host_prep_media_acquisition_readers").each do |reader|
        service = reader.fetch("service")
        reader["name"] = "{{ platform_project_name }}-#{service}"
        reader["project"] = "{{ platform_project_name }}-#{service}"
        reader["networks"][0] = "{{ platform_project_name }}-#{service}_default"
      end
    end
  }
  mutation_cases.each do |label, mutate|
    mutation = deep_copy(tasks)
    mutate.call(mutation)
    failures << "verifier accepts #{label}" if verifier_problems(mutation, verify_play).empty?
  end
end

report(failures, "media acquisition verifier: standalone read-only contract holds",
       "media acquisition verifier regression(s)")
