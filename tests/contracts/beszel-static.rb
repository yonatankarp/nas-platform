#!/usr/bin/env ruby
# The static half of the Beszel service contract: the telemetry policy the
# role declares, its argument validation, the Compose definition's agent and
# socket-proxy shape, the two inventories' capability declarations, the two
# Mac hooks and the agreement between the drift hook's refusal anchor and the
# fail_msg of the role guard it anchors on, all decided from the repository
# alone with nothing deployed.
#
# usage: beszel-static.rb REPOSITORY
#
# PLATFORM_CONTRACT_REPO_DIR names the tree being inspected, which is where
# tests/policy_support.rb and tests/http_fixture_support.rb are required from --
# not the checkout this file lives in. Run it through tests/contracts/beszel.sh
# rather than directly.
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
# The prefix ansible-core prints in front of a failing task's fail_msg, taken
# from the one place that states it rather than transcribed a third time. The
# drift hook's anchor is that prefix followed by the guard's own diagnostic, and
# both halves are read here from the tree being inspected: a core release that
# rephrases the prefix is fixed in HttpFixtureSupport and this contract follows.
require File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "tests", "http_fixture_support")
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

# The drift hook's refusal anchor, asserted as an agreement rather than as a
# third copy of the sentence. tests/mac/verify.sh verifies every service in one
# playbook, so a hook that asserts nothing beyond that command exiting non-zero
# is satisfied by an unrelated service failing -- it was, until #440. The grep
# for "<TASK_REFUSAL_PREFIX><fail_msg>" is what makes the hook test Beszel, and
# nothing static said so until #450: deleting or broadening it left this contract
# green, which is the same shape as the defect #440 closed one level up.
#
# Both halves are read from what the role and the fixture support actually
# declare, so rewording the guard's fail_msg without rewording the hook is a
# refusal here rather than a hook that has quietly stopped anchoring on
# anything. "Verify the managed application user contract" is the guard the hook
# names because it is the first tagged refusal reachable under
# --tags platform_verify_beszel; the hook's own comment records why.
app_user_guards = role_tasks.select { |task| task["name"] == "Verify the managed application user contract" }
refuse("the managed application user guard is absent or ambiguous") unless app_user_guards.length == 1
# assert is read through its FQCN alone: ansible-lint's production profile
# rejects the short form, so a bare assert: cannot reach this tree. The safe
# navigation is what the refusal above already excludes: it keeps a run in which
# that refusal was removed reporting the empty diagnostic below by name, rather
# than a NoMethodError backtrace.
guard_diagnostic = app_user_guards.first&.dig("ansible.builtin.assert", "fail_msg").to_s.strip
refuse("the managed application user guard states no diagnostic to anchor on") if guard_diagnostic.empty?
# Comment lines dropped first: an anchor that survives only inside the hook's own
# explanation of the anchor is not something the hook runs, and a whole-file
# substring cannot tell those apart.
drift_hook_code = drift_hook.lines.reject { |line| line.strip.start_with?("#") }.join
refuse("Mac drift hook does not anchor on the managed application user guard's own refusal") unless
  drift_hook_code.include?("#{HttpFixtureSupport::TASK_REFUSAL_PREFIX}#{guard_diagnostic}")

puts "Beszel static contract passed"
