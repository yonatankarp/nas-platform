#!/usr/bin/env ruby
# Static half of the Beszel contract, decided from the repository alone.
# usage: beszel-static.rb REPOSITORY (run through tests/contracts/beszel.sh;
# support files are required from PLATFORM_CONTRACT_REPO_DIR).
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
# The ansible-core fail_msg prefix, read from HttpFixtureSupport rather than restated.
require File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "tests", "http_fixture_support")
include PolicySupport
# static_role_tasks splices static imports in; a bare read of main.yml finds no tasks.
role_tasks = flatten_tasks(PolicySupport.static_role_tasks(role_path))
role_task_names = role_tasks.filter_map { |task| task["name"] if task.is_a?(Hash) }
# Collect strings one at a time: a pattern over a joined blob spans unrelated tasks.
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
# The relay's /beszel route with its own token: a pushover:// URL would ring every
# recovery, and a Pushover token here would put a publishing credential in Beszel's DB.
notification_url = defaults["beszel_notification_url"].to_s.strip
refuse("notification webhook still sends to pushover:// directly instead of through the relay") if
  notification_url.start_with?("pushover://")
refuse("notification webhook carries no @Authorization header for the relay") unless
  notification_url.include?("&@Authorization=")
refuse("notification webhook does not authenticate with vault_dozzle_alert_relay_token") unless
  notification_url.include?("('Bearer ' ~ vault_dozzle_alert_relay_token) | urlencode")
refuse("notification webhook is not the alert relay's /beszel route with the relay token") unless
  notification_url ==
    "generic://alert-relay:{{ dozzle_alert_relay_port }}/beszel?disabletls=yes&template=json" \
    "&@Authorization={{ ('Bearer ' ~ vault_dozzle_alert_relay_token) | urlencode }}"
# A stale scheme label reports [REDACTED] for the correct webhook forever (#598).
webhook_summary = role_tasks.find do |task|
  task.is_a?(Hash) && task["name"] == "Summarize the managed relay webhook without URL bodies"
end
webhook_scheme = webhook_summary&.dig("ansible.builtin.set_fact", "beszel_webhook_scheme").to_s
refuse("webhook scheme summary does not match the relay URL's generic:// scheme") unless
  webhook_scheme.include?("select('match', '^generic://')") && !webhook_scheme.include?("pushover")
# Both roles must read the one inventory variable, or the relay drops every
# "Open in Beszel" button silently.
beszel_env = File.read(File.join(root, "roles/beszel/templates/env.j2"))
dozzle_env = File.read(File.join(root, "roles/dozzle/templates/env.j2"))
refuse("Beszel's APP_URL and the relay's BESZEL_LINK_BASE are not both beszel_app_url") unless
  beszel_env.lines.include?("BESZEL_APP_URL={{ beszel_app_url }}\n") &&
    dozzle_env.lines.include?("BESZEL_LINK_BASE={{ beszel_app_url }}\n") &&
    compose.dig("services", "hub", "environment", "APP_URL") == "${BESZEL_APP_URL:?}"
# Scoped to the one variable: a mention elsewhere is not a derivation.
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
refuse("role treats live health as persisted telemetry") unless
  collection_poll && collection_poll["register"] == "beszel_telemetry_probe_result" &&
    role_tasks.any? do |task|
      task != collection_poll &&
        role_strings(task).any? { |value| value.include?("beszel_telemetry_probe_result.evidence") }
    end

intel = compose.fetch("services").fetch("agent-intel")
portable = compose.fetch("services").fetch("agent-portable")
proxy = compose.fetch("services").fetch("socket-proxy")
# A service with a networks key joins only what it lists, so the hub keeps
# default; the socket proxy shares only docker-api with agent-portable (#829).
refuse("hub must join default and the external alert-relay bridge, and nothing else may") unless
  compose.fetch("services").fetch("hub")["networks"] == %w[default alert-bridge] &&
    compose["networks"] == { "default" => {},
                             "alert-bridge" => { "external" => true, "name" => "${PLATFORM_ALERT_RELAY_NETWORK:?}" },
                             "docker-api" => { "internal" => true },
                             "docker-api-publish" => {} } &&
    compose.fetch("services").transform_values { |service| service["networks"] } ==
      { "hub" => %w[default alert-bridge], "agent-portable" => %w[default docker-api],
        "agent-intel" => nil, "socket-proxy" => %w[docker-api docker-api-publish] }
refuse("NAS Intel agent image differs") unless
  intel.fetch("image").start_with?("ghcr.io/henrygd/beszel/beszel-agent-intel:")
refuse("NAS Intel render device differs") unless
  intel.fetch("devices").first == "${NAS_RENDER_DEVICE:?}:${NAS_RENDER_DEVICE:?}" &&
    nas_inventory.fetch("platform_render_device_path") == "/dev/dri/renderD128"
# One read-only Compose slot per inventory disk, counted from the NAS inventory.
sata = nas_inventory.fetch("platform_smart_sata_devices")
nvme = nas_inventory.fetch("platform_smart_nvme_namespaces")
expected_smart_devices =
  (1..sata.length).map { |n| "${NAS_SMART_SATA_DEVICE_#{n}:?}:${NAS_SMART_SATA_DEVICE_#{n}:?}:r" } +
  (1..nvme.length).map { |n| "${NAS_SMART_NVME_NAMESPACE_#{n}:?}:/dev/nvme#{n - 1}:r" }
refuse("NAS Intel S.M.A.R.T. device slots differ from inventory") unless
  intel.fetch("devices").drop(1) == expected_smart_devices &&
    sata.all? { |path| path.match?(%r{\A/dev/sd[a-z]+\z}) } &&
    nvme.all? { |path| path.match?(%r{\A/dev/nvme\d+n1\z}) }
refuse("NAS Intel agent lacks the S.M.A.R.T. capabilities") unless
  intel.fetch("cap_add") == %w[CAP_PERFMON CAP_SYS_RAWIO CAP_SYS_ADMIN]
slot_guard = role_tasks.find { |task| task["name"] == "Require one Compose S.M.A.R.T. slot for every declared disk" }
slot_conditions = Array(slot_guard&.dig("ansible.builtin.assert", "that")).join(" ")
refuse("role does not pin the S.M.A.R.T. slot count to Compose") unless
  slot_conditions.include?("platform_smart_sata_devices | length == #{sata.length}") &&
    slot_conditions.include?("platform_smart_nvme_namespaces | length == #{nvme.length}")
# A declared disk missing from the host warns rather than fails; the behaviour
# is tested in tests/beszel_telemetry_ansible_test.rb, this holds the shape.
smart_stat = role_tasks.find { |task| task["name"] == "Look for each declared S.M.A.R.T. device node on this host" }
smart_warn = role_tasks.find { |task| task["name"] == "Warn about declared S.M.A.R.T. devices absent from this host" }
env_render = role_tasks.find { |task| task["name"] == "Render the Beszel environment" }
refuse("role does not tolerate an absent S.M.A.R.T. device") unless
  smart_stat&.key?("ansible.builtin.stat") && smart_stat["loop"] == "{{ beszel_smart_device_slots }}" &&
    smart_stat["register"] == "beszel_smart_device_stats" &&
    smart_stat["check_mode"] == false && smart_stat["changed_when"] == false &&
    smart_warn&.key?("ansible.builtin.debug") && smart_warn["loop"] == "{{ beszel_smart_missing_slots }}" &&
    !smart_warn.key?("failed_when") && env_render &&
    role_tasks.index(smart_stat) < role_tasks.index(smart_warn) &&
    role_tasks.index(smart_warn) < role_tasks.index(env_render) &&
    vars.fetch("beszel_smart_rendered_slots", "").include?("beszel_smart_present_devices") &&
    %w[stat.isblk stat.ischr].all? { |attribute| vars.fetch("beszel_smart_present_devices", "").include?(attribute) }
env_assignments = environment_assignments(File.join(root, "roles/beszel/templates/env.j2")).to_h
smart_slot_names = (1..sata.length).map { |n| "NAS_SMART_SATA_DEVICE_#{n}" } +
                   (1..nvme.length).map { |n| "NAS_SMART_NVME_NAMESPACE_#{n}" }
refuse("env template renders a S.M.A.R.T. slot without the presence check") unless
  smart_slot_names.all? do |name|
    env_assignments[name] == "{{ beszel_smart_rendered_slots['#{name}'] | default('/dev/null') }}"
  end
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

# The drift hook must grep "<TASK_REFUSAL_PREFIX><fail_msg>", or an unrelated
# service failing satisfies it (#440). Both halves are read from the tree.
app_user_guards = role_tasks.select { |task| task["name"] == "Verify the managed application user contract" }
refuse("the managed application user guard is absent or ambiguous") unless app_user_guards.length == 1
# FQCN only: ansible-lint's production profile rejects the short form.
guard_diagnostic = app_user_guards.first&.dig("ansible.builtin.assert", "fail_msg").to_s.strip
refuse("the managed application user guard states no diagnostic to anchor on") if guard_diagnostic.empty?
# no_log or a missing tag would leave the anchor pinning a sentence the run can
# never print, and the drift hook only runs in the hand-run Mac proof (#444).
refuse("the managed application user guard censors the diagnostic the hook reads") if
  app_user_guards.first["no_log"]
refuse("the managed application user guard is not selected by the verification tag") unless
  Array(app_user_guards.first["tags"]).include?("platform_verify_beszel")
# Comment lines dropped: an anchor only in the hook's explanation is not run.
drift_hook_code = drift_hook.lines.reject { |line| line.strip.start_with?("#") }.join
refuse("Mac drift hook does not anchor on the managed application user guard's own refusal") unless
  drift_hook_code.include?("#{HttpFixtureSupport::TASK_REFUSAL_PREFIX}#{guard_diagnostic}")

puts "Beszel static contract passed"
