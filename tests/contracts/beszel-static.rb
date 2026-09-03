#!/usr/bin/env ruby
# The static half of the Beszel service contract: the telemetry policy the
# role declares, its argument validation, the Compose definition's agent and
# socket-proxy shape, the two inventories' capability declarations and the two
# Mac hooks, all decided from the repository alone with nothing deployed.
#
# usage: beszel-static.rb REPOSITORY
#
# PLATFORM_CONTRACT_REPO_DIR names the tree being inspected, which is where
# tests/policy_support.rb is required from -- not the checkout this file lives
# in. Run it through tests/contracts/beszel.sh rather than directly.
root = ARGV.fetch(0)
defaults = YAML.safe_load_file(File.join(root, "roles/beszel/defaults/main.yml"))
vars = YAML.safe_load_file(File.join(root, "roles/beszel/vars/main.yml"))
role_path = File.join(root, "roles/beszel/tasks/main.yml")
contract = File.read(File.join(root, "tests/contracts/beszel.sh"))
probe_path = File.join(root, "library/beszel_telemetry_probe.py")
probe = File.file?(probe_path) ? File.read(probe_path) : ""
probe_support_path = File.join(root, "module_utils/beszel_telemetry.py")
probe_support = File.file?(probe_support_path) ? File.read(probe_support_path) : ""
require File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "tests", "policy_support")
include PolicySupport
# main.yml is read through static_role_tasks, which splices a statically imported
# stage file in where it stands and leaves a dynamic include alone -- the role
# Ansible runs. The Beszel role is one stage per file, so a bare read of the index
# would find none of the required_tasks below and this contract would abort on a
# role it never looked at.
role_tasks = flatten_tasks(PolicySupport.static_role_tasks(role_path))
role_task_names = role_tasks.filter_map { |task| task["name"] if task.is_a?(Hash) }
# Assertions about what the role does read the parsed structure rather than the
# file's bytes: a task name or a registered variable that survives only inside a
# comment is not something the role executes. role_strings collects the strings
# one at a time rather than joining them, because a pattern matched against a
# joined blob spans two unrelated tasks and reports a violation neither contains.
def role_strings(node)
  case node
  when Hash then node.flat_map { |key, value| [key.to_s] + role_strings(value) }
  when Array then node.flat_map { |value| role_strings(value) }
  when String then [node]
  else []
  end
end
specs = YAML.safe_load_file(File.join(root, "roles/beszel/meta/argument_specs.yml"))
compose = YAML.safe_load_file(File.join(root, "services/beszel/compose.yml"), aliases: true)
nas_inventory = YAML.safe_load_file(File.join(root, "inventory/group_vars/nas_hosts/main.yml"))
mac_inventory = YAML.safe_load_file(File.join(root, "inventory/group_vars/mac_hosts/main.yml"))
verify_hook = File.read(File.join(root, "tests/mac/hooks/verify/10-beszel.sh"))
drift_hook = File.read(File.join(root, "tests/mac/hooks/drift/10-beszel.sh"))

def refuse(message)
  abort "Beszel contract failed: #{message}"
end

refuse("runtime contract does not export its resolved repository root") unless
  contract.include?("PLATFORM_CONTRACT_REPO_DIR=$repo_dir\nexport PLATFORM_CONTRACT_REPO_DIR")
refuse("defaults must not silently infer platform telemetry") unless
  defaults["beszel_required_telemetry_categories"] == [] &&
    defaults["beszel_require_gpu_telemetry"] == false
refuse("freshness must cover exactly three one-minute samples") unless
  defaults["beszel_telemetry_freshness_seconds"] == 180
refuse("telemetry polling timeout differs") unless
  defaults["beszel_telemetry_poll_timeout_seconds"] == 90
# Scoped to the one variable rather than to the whole file: naming the required
# categories anywhere else, including in a comment, is not the same as deriving
# them, and matching a literal expression would miss the same inference written
# with different spacing.
effective_categories = vars["beszel_effective_required_telemetry_categories"].to_s
refuse("effective categories must use explicit inventory policy") unless
  vars.key?("beszel_effective_required_telemetry_categories") &&
    !effective_categories.include?("beszel_require_gpu_telemetry")
refuse("telemetry polling must not use derived retry arithmetic") if
  vars.key?("beszel_telemetry_poll_retries") ||
    vars.values.any? { |value| value.to_s.include?("beszel_telemetry_poll_retries") }

options = specs.dig("argument_specs", "main", "options")
{
  "beszel_required_telemetry_categories" => "list",
  "beszel_require_gpu_telemetry" => "bool",
  "beszel_telemetry_freshness_seconds" => "int",
  "beszel_telemetry_poll_timeout_seconds" => "int",
  "beszel_telemetry_request_timeout_seconds" => "int"
}.each do |name, type|
  refuse("#{name} argument validation is absent") unless options.dig(name, "type") == type
end

required_tasks = [
  "Require the selected Beszel telemetry capability",
  "Poll persisted Beszel telemetry collections",
  "Require exactly one managed Beszel system for telemetry",
  "Resolve persisted Beszel telemetry evidence",
  "Verify persisted Beszel telemetry categories"
]
required_tasks.each do |name|
  refuse("missing #{name}") unless role_task_names.include?(name)
end
collection_poll = role_tasks.find { |task| task["name"] == "Poll persisted Beszel telemetry collections" }
refuse("persisted telemetry poll must suppress authenticated results") unless
  collection_poll && collection_poll["no_log"] == true
probe_args = collection_poll && collection_poll["beszel_telemetry_probe"]
refuse("persisted telemetry poll must use one deadline-aware probe") unless probe_args.is_a?(Hash)
refuse("persisted telemetry probe is not authenticated") unless probe_args&.key?("auth_token")
refuse("persisted telemetry probe does not receive the total deadline") unless
  probe_args&.key?("timeout_seconds") && probe_args&.key?("request_timeout_seconds") &&
    probe_args&.key?("delay_seconds")
refuse("deadline probe implementation is absent") unless
  probe.include?("poll_telemetry") && probe_support.include?('fetcher("system_stats"') &&
    probe_support.include?('fetcher("container_stats"')
# The persisted-telemetry evidence has to come out of the probe's own registered
# result. Naming the variable somewhere in the file proved nothing about which
# task produced it or whether anything consumed it.
refuse("role treats live health as persisted telemetry") unless
  collection_poll && collection_poll["register"] == "beszel_telemetry_probe_result" &&
    role_tasks.any? do |task|
      task != collection_poll &&
        role_strings(task).any? { |value| value.include?("beszel_telemetry_probe_result.evidence") }
    end

intel = compose.fetch("services").fetch("agent-intel")
portable = compose.fetch("services").fetch("agent-portable")
proxy = compose.fetch("services").fetch("socket-proxy")
refuse("NAS Intel agent image differs") unless
  intel.fetch("image").start_with?("ghcr.io/henrygd/beszel/beszel-agent-intel:")
refuse("NAS Intel render device differs") unless
  intel.fetch("devices") == ["${NAS_RENDER_DEVICE:?}:${NAS_RENDER_DEVICE:?}"] &&
    nas_inventory.fetch("platform_render_device_path") == "/dev/dri/renderD128"
expected_mounts = [
  "${NAS_DOCKER_ROOT:?}/beszel/volume1:/extra-filesystems/volume1:ro",
  "${NAS_MEDIA_ROOT:?}/.beszel:/extra-filesystems/volume2:ro"
]
[intel, portable].each do |agent|
  refuse("agent capacity mounts differ") unless expected_mounts.all? { |mount| agent.fetch("volumes").include?(mount) }
end
refuse("socket proxy is absent") unless proxy.fetch("volumes") == ["/var/run/docker.sock:/var/run/docker.sock:ro"]
refuse("Mac must use portable telemetry without a render device") unless
  mac_inventory.fetch("platform_beszel_agent_kind") == "portable" &&
    mac_inventory.fetch("platform_render_device_available") == false &&
    mac_inventory.fetch("beszel_required_telemetry_categories") == %w[core disk containers] &&
    mac_inventory.fetch("beszel_require_gpu_telemetry") == false
refuse("NAS telemetry policy must explicitly require GPU") unless
  nas_inventory.fetch("beszel_required_telemetry_categories") == %w[core disk containers gpu] &&
    nas_inventory.fetch("beszel_require_gpu_telemetry") == true
refuse("Mac verification does not execute persisted telemetry proof") unless
  verify_hook.include?('"$mac_hook_dir/../../run-beszel-contract.sh" verify')
refuse("Mac drift hook does not execute category rejection semantics") unless
  drift_hook.include?('ruby "$mac_script_dir/../beszel_telemetry_probe_test.rb"')

puts "Beszel static contract passed"
