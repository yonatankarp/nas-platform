#!/usr/bin/env ruby
# Platform and preflight policy.
#
# Machine facts stay host-scoped and portable configuration stays shared, every
# inventory names the same platform hierarchy, preflight refuses empty endpoint
# coordinates and adjudicates its own write probe before creating it, and declared
# storage matches what the roles mount. Split out of policy_test.rb.

require "open3"
require "rbconfig"
require "set"
require "yaml"
require_relative "policy_support"

include PolicySupport

ROOT = File.expand_path("..", __dir__)
failures = []

def check(failures, condition, message)
  failures << message unless condition
end

PLATFORM_CAPABILITIES = %w[
  platform_container_cpu_budget
  platform_render_device_available platform_render_device_path
  platform_beszel_agent_available platform_beszel_agent_kind
].freeze
PLATFORM_TELEMETRY_POLICY = %w[
  beszel_required_telemetry_categories beszel_require_gpu_telemetry
].freeze
PLATFORM_INVENTORIES = {
  "local.yml" => ["nas_hosts", "nas", "local", "nas"],
  "remote.yml" => ["nas_hosts", "nas", "ssh", "nas"],
  "mac.yml" => ["mac_hosts", "mac", "local", "mac"]
}.freeze
HOST_SCOPED_VARS = (
  %w[platform_kind nas_docker_root nas_media_root] + PLATFORM_CAPABILITIES +
    PLATFORM_TELEMETRY_POLICY
).freeze

shared_vars = YAML.safe_load_file(File.join(ROOT, "inventory", "group_vars", "all", "main.yml"))
shared_machine_facts = shared_vars.keys & HOST_SCOPED_VARS
check(failures, shared_machine_facts.empty?,
      "machine facts must not be all-group variables: #{shared_machine_facts.join(', ')}")

PLATFORM_INVENTORIES.values.map { |values| [values[0], values[3]] }.uniq.each do |host_group, platform_kind|
  relative_path = File.join("inventory", "group_vars", host_group, "main.yml")
  path = File.join(ROOT, relative_path)
  host_vars = begin
    YAML.safe_load_file(path)
  rescue Errno::ENOENT
    check(failures, false, "#{relative_path} is missing")
    {}
  rescue Psych::Exception => e
    check(failures, false, "#{relative_path} is malformed: #{e.message.lines.first.strip}")
    {}
  end

  check(failures, host_vars["platform_kind"] == platform_kind,
        "#{relative_path} platform_kind must be #{platform_kind}")
  PLATFORM_CAPABILITIES.each do |capability|
    check(failures, host_vars.key?(capability),
          "#{relative_path} must define #{capability}")
  end
  expected_cpu_budget = platform_kind == "nas" ? 3 : 0
  check(failures, host_vars["platform_container_cpu_budget"] == expected_cpu_budget,
        "#{relative_path} platform_container_cpu_budget must be #{expected_cpu_budget}")
  PLATFORM_TELEMETRY_POLICY.each do |policy|
    check(failures, host_vars.key?(policy),
          "#{relative_path} must define #{policy}")
  end
  %w[platform_render_device_available platform_beszel_agent_available].each do |capability|
    check(failures, [true, false].include?(host_vars[capability]),
          "#{relative_path} #{capability} must be boolean")
  end
  check(failures, host_vars["platform_render_device_path"].is_a?(String) &&
                  !host_vars["platform_render_device_path"].empty?,
        "#{relative_path} platform_render_device_path must be a nonempty path")
  mac_runtime_facts = if platform_kind == "mac"
                        %w[
                          platform_project_name beszel_port ntfy_port dozzle_port
                          audiobookshelf_port komga_port tinymediamanager_web_port
                          tinymediamanager_api_port jellyfin_port immich_port paperless_port
                        ]
                      else
                        []
                      end
  unexpected_vars = host_vars.keys - HOST_SCOPED_VARS - mac_runtime_facts
  check(failures, unexpected_vars.empty?,
        "#{relative_path} contains portable configuration: #{unexpected_vars.join(', ')}")
end

site_play = YAML.safe_load_file(File.join(ROOT, "site.yml")).first
check(failures, site_play["hosts"] == "platform_hosts",
      "site.yml must target platform_hosts")
check(failures, site_play.dig("vars", "platform_vault_file").to_s.include?(
  "inventory/group_vars/all/vault.yml"
), "site.yml must identify the encrypted deployment vault for SHA-256 reporting")

preflight_options = YAML.safe_load_file(
  File.join(ROOT, "roles", "preflight", "meta", "argument_specs.yml")
).dig("argument_specs", "main", "options")
(PLATFORM_CAPABILITIES + %w[platform_kind platform_public_host platform_callback_host]).each do |option|
  check(failures, preflight_options.is_a?(Hash) && preflight_options[option].is_a?(Hash) &&
                  preflight_options[option]["required"] == true,
        "preflight argument specs must require #{option}")
end

check(failures, preflight_options.dig("platform_kind", "choices") == %w[nas mac],
      "preflight platform_kind must allow only nas or mac")
preflight_tasks = YAML.safe_load_file(
  File.join(ROOT, "roles", "preflight", "tasks", "main.yml")
)
endpoint_guard = preflight_tasks.first
endpoint_conditions = Array(endpoint_guard&.dig("ansible.builtin.assert", "that")).join(" ")
check(failures, endpoint_guard&.dig("name") ==
                "Require explicit nonempty application endpoint coordinates" &&
                endpoint_conditions.include?("platform_public_host | length > 0") &&
                endpoint_conditions.include?("platform_callback_host | length > 0"),
      "preflight must reject empty public and callback host coordinates first")
mount_table_task = preflight_tasks.find { |task| task["name"] == "Read the kernel mount table" }
mount_guard_task = preflight_tasks.find do |task|
  task["name"] == "Require the NAS volumes to be mounted"
end
mount_guard_argv = Array(mount_guard_task&.dig("ansible.builtin.command", "argv"))
mount_guard_conditions = Array(mount_guard_task&.fetch("when", []))
check(failures,
      mount_table_task.nil? &&
        mount_guard_argv.first == "awk" &&
        mount_guard_argv.include?("target={{ item }}") &&
        mount_guard_argv.include?("/proc/mounts") &&
        mount_guard_argv.any? { |argument| argument.include?("$2 == target") } &&
        mount_guard_conditions.include?("platform_kind == 'nas'") &&
        mount_guard_conditions.include?("item is match('^/volume')") &&
        mount_guard_task["changed_when"] == false &&
        mount_guard_task["check_mode"] == false,
      "preflight must check mounts by command exit status, including in check mode")
# The detection moved into a shared task file so verify.yml can establish the
# same fact without running all of preflight.
preflight_gpu_tasks = YAML.safe_load_file(
  File.join(ROOT, "roles", "preflight", "tasks", "gpu.yml")
)
gpu_fact_task = preflight_gpu_tasks.find do |task|
  task["name"] == "Record whether hardware acceleration is available"
end
gpu_expression = gpu_fact_task&.dig("ansible.builtin.set_fact", "preflight_gpu_available").to_s
check(failures, gpu_expression.include?("platform_render_device_available") &&
                gpu_expression.include?("preflight_render_device.stat.exists") &&
                gpu_expression.include?("preflight_render_device.stat.ischr"),
      "GPU availability must require declared capability and an existing character device")

mac_vars = YAML.safe_load_file(
  File.join(ROOT, "inventory", "group_vars", "mac_hosts", "main.yml")
)
{
  "nas_docker_root" => "PLATFORM_DOCKER_ROOT",
  "nas_media_root" => "PLATFORM_MEDIA_ROOT"
}.each do |variable, environment_variable|
  expression = mac_vars[variable].to_s
  check(failures, expression.include?("lookup('env', '#{environment_variable}')") &&
                  expression.include?("| platform_physical_path"),
        "Mac #{variable} must canonicalize #{environment_variable} before export")
end

storage = YAML.safe_load_file(File.join(ROOT, "inventory", "group_vars", "all", "main.yml"))
declared_paths = storage.fetch("nas_storage").map { |entry| entry.fetch("path") }
paperless_postgres_storage = storage.fetch("nas_storage").find do |entry|
  entry["path"] == "{{ nas_docker_root }}/paperless-ngx/postgres"
end
check(failures,
      paperless_postgres_storage && paperless_postgres_storage["mode"] == "0755",
      "Paperless PostgreSQL 18 mount parent must be traversable by the postgres user")
# Preflight adjudicates its own debris: the deterministic probe path is the role's
# leftovers after an interrupted run, so an empty directory self-heals while
# anything that could be real data still refuses.
preflight_body = File.read(File.join(ROOT, "roles", "preflight", "tasks", "main.yml"))
preflight_probe_tasks = flatten_tasks(YAML.safe_load(preflight_body))
# Read from the parsed tasks rather than the file's bytes. The three names below
# all appear in the role's own explanatory comments, so a whole-file substring
# check was satisfied by the commentary alone, and it never said that the derived
# fact came from the capacity the docker info task actually registered.
docker_capacity = preflight_probe_tasks.find do |task|
  Array(task.dig("ansible.builtin.command", "argv")) == %w[docker info --format json]
end
effective_cpuset = preflight_probe_tasks.filter_map do |task|
  task.dig("ansible.builtin.set_fact", "platform_effective_container_cpuset")
end.first.to_s
check(failures,
      docker_capacity && !docker_capacity["register"].to_s.empty? &&
        effective_cpuset.include?("platform_container_cpuset") &&
        effective_cpuset.include?(docker_capacity["register"].to_s),
      "preflight must derive the effective container CPU set from Docker capacity")
# Every task that touches the probe has to touch the same validated path. Read as
# text this was two substring checks, one of which only ruled out the single
# wrong path that happened to have been used before.
probe_path = "{{ nas_docker_root }}/.nas-platform-preflight-probe"
probe_targets = task_path_arguments(preflight_probe_tasks).grep(/preflight-probe/)
check(failures, probe_targets.length >= 4 && probe_targets.uniq == [probe_path],
      "fresh-install preflight must probe the existing validated nas_docker_root")
probe_inspection = preflight_probe_tasks.index { |task| task["name"] == "Inspect the deterministic write probe path" }
probe_refusal = preflight_probe_tasks.index { |task| task["name"] == "Refuse to remove a pre-existing write probe path" }
probe_reclaim = preflight_probe_tasks.index do |task|
  task["name"] == "Reclaim the empty write probe directory left by an interrupted run"
end
probe_creation = preflight_probe_tasks.index { |task| task["name"] == "Confirm the service state root is writable" }
probe_conditions = Array(
  probe_refusal ? preflight_probe_tasks.fetch(probe_refusal).dig("ansible.builtin.assert", "that") : nil
).join(" ")
check(failures, probe_inspection && probe_refusal && probe_reclaim && probe_creation &&
                probe_inspection < probe_refusal && probe_refusal < probe_reclaim &&
                probe_reclaim < probe_creation,
      "preflight must inspect and adjudicate a pre-existing deterministic probe before creating it")
# The probe path is the role's own debris after an interrupted run, so an empty
# directory self-heals while anything that could be real data still refuses.
check(failures, probe_inspection &&
                preflight_probe_tasks.fetch(probe_inspection).dig("ansible.builtin.stat", "follow") == false,
      "preflight must inspect the deterministic probe path without following symlinks")
check(failures, probe_conditions.include?("preflight_write_probe.stat.isdir") &&
                probe_conditions.include?("not preflight_write_probe.stat.islnk") &&
                probe_conditions.include?("preflight_write_probe_contents.files"),
      "preflight must refuse a pre-existing probe that is not an empty non-symlink directory")
probe_emptiness = preflight_probe_tasks.find do |task|
  task.dig("ansible.builtin.find", "paths") == "{{ nas_docker_root }}/.nas-platform-preflight-probe"
end
check(failures, probe_emptiness&.dig("ansible.builtin.find", "hidden") == true &&
                probe_emptiness&.dig("ansible.builtin.find", "file_type") == "any",
      "preflight must count hidden and non-file probe children when testing emptiness")
check(failures, probe_reclaim &&
                preflight_probe_tasks.fetch(probe_reclaim).dig("ansible.builtin.file", "state") == "absent" &&
                preflight_probe_tasks.fetch(probe_reclaim)["changed_when"] == false,
      "preflight must reclaim the stale probe directory without reporting a change")



if failures.empty?
  puts "platform policy: all properties hold"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} platform policy violation(s)"
end
