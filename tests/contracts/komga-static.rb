#!/usr/bin/env ruby
# Static half of the Komga service contract, decided from the repository alone.
#
# usage: komga-static.rb COMPOSE MAC_COMPOSE ROLE DEFAULTS ARGUMENT_SPECS ENV_TEMPLATE INVENTORY
#
# Run it through tests/contracts/komga.sh, which sets PLATFORM_CONTRACT_REPO_DIR.
compose_path, mac_path, role_path, defaults_path, argument_specs_path,
  environment_path, inventory_path = ARGV
compose = YAML.safe_load_file(compose_path, aliases: true)
mac = YAML.safe_load_file(mac_path, aliases: true)

# Flattened so a task moved inside a block is still found.
require File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "tests", "policy_support")
include PolicySupport

# Unscoped on purpose: a forbidden primitive in any task is a violation.
def deep_strings(node)
  case node
  when Hash then node.flat_map { |key, value| [key.to_s] + deep_strings(value) }
  when Array then node.flat_map { |value| deep_strings(value) }
  when String then [node]
  when nil then []
  else [node.to_s]
  end
end

role_tasks = flatten_tasks(YAML.safe_load_file(role_path, aliases: false))
role_names = role_tasks.filter_map { |task| task["name"] }
role_at = lambda { |name| role_tasks.index { |task| task["name"] == name } }
role_task = lambda { |name| role_tasks.find { |task| task["name"] == name } || {} }
defaults = YAML.safe_load_file(defaults_path)
argument_specs = YAML.safe_load_file(argument_specs_path)
inventory = YAML.safe_load_file(inventory_path)
service = compose.fetch("services").fetch("komga")
abort "Komga contract failed: platform identity differs" unless
  service.fetch("user") == "${NAS_UID:?}:${NAS_GID:?}"
abort "Komga contract failed: NAS port differs" unless service.fetch("ports") == ["25600:25600"]
abort "Komga contract failed: storage contract differs" unless service.fetch("volumes") == [
  "${KOMGA_CONFIG_PATH:?}:/config",
  "${KOMGA_LIBRARY_PATH:?}:/data:ro"
]

# Config mounts at /config and the library at /data:ro, so config resolving under
# the media root could land inside the read-only library. Read as source text.
environment = File.read(environment_path)
env_value = lambda do |name|
  values = environment.scan(/^#{Regexp.escape(name)}=(.*)$/).flatten
  abort "Komga contract failed: #{name} is not rendered exactly once" unless values.length == 1
  values.first.strip
end
rooted_at = lambda { |value, root| value.match?(%r{\A\{\{\s*#{root}\s*\}\}/}) }
# Both halves are needed; neither implies the other.
abort "Komga contract failed: config storage is not rooted outside the media tree" unless
  rooted_at.call(env_value.call("KOMGA_CONFIG_PATH"), "nas_docker_root")
abort "Komga contract failed: the library is not rooted in the media tree" unless
  rooted_at.call(env_value.call("KOMGA_LIBRARY_PATH"), "nas_media_root")

abort "Komga contract failed: restart policy differs" unless service.fetch("restart") == "unless-stopped"
abort "Komga contract failed: logging policy differs" unless service.fetch("logging") == {
  "driver" => "json-file", "options" => { "max-size" => "10m", "max-file" => "3" }
}
expected_health_test = [
  "CMD-SHELL",
  "test \"$$(/usr/bin/curl --fail --silent --show-error " \
    "http://127.0.0.1:25600/actuator/health)\" = '{\"status\":\"UP\"}'"
]
abort "Komga contract failed: application healthcheck differs" unless
  service.fetch("healthcheck") == {
    "test" => expected_health_test,
    "interval" => "30s",
    "timeout" => "10s",
    "retries" => 5,
    "start_period" => "60s"
  }
mac_service = mac.fetch("services").fetch("komga")
abort "Komga contract failed: Mac override may only replace container name and ports" unless
  mac_service.keys.sort == %w[container_name ports] && !mac_service.key?("image")
expected_libraries = [
  { "name" => "Comics", "root" => "/data/Comics", "settings" => {} },
  { "name" => "Ebooks", "root" => "/data/Ebooks", "settings" => {} }
]
abort "Komga contract failed: managed library model differs" unless
  defaults.fetch("komga_libraries") == expected_libraries
abort "Komga contract failed: the retired singular library inputs survive" if
  defaults.key?("komga_library_name") || defaults.key?("komga_library_root")
abort "Komga contract failed: managed scan schedule differs" unless
  defaults.fetch("komga_library_settings").fetch("scanInterval") == "HOURLY"
abort "Komga contract failed: managed scan exclusions differ" unless
  defaults.fetch("komga_library_settings").fetch("scanDirectoryExclusions") == [".acquisition"]
abort "Komga contract failed: the library root migration input is not one-convergence" unless
  defaults.fetch("komga_library_root_migration_allowed") == false
# group_vars/all outranks role defaults, so the inventory must not hold true
# either (#343). The move is taken with -e komga_library_root_migration_allowed=true.
abort "Komga contract failed: the library root migration input is enabled in the inventory" unless
  inventory.fetch("komga_library_root_migration_allowed", false) == false
library_options = argument_specs.dig("argument_specs", "main", "options") || {}
abort "Komga contract failed: the plural library model is undeclared" unless
  library_options.dig("komga_libraries", "type") == "list" &&
  library_options.dig("komga_libraries", "elements") == "dict" &&
  library_options.dig("komga_library_root_migration_allowed", "type") == "bool"
abort "Komga contract failed: application health timing defaults differ" unless
  defaults.values_at("komga_health_retries", "komga_health_delay") == [60, 3]
health_options = argument_specs.dig("argument_specs", "main", "options")
abort "Komga contract failed: application health timing arguments are undeclared" unless
  health_options&.slice("komga_health_retries", "komga_health_delay") == {
    "komga_health_retries" => { "type" => "int", "required" => false },
    "komga_health_delay" => { "type" => "int", "required" => false }
  }

health_tasks = role_tasks.each_with_index.select do |task, _index|
  task["name"] == "Wait for Komga application health"
end
abort "Komga contract failed: application health readiness task must occur exactly once" unless
  health_tasks.length == 1
health_task, health_index = health_tasks.first
deploy_index = role_tasks.index { |task| task["name"] == "Deploy Komga" }
claim_index = role_tasks.index { |task| task["name"] == "Read Komga claim status" }
abort "Komga contract failed: application readiness must gate claim reconciliation" unless
  deploy_index && claim_index && deploy_index < health_index && health_index < claim_index
abort "Komga contract failed: application readiness request differs" unless
  health_task["ansible.builtin.uri"] == {
    "url" => "{{ komga_api }}/actuator/health",
    "method" => "GET",
    "status_code" => [200],
    "return_content" => true
  }
abort "Komga contract failed: application readiness status gate differs" unless
  health_task.values_at("register", "until", "retries", "delay", "changed_when", "check_mode") == [
    "komga_health",
    [
      "komga_health.json | default(none) is mapping",
      "komga_health.json.status | default(none) == 'UP'"
    ],
    "{{ komga_health_retries }}",
    "{{ komga_health_delay }}",
    false,
    false
  ]

required_tasks = [
  "Wait for Komga application health",
  "Read Komga claim status",
  "Claim Komga with the vault administrator",
  "Refuse ambiguous Komga library candidates",
  "Require valid Komga library candidate schemas",
  "Create the managed Komga library",
  "Repair the managed Komga library",
  "Read back Komga libraries after reconciliation",
  "Require exact reconciled Komga library",
  "Require the vault Komga administrator",
  "Require exactly the managed Komga library"
]
required_tasks.each do |name|
  abort "Komga contract failed: missing #{name}" unless role_names.include?(name)
end
preflight_names = [
  "List Komga libraries for reconciliation",
  "Refuse ambiguous Komga library candidates",
  "Require valid Komga library candidate schemas"
]
mutation_names = ["Create the managed Komga library", "Repair the managed Komga library"]
preflight = preflight_names.map(&role_at)
mutations = mutation_names.map(&role_at)
abort "Komga contract failed: library preflight must precede every mutation" unless
  preflight.none?(&:nil?) && mutations.none?(&:nil?) && preflight.max < mutations.min
# Komga refuses a root nested with an existing library's root.
abort "Komga contract failed: library repairs must precede library creations" unless
  role_at.call("Repair the managed Komga library") <
    role_at.call("Create the managed Komga library")
abort "Komga contract failed: managed root matching is not trailing-slash normalized" unless
  role_task.call("Resolve normalized Komga library targets")
    .dig("ansible.builtin.set_fact", "komga_desired_libraries").to_s
    .include?("regex_replace('/+$', '')")
abort "Komga contract failed: library updates must preserve the selected identifier" unless
  role_task.call("Repair the managed Komga library").dig("ansible.builtin.uri", "url").to_s
    .include?("item.id | urlencode")
# Read as the guard's own conditions: the input appears in three live places.
abort "Komga contract failed: the library root move is not gated on the one-convergence input" unless
  Array(role_task.call("Refuse ambiguous Komga library candidates")
    .dig("ansible.builtin.assert", "that")).any? do |condition|
    condition.to_s.include?("komga_library_root_migration_allowed | bool")
  end
user_mutation = role_at.call("Reconcile managed Komga users")
abort "Komga contract failed: complete library preflight must precede managed-user mutation" unless
  user_mutation && preflight.none?(&:nil?) && preflight.max < user_mutation &&
    user_mutation < mutations.min
abort "Komga contract failed: role must not edit an opaque database" if
  deep_strings(role_tasks).any? { |value| value.match?(/sqlite|database\.sqlite|tasks\.sqlite/i) }
