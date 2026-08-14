#!/usr/bin/env ruby
# Property-based policy checks.
#
# Most checks deliberately assert properties rather than per-service values.
# The source-platform inventory is the exception: pinning that finite set keeps
# an omitted legacy service from silently disappearing from the migration scope.

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

beginner_guides = %w[
  docs/getting-started.md
  docs/getting-started-mac.md
  docs/getting-started-nas.md
  docs/ansible-basics.md
]
beginner_guides.each do |relative_path|
  check(failures, File.file?(File.join(ROOT, relative_path)),
        "beginner guide is missing: #{relative_path}")
end

readme_source = File.read(File.join(ROOT, "README.md"))
beginner_guides.each do |relative_path|
  check(failures, readme_source.include?("](#{relative_path})"),
        "README must link to #{relative_path}")
end

getting_started_path = File.join(ROOT, "docs", "getting-started.md")
getting_started_source = File.file?(getting_started_path) ? File.read(getting_started_path) : ""
check(failures,
      %w[inventory/mac.yml inventory/remote.yml].all? do |inventory|
        getting_started_source.include?(inventory)
      end,
      "beginner starting point must distinguish Mac and remote NAS inventories")
check(failures,
      getting_started_source.match?(/Never commit a plaintext vault/i) &&
        getting_started_source.include?("vault password"),
      "beginner starting point must forbid plaintext vault and password commits")

ansible_basics_path = File.join(ROOT, "docs", "ansible-basics.md")
ansible_basics_source = File.file?(ansible_basics_path) ? File.read(ansible_basics_path) : ""
check(failures,
      ansible_basics_source.scan(%r{https://docs\.ansible\.com/}).length >= 10,
      "Ansible concepts guide must link concepts to official Ansible documentation")

service_dirs = Dir[File.join(ROOT, "services", "*")].select { |p| File.directory?(p) }
check(failures, service_dirs.any?, "no services defined")

beszel_contract_path = File.join(ROOT, "tests", "contracts", "beszel.sh")
beszel_contract = File.file?(beszel_contract_path) ? File.read(beszel_contract_path) : ""
check(failures,
      beszel_contract.include?('since: baseline_id') &&
        beszel_contract.include?('message["id"] != baseline_id') &&
        !beszel_contract.include?("iso8601"),
      "Beszel notification proof must poll after a captured ntfy message ID")

policy_runner = File.read(File.join(ROOT, "tests", "validate-policy.sh"))
%w[
  ruby\ tests/beszel_telemetry_probe_test.rb
  ruby\ tests/beszel_telemetry_timeout_test.rb
  ruby\ tests/beszel_telemetry_ansible_test.rb
  python3\ tests/beszel_telemetry_module_test.py
  tests/mac/beszel-telemetry-hook-test.sh
].each do |command|
  check(failures, policy_runner.lines.map(&:strip).include?(command.gsub("\\ ", " ")),
        "validate-policy.sh must run #{command.gsub('\\ ', ' ')}")
end

mac_run_path = File.join(ROOT, "tests", "mac", "run.sh")
mac_run = File.file?(mac_run_path) ? File.read(mac_run_path) : ""
dozzle_tasks_path = File.join(ROOT, "roles", "dozzle", "tasks", "main.yml")
dozzle_tasks = File.file?(dozzle_tasks_path) ? File.read(dozzle_tasks_path) : ""
dozzle_planned_tasks = [
  "Report planned managed Dozzle dispatcher creation",
  "Report planned managed Dozzle dispatcher repair",
  "Report planned managed Dozzle alert rule creation",
  "Report planned managed Dozzle alert rule repair",
  "Report planned managed Dozzle alert rule enabled-state repair",
  "Report planned unmanaged Dozzle alert rule removal",
  "Report planned unmanaged Dozzle dispatcher removal"
]
check(failures, dozzle_planned_tasks.all? { |name| dozzle_tasks.include?("- name: #{name}") },
      "Dozzle must expose every REST mutation category as a check-mode planned change")
check(failures,
      %w[
        PLATFORM_PROJECT_NAME PLATFORM_BESZEL_PORT PLATFORM_NTFY_PORT PLATFORM_DOZZLE_PORT
        PLATFORM_AUDIOBOOKSHELF_PORT
      ].all? do |value|
        mac_run.include?("export #{value}=")
      end && %w[beszel ntfy dozzle audiobookshelf].all? do |name|
        mac_run.include?(%Q{"$project_name-#{name}"})
      end,
      "Mac runner must export dynamic project/port facts and isolate every Compose project")

EXPECTED_SERVICES = %w[
  audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx
  tinymediamanager
].freeze
EXPECTED_LEGACY_SOURCE = {
  "repository" => "yonatankarp/nas-infrastructure",
  "commit" => "400f03f276ae1bb69f5460c175b9fb923d620f1a",
  "local_path" => "../nas-infrastructure"
}.freeze
EXPECTED_SERVICE_MAPPINGS = {
  "audiobookshelf" => { "role" => "audiobookshelf", "legacy_path" => "compose/audiobookshelf/compose.yml", "tranche" => 3 },
  "beszel" => { "role" => "beszel", "legacy_path" => "compose/beszel/compose.yml", "tranche" => 2 },
  "dozzle" => { "role" => "dozzle", "legacy_path" => "compose/dozzle/compose.yml", "tranche" => 2 },
  "immich" => { "role" => "immich", "legacy_path" => "compose/immich/compose.yml", "tranche" => 5 },
  "jellyfin" => { "role" => "jellyfin", "legacy_path" => "compose/jellyfin/compose.yml", "tranche" => 4 },
  "komga" => { "role" => "komga", "legacy_path" => "compose/komga/compose.yml", "tranche" => 3 },
  "ntfy" => { "role" => "ntfy", "legacy_path" => "compose/ntfy/compose.yml", "tranche" => 2 },
  "paperless-ngx" => { "role" => "paperless_ngx", "legacy_path" => "compose/paperless-ngx/compose.yml", "tranche" => 6 },
  "tinymediamanager" => { "role" => "tinymediamanager", "legacy_path" => "compose/tinymediamanager/compose.yml", "tranche" => 3 }
}.freeze
EXPECTED_VAULT_KEYS = %w[
  vault_audiobookshelf_admin_username
  vault_audiobookshelf_admin_password
  vault_beszel_superuser_email
  vault_beszel_superuser_password
  vault_beszel_app_user_email
  vault_beszel_app_user_password
  vault_beszel_agent_key
  vault_beszel_universal_token
  vault_beszel_hub_private_key
  vault_dozzle_admin_username
  vault_dozzle_admin_password
  vault_dozzle_admin_password_hash
  vault_immich_admin_email
  vault_immich_admin_password
  vault_immich_db_name
  vault_immich_db_username
  vault_immich_db_password
  vault_jellyfin_admin_username
  vault_jellyfin_admin_password
  vault_jellyfin_opensubtitles_username
  vault_jellyfin_opensubtitles_password
  vault_komga_admin_email
  vault_komga_admin_password
  vault_ntfy_admin_user
  vault_ntfy_admin_password
  vault_ntfy_admin_password_hash
  vault_ntfy_dozzle_password_hash
  vault_ntfy_dozzle_token
  vault_ntfy_beszel_password_hash
  vault_ntfy_beszel_token
  vault_paperless_admin_username
  vault_paperless_admin_password
  vault_paperless_admin_email
  vault_paperless_db_name
  vault_paperless_db_username
  vault_paperless_db_password
  vault_paperless_django_secret_key
  vault_paperless_gmail_account
  vault_paperless_gmail_app_password
  vault_paperless_mail_account_name
  vault_paperless_mail_rule_name
  vault_managed_users
  vault_tinymediamanager_password
].sort.freeze
REQUIRED_MANIFEST_FIELDS = %w[name legacy_path role tranche status].freeze
ALLOWED_SERVICE_STATUSES = %w[planned implemented accepted].freeze
IMPLEMENTED_STATUSES = %w[implemented accepted].freeze
PLATFORM_INVENTORIES = {
  "local.yml" => ["nas_hosts", "nas", "local", "nas"],
  "remote.yml" => ["nas_hosts", "nas", "ssh", "nas"],
  "mac.yml" => ["mac_hosts", "mac", "local", "mac"]
}.freeze
PLATFORM_CAPABILITIES = %w[
  platform_render_device_available platform_render_device_path
  platform_beszel_agent_available platform_beszel_agent_kind
  platform_host_network_available platform_host_network_adapter
  platform_external_integration_checks
].freeze
PLATFORM_TELEMETRY_POLICY = %w[
  beszel_required_telemetry_categories beszel_require_gpu_telemetry
].freeze
HOST_SCOPED_VARS = (
  %w[platform_kind nas_docker_root nas_media_root] + PLATFORM_CAPABILITIES +
    PLATFORM_TELEMETRY_POLICY
).freeze

PLATFORM_INVENTORIES.each do |inventory_name, (host_group, host_name, connection, _platform_kind)|
  inventory_path = File.join(ROOT, "inventory", inventory_name)
  inventory = begin
    YAML.safe_load_file(inventory_path)
  rescue Errno::ENOENT
    check(failures, false, "inventory/#{inventory_name} is missing")
    {}
  rescue Psych::Exception => e
    check(failures, false,
          "inventory/#{inventory_name} is malformed: #{e.message.lines.first.strip}")
    {}
  end

  platform_children = inventory.dig("platform_hosts", "children")
  check(failures, platform_children.is_a?(Hash) && platform_children.key?(host_group),
        "inventory/#{inventory_name} must expose #{host_group} as a child of platform_hosts")
  host = platform_children&.dig(host_group, "hosts", host_name)
  check(failures, host.is_a?(Hash),
        "inventory/#{inventory_name} must place #{host_name} under #{host_group}")
  check(failures, host.is_a?(Hash) && host["ansible_connection"] == connection,
        "inventory/#{inventory_name} #{host_name} must use #{connection} connection")
  %w[platform_public_host platform_callback_host].each do |coordinate|
    check(failures, host.is_a?(Hash) && host[coordinate].is_a?(String) &&
                    !host[coordinate].empty?,
          "inventory/#{inventory_name} must define #{coordinate}")
  end
end

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
  PLATFORM_TELEMETRY_POLICY.each do |policy|
    check(failures, host_vars.key?(policy),
          "#{relative_path} must define #{policy}")
  end
  %w[
    platform_render_device_available platform_host_network_available
    platform_external_integration_checks
  ].each do |capability|
    check(failures, [true, false].include?(host_vars[capability]),
          "#{relative_path} #{capability} must be boolean")
  end
  check(failures, host_vars["platform_render_device_path"].is_a?(String) &&
                  !host_vars["platform_render_device_path"].empty?,
        "#{relative_path} platform_render_device_path must be a nonempty path")
  check(failures, %w[host published_ports].include?(host_vars["platform_host_network_adapter"]),
        "#{relative_path} platform_host_network_adapter must be host or published_ports")
  expected_network_adapter = host_vars["platform_host_network_available"] ? "host" : "published_ports"
  check(failures, host_vars["platform_host_network_adapter"] == expected_network_adapter,
        "#{relative_path} host-network capability and adapter must agree")
  mac_runtime_facts = if platform_kind == "mac"
                        %w[
                          platform_project_name beszel_port ntfy_port dozzle_port
                          audiobookshelf_port komga_port tinymediamanager_web_port
                          tinymediamanager_api_port jellyfin_port immich_port paperless_port
                          platform_adoption_root platform_adoption_marker platform_adoption_enabled
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
check(failures, mount_table_task && mount_table_task["when"].to_s.include?("platform_kind == 'nas'"),
      "preflight must read the Linux mount table only on NAS hosts")
gpu_fact_task = preflight_tasks.find do |task|
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
ansible_config_source = File.read(File.join(ROOT, "ansible.cfg"))
filter_probe = <<~'PYTHON'
  import sys
  import os
  import tempfile
  import types

  ansible = types.ModuleType("ansible")
  errors = types.ModuleType("ansible.errors")
  class AnsibleFilterError(Exception):
      pass
  errors.AnsibleFilterError = AnsibleFilterError
  sys.modules["ansible"] = ansible
  sys.modules["ansible.errors"] = errors

  namespace = {}
  with open(sys.argv[1], encoding="utf-8") as source:
      exec(compile(source.read(), sys.argv[1], "exec"), namespace)
  physical_path = namespace["platform_physical_path"]

  for unsafe in ("relative", "//safe/root", "/safe/root/../outside", "/safe//root", "/safe/root/"):
      try:
          physical_path(unsafe)
      except AnsibleFilterError:
          continue
      raise SystemExit(f"accepted unsafe path: {unsafe}")

  if physical_path("/safe/root") != "/safe/root":
      raise SystemExit("changed a normalized path without symlinked ancestors")

  with tempfile.TemporaryDirectory() as sandbox:
      physical_root = os.path.join(sandbox, "physical")
      linked_root = os.path.join(sandbox, "linked")
      os.mkdir(physical_root)
      os.symlink(physical_root, linked_root)
      unresolved_leaf = os.path.join(linked_root, "missing", "leaf")
      expected = os.path.join(os.path.realpath(physical_root), "missing", "leaf")
      if physical_path(unresolved_leaf) != expected:
          raise SystemExit("did not resolve a symlinked ancestor before a missing leaf")
PYTHON
_filter_stdout, filter_stderr, filter_status = Open3.capture3(
  "python3", "-c", filter_probe, File.join(ROOT, "filter_plugins", "platform_paths.py")
)
check(failures, ansible_config_source.match?(/^filter_plugins\s*=\s*filter_plugins$/),
      "Mac path canonicalization must use the configured physical-path filter")
check(failures, filter_status.success?,
      "Mac physical-path filter must reject ambiguous or relative paths: #{filter_stderr.strip}")

%w[ntfy beszel].each do |role_name|
  role_options = YAML.safe_load_file(
    File.join(ROOT, "roles", role_name, "meta", "argument_specs.yml")
  ).dig("argument_specs", "main", "options")
  check(failures, role_options.dig("platform_compose_kind", "type") == "str" &&
                  role_options.dig("platform_compose_kind", "required") == true,
        "#{role_name} argument specs must require platform_compose_kind")
  next unless role_name == "beszel"

  check(failures, role_options.dig("platform_render_device_path", "type") == "path" &&
                  role_options.dig("platform_render_device_path", "required") == true,
        "Beszel argument specs must require platform_render_device_path")
end

paperless_defaults = YAML.safe_load_file(
  File.join(ROOT, "roles", "paperless_ngx", "defaults", "main.yml")
)
{
  "paperless_task_workers" => 2,
  "paperless_threads_per_worker" => 1
}.each do |variable, expected|
  actual = paperless_defaults[variable]
  check(failures, actual.is_a?(Integer) && actual == expected,
        "Paperless #{variable} default must be integer #{expected}")
end

paperless_options = YAML.safe_load_file(
  File.join(ROOT, "roles", "paperless_ngx", "meta", "argument_specs.yml")
).dig("argument_specs", "main", "options")
%w[paperless_task_workers paperless_threads_per_worker].each do |variable|
  check(failures, paperless_options.dig(variable, "type") == "int" &&
                  paperless_options.dig(variable, "required") == false,
        "Paperless argument specs must declare optional integer #{variable}")
end

expected_immich_preference_profile = {
  "albums" => { "defaultAssetOrder" => "desc" },
  "avatar" => { "color" => "primary" },
  "cast" => { "gCastEnabled" => false },
  "download" => { "archiveSize" => 4_294_967_296, "includeEmbeddedVideos" => false },
  "emailNotifications" => { "enabled" => true, "albumInvite" => true, "albumUpdate" => true },
  "folders" => { "enabled" => false, "sidebarWeb" => false },
  "memories" => { "enabled" => true, "duration" => 5 },
  "people" => { "enabled" => true, "sidebarWeb" => false, "minimumFaces" => 3 },
  "purchase" => {
    "showSupportBadge" => true,
    "hideBuyButtonUntil" => "2022-02-12T00:00:00.000Z"
  },
  "ratings" => { "enabled" => false },
  "recentlyAdded" => { "sidebarWeb" => false },
  "sharedLinks" => { "enabled" => true, "sidebarWeb" => false },
  "tags" => { "enabled" => false, "sidebarWeb" => false }
}.freeze
immich_preference_keys = %w[
  immich_managed_user_preference_profile_default
  immich_managed_user_preference_profile_by_email
  immich_managed_user_preference_overrides
  immich_managed_user_preference_profiles
]
immich_defaults = YAML.safe_load_file(File.join(ROOT, "roles", "immich", "defaults", "main.yml"))
[shared_vars, immich_defaults].each_with_index do |variables, index|
  source = index.zero? ? "normal inventory" : "Immich role defaults"
  check(failures, variables["immich_managed_user_preference_profile_default"] == "standard",
        "#{source} must select the standard Immich preference profile by default")
  check(failures, variables["immich_managed_user_preference_profile_by_email"] == {},
        "#{source} must default Immich per-email profile selection to an empty mapping")
  check(failures, variables["immich_managed_user_preference_overrides"] == {},
        "#{source} must default Immich per-email preference overrides to an empty mapping")
  check(failures,
        variables.dig("immich_managed_user_preference_profiles", "standard") ==
          expected_immich_preference_profile,
        "#{source} standard Immich preference profile differs from the approved v3.1.0 schema")
end

immich_options = YAML.safe_load_file(
  File.join(ROOT, "roles", "immich", "meta", "argument_specs.yml")
).dig("argument_specs", "main", "options")
immich_preference_keys.each do |key|
  expected_type = key.end_with?("_default") ? "str" : "dict"
  check(failures,
        immich_options.dig(key, "type") == expected_type &&
          immich_options.dig(key, "required") == false,
        "Immich argument specs must declare optional #{expected_type} #{key}")
end

paperless_env_lines = File.readlines(
  File.join(ROOT, "roles", "paperless_ngx", "templates", "env.j2"),
  chomp: true
)
[
  "PAPERLESS_TASK_WORKERS={{ paperless_task_workers }}",
  "PAPERLESS_THREADS_PER_WORKER={{ paperless_threads_per_worker }}"
].each do |line|
  check(failures, paperless_env_lines.include?(line),
        "Paperless environment template must contain exact line: #{line}")
end

def flatten_tasks(tasks, flattened = [])
  Array(tasks).each do |task|
    next unless task.is_a?(Hash)

    flattened << task
    %w[block rescue always].each { |section| flatten_tasks(task[section], flattened) }
  end
  flattened
end

# These checks prove that verification is structurally wired to an observable,
# service-specific result. The integration run supplies runtime semantic proof;
# static policy intentionally does not interpret arbitrary Jinja expressions.
def service_specific_uri?(task, prefixes, service_names)
  uri = task["ansible.builtin.uri"]
  return false unless uri.is_a?(Hash) && uri["url"].is_a?(String)

  url = uri.fetch("url")
  variable_reference = prefixes.any? { |prefix| url.match?(/\b#{Regexp.escape(prefix)}_[A-Za-z0-9_]+\b/) }
  literal_endpoint = service_names.any? do |name|
    url.match?(/(?<![A-Za-z0-9_-])#{Regexp.escape(name)}(?![A-Za-z0-9_-])/)
  end
  variable_reference || literal_endpoint
end

def uri_verifies_service?(task, prefixes, service_names)
  uri = task["ansible.builtin.uri"]
  return false unless service_specific_uri?(task, prefixes, service_names)

  return true if uri.key?("status_code")

  register = task["register"]
  register.is_a?(String) && %w[until failed_when].any? do |condition|
    task[condition].to_s.match?(/\b#{Regexp.escape(register)}\b/)
  end
end

def assert_verifies_service?(task, validated_registers)
  assertion = task["ansible.builtin.assert"]
  conditions = assertion.is_a?(Hash) ? Array(assertion["that"]) : []
  return false if conditions.empty?

  conditions.all? do |condition|
    next false unless condition.is_a?(String)

    producer = validated_registers.find do |register|
      condition.match?(/\b#{Regexp.escape(register)}(?:\.[A-Za-z_][A-Za-z0-9_]*|\[['"][^'"]+['"]\])/)
    end
    comparison = condition.match(/\A\s*(.+?)\s*(==|!=|>=|<=|>|<|\bin\b|\bis\b)\s*(.+?)\s*\z/m)
    producer && comparison && comparison[1].strip != comparison[3].strip
  end
end

def role_has_verification?(tasks_path, service_name, role_name)
  tasks = flatten_tasks(YAML.safe_load_file(tasks_path))
  canonical_name = contract_basename(service_name)
  prefixes = [service_name.tr("-", "_"), role_name, canonical_name.tr("-", "_")].uniq
  service_names = [service_name, role_name, canonical_name].uniq
  expected_tag = "platform_verify_#{canonical_name}"
  validated_registers = Set.new
  verified = false

  tasks.each do |task|
    named = task["name"].is_a?(String) && task["name"].match?(/\b(?:verify|verification)\b/i)
    tagged = Array(task["tags"]).include?(expected_tag)
    evidence = uri_verifies_service?(task, prefixes, service_names) ||
               assert_verifies_service?(task, validated_registers)
    verified ||= named && tagged && evidence
    register = task["register"]
    if register.is_a?(String) && prefixes.any? { |prefix| register.start_with?("#{prefix}_") } &&
       service_specific_uri?(task, prefixes, service_names)
      validated_registers << register
    end
  end
  verified
rescue Psych::Exception
  false
end

def contract_has_verification?(contract_path, contract_root, service_name, relative_contract_path, registry_entries)
  expected_entry = { "service" => service_name, "path" => relative_contract_path }
  return false unless registry_entries.include?(expected_entry)
  return false unless owned_file?(contract_path, contract_root)
  return false unless File.executable?(contract_path) && File.size?(contract_path)

  _stdout, _stderr, status = Open3.capture3("sh", "-n", contract_path)
  status.success?
end

registry_path = File.join(ROOT, "tests", "contracts", "registry.yml")
registry = begin
  duplicate_yaml_keys(Psych.parse_stream(File.read(registry_path))).uniq.each do |key|
    check(failures, false, "contract registry contains duplicate mapping key #{key}")
  end
  YAML.safe_load_file(registry_path)
rescue Errno::ENOENT
  check(failures, false, "contract registry is missing")
  nil
rescue Psych::Exception => e
  check(failures, false, "contract registry is malformed: #{e.message.lines.first.strip}")
  nil
end
check(failures, registry.is_a?(Hash), "contract registry top level must be a mapping")
check(failures, registry.is_a?(Hash) && registry.keys == ["contracts"],
      "contract registry must contain exactly a contracts list")
contract_registry_entries = registry.is_a?(Hash) ? registry["contracts"] : nil
check(failures, contract_registry_entries.is_a?(Array),
      "contract registry must contain a contracts list")
contract_registry_entries = [] unless contract_registry_entries.is_a?(Array)
contract_registry_entries.each do |entry|
  check(failures, entry.is_a?(Hash) && entry.keys.sort == %w[path service] &&
                  entry.values.all? { |value| value.is_a?(String) && !value.empty? },
        "contract registry entries require nonempty service and path strings")
end

manifest_path = File.join(ROOT, "services", "manifest.yml")
manifest_loaded = true
manifest = begin
  duplicate_yaml_keys(Psych.parse_stream(File.read(manifest_path))).uniq.each do |key|
    check(failures, false, "service manifest contains duplicate mapping key #{key}")
  end
  YAML.safe_load_file(manifest_path)
rescue Errno::ENOENT
  check(failures, false, "service manifest is missing: services/manifest.yml")
  manifest_loaded = false
  nil
rescue Psych::Exception => e
  check(failures, false, "service manifest is malformed: #{e.message.lines.first.strip}")
  manifest_loaded = false
  nil
end

check(failures, manifest.is_a?(Hash), "service manifest top level must be a mapping") if manifest_loaded
manifest = {} unless manifest.is_a?(Hash)

legacy_source = manifest["legacy_source"]
check(failures, legacy_source.is_a?(Hash), "service manifest legacy_source must be a mapping") if manifest_loaded
legacy_source = {} unless legacy_source.is_a?(Hash)
EXPECTED_LEGACY_SOURCE.each do |field, expected|
  check(failures, legacy_source[field] == expected,
        "legacy_source #{field} must equal #{expected}") if manifest_loaded
end

manifest_entries = manifest["services"]
unless manifest_entries.is_a?(Array)
  check(failures, false, "service manifest must contain a services list") if manifest_loaded
  manifest_entries = []
end

manifest_names = manifest_entries.filter_map do |service|
  unless service.is_a?(Hash)
    check(failures, false, "each service manifest entry must be a mapping")
    next
  end

  missing_fields = REQUIRED_MANIFEST_FIELDS.reject { |field| service.key?(field) }
  check(failures, missing_fields.empty?,
        "service manifest entry is missing required fields: #{missing_fields.join(', ')}")
  check(failures, service["name"].is_a?(String), "service name must be a string")
  check(failures, service["role"].is_a?(String),
        "#{service['name'] || '<unnamed>'}: role must be a string")
  check(failures, service["legacy_path"].is_a?(String),
        "#{service['name'] || '<unnamed>'}: legacy_path must be a string")
  check(failures, ALLOWED_SERVICE_STATUSES.include?(service["status"]),
        "#{service['name'] || '<unnamed>'}: status must be planned, implemented, or accepted")
  check(failures, service["tranche"].is_a?(Integer) && service["tranche"].positive?,
        "#{service['name'] || '<unnamed>'}: tranche must be a positive integer")

  name = service["name"]
  if name.is_a?(String) && EXPECTED_SERVICE_MAPPINGS.key?(name)
    EXPECTED_SERVICE_MAPPINGS.fetch(name).each do |field, expected|
      check(failures, service[field] == expected, "#{name}: #{field} must equal #{expected}")
    end
  end
  name if name.is_a?(String)
end.compact

check(failures, manifest_names.sort == EXPECTED_SERVICES.sort,
      "service manifest must list the complete source platform")
check(failures, (manifest_names - EXPECTED_SERVICES).empty?,
      "service manifest contains unknown services: #{(manifest_names - EXPECTED_SERVICES).uniq.join(', ')}")

%w[ntfy beszel].each do |name|
  entry = manifest_entries.find { |service| service.is_a?(Hash) && service["name"] == name }
  check(failures, entry && IMPLEMENTED_STATUSES.include?(entry["status"]),
        "#{name}: status must be implemented or accepted")
end

%w[name role legacy_path].each do |field|
  values = manifest_entries.filter_map { |service| service[field] if service.is_a?(Hash) }
  duplicates = values.tally.select { |_value, count| count > 1 }.keys
  check(failures, duplicates.empty?,
        "service manifest #{field} values must be unique: #{duplicates.join(', ')}")
end

service_dir_names = service_dirs.map { |dir| File.basename(dir) }
undeclared_dirs = service_dir_names - manifest_names
check(failures, undeclared_dirs.empty?,
      "service directories must be declared in the manifest: #{undeclared_dirs.join(', ')}")

storage = YAML.safe_load_file(File.join(ROOT, "inventory", "group_vars", "all", "main.yml"))
declared_paths = storage.fetch("nas_storage").map { |entry| entry.fetch("path") }
paperless_postgres_storage = storage.fetch("nas_storage").find do |entry|
  entry["path"] == "{{ nas_docker_root }}/paperless-ngx/postgres"
end
check(failures,
      paperless_postgres_storage && paperless_postgres_storage["mode"] == "0755",
      "Paperless PostgreSQL 18 mount parent must be traversable by the postgres user")
paperless_contract = File.read(File.join(ROOT, "tests", "contracts", "paperless.sh"))
paperless_snapshot = File.read(File.join(ROOT, "tests", "mac", "snapshot-paperless.sh"))
root_version_checksum = %r{
  document\.fetch\("versions"\)\.find\s*\{\s*\|version\|\s*
  version\.fetch\("is_root"\)\s*\}.*?
  root_version&?\.fetch\("checksum"\)
}mx
check(failures,
      paperless_contract.include?("PDF_MARKER = \"paperlesscontractenglish\""),
      "Paperless contract must define the PDF fixture marker")
check(failures,
      paperless_contract.include?("def request(method, path, token: nil, body: nil, expected: [200], parse_json: true, read_timeout: 60)") &&
      paperless_contract.match?(%r{/preview/.*, token: token, parse_json: false}),
      "Paperless binary preview responses must bypass JSON parsing")
check(failures,
      paperless_contract.include?("MAIL_PROBE_READ_TIMEOUT = 180") &&
      paperless_contract.match?(%r{/api/mail_accounts/test/.*?read_timeout:\s*MAIL_PROBE_READ_TIMEOUT}m),
      "Paperless synchronous Gmail probe must use its explicit bounded timeout")
check(failures,
      paperless_contract.match?(root_version_checksum),
      "Paperless checksum verification must select the API v3 root-version checksum")
check(failures,
      paperless_contract.match?(/EXPORT_PATH\.mkdir\(0o700\).*?document_exporter/m),
      "Paperless portable export must create the required empty target directory")
check(failures,
      paperless_contract.match?(%r{
        document_ids\s*=\s*\[.*?
        request\(\s*"post",\s*"/api/trash/".*?
        "action"\s*=>\s*"empty".*?
        "documents"\s*=>\s*document_ids.*?
        document_importer
      }mx),
      "Paperless portable import must empty its exported fixtures from trash first")
check(failures,
      paperless_contract.match?(%r{
        document_importer.*?
        "docker",\s*"restart",\s*WEBSERVER.*?
        wait_healthy\(WEBSERVER.*?
        document_for
      }mx),
      "Paperless portable import must reload and health-check the webserver search index")
check(failures,
      paperless_snapshot.match?(root_version_checksum) &&
      paperless_snapshot.match?(/def catalogue.*?"checksum" => document_checksum\(document\)/m),
      "Paperless snapshot catalogue must use API v3 root-version checksums")
check(failures,
      paperless_contract.match?(/diagnostic_bytes = stderr\.read.*?bytesize > 4096.*?else\s+diagnostic_bytes/m),
      "Paperless exporter diagnostics must preserve short stderr output")

manifest_entries.each do |service|
  next unless service.is_a?(Hash)
  next unless IMPLEMENTED_STATUSES.include?(service["status"])

  name = service["name"]
  role = service["role"]
  next unless name.is_a?(String) && role.is_a?(String)

  services_root = File.join(ROOT, "services")
  service_root = File.join(services_root, name)
  compose_path = File.join(service_root, "compose.yml")
  roles_root = File.join(ROOT, "roles")
  role_root = File.join(ROOT, "roles", role)
  spec_path = File.join(role_root, "meta", "argument_specs.yml")
  tasks_path = File.join(role_root, "tasks", "main.yml")
  service_root_owned = owned_directory?(service_root, services_root)
  role_root_owned = owned_directory?(role_root, roles_root)
  compose_owned = service_root_owned && owned_file?(compose_path, service_root)
  spec_owned = role_root_owned && owned_file?(spec_path, role_root)
  tasks_owned = role_root_owned && owned_file?(tasks_path, role_root)
  check(failures, service_root_owned, "#{name}: service must be a real directory within services")
  check(failures, compose_owned, "#{name}: compose.yml must be a regular file within its service root")
  check(failures, role_root_owned, "#{name}: role must be a real directory within roles")
  check(failures, spec_owned, "#{name}: argument_specs.yml must be a regular file within its role root")
  check(failures, tasks_owned, "#{name}: tasks/main.yml must be a regular file within its role root")
  check(failures, declared_paths.any? { |path| path.include?("/#{name}/") || path.end_with?("/#{name}") },
        "#{name}: implemented service has no storage declaration")

  relative_contract_path = "tests/contracts/#{contract_basename(name)}.sh"
  contract_root = File.join(ROOT, "tests", "contracts")
  contract_path = File.join(ROOT, relative_contract_path)
  role_verification = tasks_owned && role_has_verification?(tasks_path, name, role)
  contract_verification = contract_has_verification?(
    contract_path, contract_root, name, relative_contract_path, contract_registry_entries
  )
  verifies_service = role_verification || contract_verification
  check(failures, verifies_service,
        "#{name}: implemented service has no automated verification or service contract")
end

# Digest pinning with a human-readable version tag, so Renovate can propose
# updates and a reader can tell what is deployed.
IMAGE = %r{\A\S+:[^@\s]+@sha256:[0-9a-f]{64}\z}
SELECTED_IMAGE_PINS = {
  ["services/dozzle/compose.yml", "dozzle"] => "docker.io/amir20/dozzle:v10.7.1@sha256:a8441e9d2928cc7b30d0023f5eedbb87ef6e234d87f3be02662bd8f417955b8b",
  ["services/komga/compose.yml", "komga"] => "docker.io/gotson/komga:1.26.1@sha256:e109902ebebb8a05f633f48d84a2ac7bb1334bf0f6fbc17262a333082c7de44d",
  ["services/paperless-ngx/compose.yml", "gotenberg"] => "docker.io/gotenberg/gotenberg:8.35.0@sha256:a16a14e1f18a71405624bc028e90d4ef50ea774c352b303639c10bf7b141f760",
  ["services/tinymediamanager/compose.yml", "tinymediamanager"] => "docker.io/tinymediamanager/tinymediamanager:5.3.1@sha256:bada62a398e3aabe7a67b0e081c40dc08ce74aa86b7ba63e0a34a1bf278146a4",
  ["services/tinymediamanager/compose.integration.yml", "tinymediamanager"] => "docker.io/tinymediamanager/tinymediamanager:5.3.1@sha256:bada62a398e3aabe7a67b0e081c40dc08ce74aa86b7ba63e0a34a1bf278146a4",
  ["services/tinymediamanager/compose.mac.yml", "tinymediamanager"] => "docker.io/tinymediamanager/tinymediamanager:5.3.1@sha256:bada62a398e3aabe7a67b0e081c40dc08ce74aa86b7ba63e0a34a1bf278146a4"
}.freeze
SUPERSEDED_SELECTED_IMAGE_TAGS = %w[v10.6.14 1.25.0 8.34 5.3.0].freeze

SELECTED_IMAGE_PINS.each do |(relative_path, container), expected_image|
  image = YAML.safe_load_file(File.join(ROOT, relative_path), aliases: true)
              .fetch("services").fetch(container).fetch("image")
  check(failures, image == expected_image,
        "#{relative_path}/#{container}: selected image pin must match the approved immutable reference")
  check(failures, SUPERSEDED_SELECTED_IMAGE_TAGS.none? { |tag| image.include?(":#{tag}@") },
        "#{relative_path}/#{container}: selected image pin must not use a superseded version")
end

service_dirs.each do |dir|
  name = File.basename(dir)
  compose_path = File.join(dir, "compose.yml")
  check(failures, File.file?(compose_path), "#{name}: missing compose.yml")
  next unless File.file?(compose_path)

  compose = YAML.safe_load_file(compose_path, aliases: true)
  containers = compose.fetch("services")

  containers.each do |container, spec|
    label = "#{name}/#{container}"

    check(failures, spec["image"].to_s.match?(IMAGE),
          "#{label}: image must be digest-pinned with a version tag")
    check(failures, !spec.key?("build"),
          "#{label}: must use a published image, not build")
    check(failures, spec["privileged"] != true,
          "#{label}: privileged mode is not allowed")
    check(failures, spec["restart"] == "unless-stopped",
          "#{label}: long-running services must restart unless-stopped")

    logging = spec["logging"] || {}
    check(failures, logging["driver"] == "json-file",
          "#{label}: logging must use the json-file driver")
    options = logging["options"] || {}
    check(failures, options["max-size"] && options["max-file"],
          "#{label}: logging must be bounded by max-size and max-file")

    # Paths must be parameterized. Hardcoded absolutes cannot be redirected, so
    # tests would need override files and local runs would diverge from the NAS.
    Array(spec["volumes"]).each do |mount|
      # The source cannot be split on the first colon, because ${VAR:?} contains
      # one. The container target is always an absolute path, so anchor on that.
      parsed = mount.match(%r{\A(?<source>.*?):(?<target>/[^:]*)(?::(?<mode>ro|rw))?\z})
      check(failures, !parsed.nil?, "#{label}: cannot parse volume entry #{mount}")
      next if parsed.nil?

      source = parsed[:source]
      check(failures, !source.match?(%r{\A/volume\d}),
            "#{label}: volume source #{source} is hardcoded; use ${NAS_DOCKER_ROOT:?} or ${NAS_MEDIA_ROOT:?}")

      inventory_source = if source.include?("NAS_DOCKER_ROOT")
                           source.sub(/\A\$\{NAS_DOCKER_ROOT:\?\}/, "{{ nas_docker_root }}")
                         elsif source == "${AUDIOBOOKSHELF_BACKUP_PATH:?}"
                           "{{ nas_docker_root }}/audiobookshelf/backups"
                         end
      next unless inventory_source

      # Service state must be declared in the storage inventory so host_prep
      # creates it with the right ownership and it gets a recovery class.
      expected = inventory_source
      declared = declared_paths.include?(expected) ||
                 declared_paths.any? { |p| expected.start_with?(p + "/") }
      check(failures, declared,
            "#{label}: #{source} is not declared in nas_storage (expected #{expected})")
    end
  end
end

# Platform Compose files may add capabilities (devices, mounts, profiles, and
# similar host-specific wiring). tinyMediaManager platform overrides retain the
# canonical multi-platform manifest and select linux/amd64 through Compose.
TINYMEDIAMANAGER_IMAGE = SELECTED_IMAGE_PINS.fetch(
  ["services/tinymediamanager/compose.yml", "tinymediamanager"]
)
platform_image_overrides = {
  "services/tinymediamanager/compose.integration.yml" => {
    "tinymediamanager" => TINYMEDIAMANAGER_IMAGE
  },
  "services/tinymediamanager/compose.mac.yml" => {
    "tinymediamanager" => TINYMEDIAMANAGER_IMAGE
  }
}
Dir[File.join(ROOT, "services", "*", "compose.*.yml")].sort.each do |override_path|
  override = YAML.safe_load_file(override_path, aliases: true)
  image_services = override.fetch("services", {}).filter_map do |container, spec|
    [container, spec.fetch("image")] if spec.is_a?(Hash) && spec.key?("image")
  end
  relative_override = override_path.delete_prefix("#{ROOT}/")
  expected_images = platform_image_overrides.fetch(relative_override, {}).to_a
  check(failures, image_services.sort == expected_images.sort,
        "#{relative_override}: platform image overrides differ from the exact allowlist")
end
canonical_tmm_image = YAML.safe_load_file(
  File.join(ROOT, "services", "tinymediamanager", "compose.yml"), aliases: true
).dig("services", "tinymediamanager", "image")
check(failures, canonical_tmm_image == TINYMEDIAMANAGER_IMAGE,
      "tinyMediaManager canonical image must remain the approved multi-platform manifest")

# Every role declares its interface, so a missing variable fails before the first
# task naming the variable rather than midway with a trace.
Dir[File.join(ROOT, "roles", "*")].select { |p| File.directory?(p) }.each do |role|
  name = File.basename(role)
  spec_path = File.join(role, "meta", "argument_specs.yml")
  check(failures, File.file?(spec_path), "role #{name}: missing meta/argument_specs.yml")
  next unless File.file?(spec_path)

  spec = YAML.safe_load_file(spec_path)
  check(failures, spec.dig("argument_specs", "main", "options").is_a?(Hash),
        "role #{name}: argument_specs declares no options")
end

# Deployment goes through the module. A shell-out always claims a change and
# cannot run under --check, which the converge-every-run model depends on.
role_task_files = Dir[File.join(ROOT, "roles", "*", "{tasks,handlers}", "*.yml")]
role_task_files.each do |path|
  body = File.read(path)
  check(failures, !body.match?(/(command|shell):[\s\S]{0,120}docker\s+compose/),
        "#{path}: shells out to Compose; use community.docker.docker_compose_v2")
end
check(failures,
      role_task_files.any? { |p| File.read(p).include?("community.docker.docker_compose_v2") },
      "no role deploys anything through docker_compose_v2")

# Collections are pinned like every image.
requirements = YAML.safe_load_file(File.join(ROOT, "requirements.yml"))
requirements.fetch("collections").each do |collection|
  check(failures, collection["version"].to_s.match?(/\A\d+\.\d+\.\d+\z/),
        "collection #{collection['name']} must be version-pinned")
end

config = File.read(File.join(ROOT, "ansible.cfg"))
check(failures, config.match?(/^inject_facts_as_vars\s*=\s*False/i),
      "ansible.cfg must disable fact injection, removed in ansible-core 2.24")

ci = YAML.safe_load_file(File.join(ROOT, ".github", "workflows", "ci.yml"))
ci_commands = ci.fetch("jobs", {}).values.flat_map do |job|
  Array(job["steps"]).filter_map { |step| step["run"] if step.is_a?(Hash) }
end.flat_map { |run| run.to_s.lines.map(&:strip) }
check(failures, ci_commands.include?("tests/validate-policy.sh"),
      "CI must run tests/validate-policy.sh")

validation_script_path = File.join(ROOT, "tests", "validate-policy.sh")
validation_commands = if owned_file?(validation_script_path, File.join(ROOT, "tests"))
                        File.readlines(validation_script_path).map(&:strip)
                      else
                        []
                      end
%w[
  ruby\ tests/policy_test.rb
  ruby\ tests/policy_manifest_test.rb
  ruby\ tests/run_contracts_test.rb
  ruby\ tests/run_contracts.rb\ --validate-only
  ruby\ tests/database_managed_users_test.rb
  ruby\ tests/database_managed_users_test.rb\ --self-test
  ruby\ tests/immich_configured_password_test.rb
  ruby\ tests/immich_user_onboarding_test.rb
  ruby\ tests/komga_library_reconciliation_test.rb
  ruby\ tests/paperless_mail_reconciliation_test.rb
  tests/integration_lock_test.sh
  tests/mac/manual-validation-runner-test.sh
  tests/mac/audiobookshelf-drift-hook-test.sh
  tests/contracts/audiobookshelf-audio-test.sh
  ruby\ tests/mac/report.rb\ --self-test
  tests/mac/cleanup.sh\ --self-test
  ruby\ tests/mac/sanitize-logs.rb\ --self-test
].each do |command|
  check(failures, validation_commands.include?(command),
        "validate-policy.sh must run #{command}")
end
check(failures,
      validation_commands.count("ruby tests/immich_configured_password_test.rb") == 1,
      "validate-policy.sh must run ruby tests/immich_configured_password_test.rb exactly once")

# Compose interpolates $ in env files and silently truncates an unescaped bcrypt
# hash rather than rejecting it, so escaping is mandatory wherever hashes flow.
Dir[File.join(ROOT, "roles", "*", "templates", "env.j2")].each do |template|
  body = File.read(template)
  next unless body.include?("password_hash") || body.include?("AUTH_USERS")

  check(failures, body.include?("replace('$', '$$')"),
        "#{template}: bcrypt values must escape $ as $$ for Compose")
end

# The vault example is the documented contract; drift means an operator follows it
# and ends up with a vault missing keys the roles require.
example_path = File.join(ROOT, "inventory", "group_vars", "all", "vault.yml.example")
example = YAML.safe_load_file(example_path)
example.each do |key, value|
  next unless value.is_a?(String)
  next if key == "vault_jellyfin_admin_username" && value == "Yonatan"
  next if value.match?(/^example[-_]/) || value.end_with?("@example.invalid")
  next if value.match?(/^\$2b\$12\$0{53}$/)
  next if value.match?(/^tk_[01]{29}$/)
  next if value == "ssh-ed25519 AAAA"
  next if value == "00000000-0000-4000-a000-000000000000"
  next if value.include?("example-only-not-a-real-private-key")

  check(failures, false, "#{example_path}: #{key} looks like a real value, not a placeholder")
end

# The example documents what vault must contain; the generator's template is what
# actually gets written. Drift means an operator follows the example and ends up
# with a vault missing keys the roles require, failing late and confusingly.
def vault_keys(path)
  return [] unless File.file?(path)

  File.readlines(path).filter_map { |line| line[/^\s*(vault_[a-z_]+):/, 1] }.sort
end

vault_contract_sources = {
  "vault.yml.example" => example_path,
  "vault-plain.yml.j2" => File.join(ROOT, "templates", "vault-plain.yml.j2"),
  "vault_contract argument specs" =>
    File.join(ROOT, "roles", "vault_contract", "meta", "argument_specs.yml"),
  "ephemeral vault generator" => File.join(ROOT, "tests", "generate-ephemeral-vault.sh")
}
vault_contract_sources.each do |label, path|
  keys = vault_keys(path)
  duplicate_keys = keys.tally.select { |_key, count| count > 1 }.keys
  check(failures, duplicate_keys.empty?,
        "#{label} contains duplicate vault keys: #{duplicate_keys.join(', ')}")
  (EXPECTED_VAULT_KEYS - keys.uniq).each do |key|
    check(failures, false, "#{label} is missing required portable credential #{key}")
  end
  (keys.uniq - EXPECTED_VAULT_KEYS).each do |key|
    check(failures, false, "#{label} has unexpected or non-portable vault key #{key}")
  end
end

check(failures, vault_contract_sources.values.map { |path| vault_keys(path) }.uniq.length == 1,
      "vault example, template, validation role, and ephemeral generator must have exact schema parity")

vault_contract_spec_path = vault_contract_sources.fetch("vault_contract argument specs")
vault_contract_options = if File.file?(vault_contract_spec_path)
                           YAML.safe_load_file(vault_contract_spec_path)
                               .dig("argument_specs", "main", "options") || {}
                         else
                           {}
                         end
EXPECTED_VAULT_KEYS.each do |key|
  option = vault_contract_options[key]
  check(failures, option.is_a?(Hash) && option["required"] == true,
        "vault contract must require #{key}")
end

vault_contract_tasks_path = File.join(ROOT, "roles", "vault_contract", "tasks", "main.yml")
vault_contract_tasks = File.file?(vault_contract_tasks_path) ?
  YAML.safe_load_file(vault_contract_tasks_path) : []
check(failures, !vault_contract_tasks.empty? && vault_contract_tasks.all? { |task| task["no_log"] == true },
      "every vault contract task must use no_log")
shape_conditions = vault_contract_tasks.flat_map do |task|
  Array(task.dig("ansible.builtin.assert", "that"))
end.join(" ")
EXPECTED_VAULT_KEYS.each do |key|
  check(failures, shape_conditions.match?(/\b#{Regexp.escape(key)}\b/),
        "vault contract shape validation must inspect #{key}")
end
check(failures, vault_contract_tasks.none? { |task| task.to_s.match?(/vault_[a-z_]+\s*\|\s*hash/) },
      "vault contract must never hash an individual plaintext credential")

vault_metadata_index = vault_contract_tasks.index do |task|
  task["name"] == "Inspect the candidate vault artifact without hashing"
end
vault_header_index = vault_contract_tasks.index do |task|
  task["name"] == "Read only the encrypted vault format header"
end
vault_encryption_guard_index = vault_contract_tasks.index do |task|
  task["name"] == "Require the reported vault artifact to be encrypted"
end
vault_checksum_index = vault_contract_tasks.index do |task|
  task["name"] == "Compute the encrypted vault artifact SHA-256"
end
vault_metadata_task = vault_metadata_index && vault_contract_tasks[vault_metadata_index]
vault_order_indexes = [
  vault_metadata_index,
  vault_header_index,
  vault_encryption_guard_index,
  vault_checksum_index
]
check(failures,
      vault_metadata_task&.dig("ansible.builtin.stat", "get_checksum") == false &&
        vault_order_indexes.all? { |index| index.is_a?(Integer) } &&
        vault_order_indexes.each_cons(2).all? { |left, right| left < right },
      "vault contract must verify encryption header before computing SHA-256")

site_pre_tasks = Array(site_play["pre_tasks"])
vault_contract_index = site_pre_tasks.index do |task|
  task.dig("ansible.builtin.include_role", "name") == "vault_contract"
end
first_mutation_guard = site_pre_tasks.index do |task|
  task.dig("ansible.builtin.include_role", "name") == "deployment_bundle"
end
check(failures, vault_contract_index == 0 && first_mutation_guard && vault_contract_index < first_mutation_guard,
      "site.yml must validate the vault contract before every target pre-task")
site_vault_contract = vault_contract_index && site_pre_tasks[vault_contract_index]
check(failures, site_vault_contract&.dig("ansible.builtin.include_role", "apply", "no_log") == true,
      "site.yml must redact vault role argument validation")

validate_vault_play = if File.file?(File.join(ROOT, "validate-vault.yml"))
                        YAML.safe_load_file(File.join(ROOT, "validate-vault.yml")).first
                      else
                        {}
                      end
validate_vault_role = Array(validate_vault_play["roles"]).find do |role|
  role.is_a?(Hash) && role["role"] == "vault_contract"
end
check(failures, validate_vault_role && validate_vault_role["no_log"] == true,
      "validate-vault.yml must redact vault role argument validation")

secret_generator_path = File.join(ROOT, "generate-secrets.yml")
secret_generator = YAML.safe_load_file(secret_generator_path).first
check(failures, secret_generator.dig("vars", "generate_brand_new_platform") == false,
      "generate-secrets.yml must default brand-new-platform confirmation to false")
brand_new_guard = Array(secret_generator["tasks"]).find do |task|
  task["name"] == "Require explicit confirmation of a brand-new platform"
end
guard_conditions = Array(brand_new_guard&.dig("ansible.builtin.assert", "that")).join(" ")
guard_message = brand_new_guard&.dig("ansible.builtin.assert", "fail_msg").to_s
check(failures, guard_conditions.include?("generate_brand_new_platform | bool") &&
                guard_message.include?("password manager") && guard_message.include?("Portainer"),
      "generate-secrets.yml must refuse migration credential generation explicitly")

secret_generator_tasks = Array(secret_generator["tasks"]).to_h { |task| [task["name"], task] }
secret_bearing_generator_tasks = [
  "Generate passwords",
  "Read the Beszel hub keypair",
  "Hash the ntfy passwords with ntfy's own hasher",
  "Generate the ntfy access tokens with ntfy's own generator",
  "Collect the generated material",
  "Fail loudly if any value did not parse",
  "Write the plaintext vars file for encryption"
]
secret_bearing_generator_tasks.each do |task_name|
  check(failures, secret_generator_tasks.dig(task_name, "no_log") == true,
        "generate-secrets.yml must redact secret-bearing task #{task_name}")
end

ci_body = File.read(File.join(ROOT, ".github", "workflows", "ci.yml"))
check(failures,
      ci_body.include?("tests/generate-ephemeral-vault.sh --self-test") &&
        ci_body.include?("test ! -s") &&
        %w[apache2-utils openssh-client openssl].all? { |dependency| ci_body.include?(dependency) },
      "CI must run the silent ephemeral vault self-test with explicit dependencies")
check(failures, ci_body.include?("tests/generate-secrets-redaction-test.sh"),
      "CI must execute the generated-secret redaction test")

ephemeral_helper = File.read(File.join(ROOT, "tests", "generate-ephemeral-vault.sh"))
helper_safety_evidence = {
  "pre-existing output refusal" => "self-test generation accepted a pre-existing output",
  "vault leaf symlink refusal" => "self-test generation accepted a vault output symlink",
  "password leaf symlink refusal" => "self-test generation accepted a password output symlink",
  "unexpected entry refusal" => "self-test generation accepted an unexpected entry",
  "in-repository refusal" => "self-test generation accepted an in-repository directory",
  "TMPDIR symlink refusal" => "self-test accepted a symlink temporary parent",
  "trailing-slash symlink refusal" => "self-test cleanup accepted a trailing-slash symlink alias",
  "lexical alias refusal" => "self-test cleanup accepted a non-normalized lexical alias",
  "trailing-slash TMPDIR refusal" => "self-test accepted a trailing-slash symlink temporary parent",
  "unsafe mode refusal" => "self-test generation accepted a world-writable directory",
  "ownership refusal" => "self-test generation accepted a foreign-owned directory",
  "failure cleanup" => "self-test failed generation left credential material",
  "mid-validation cleanup" => "self-test mid-validation failure left credential material"
}
helper_safety_evidence.each do |property, evidence|
  check(failures, ephemeral_helper.include?(evidence),
        "ephemeral vault self-test must cover #{property}")
end
helper_guard_sources = {
  "requested-path lexical guard" => 'validate_lexical_path "$requested"',
  "temporary-parent lexical guard" => 'validate_lexical_path "$temporary_parent_input"',
  "temporary-parent symlink guard" => '[ ! -L "$temporary_parent_input" ]',
  "directory symlink guard" => '[ ! -L "$requested" ]',
  "directory ownership guard" => '[ "$(owner_id "$physical")" = "$(id -u)" ]',
  "directory mode guard" => '[ "$(file_mode "$physical")" = 700 ]',
  "repository containment guard" => '"$repo_dir/"*) die',
  "output overwrite and symlink guard" => '[ ! -e "$candidate" ] && [ ! -L "$candidate" ]',
  "empty-directory guard" => '[ -z "$(find "$directory" -mindepth 1 -maxdepth 1 -print -quit)" ]',
  "cleanup unexpected-entry guard" => '! -name vault.yml ! -name password -print -quit',
  "cleanup leaf-symlink guard" => '[ ! -L "$directory/vault.yml" ] && [ ! -L "$directory/password" ]',
  "failure trap isolation" => "generate_vault() (",
  "failure cleanup trap" => 'trap \'rm -f -- "$plain" "$private_key" "$private_key.pub" "$password_file" "$output"\' EXIT',
  "self-test cleanup trap" => "trap self_test_cleanup_on_exit EXIT"
}
helper_guard_sources.each do |property, source|
  check(failures, ephemeral_helper.include?(source),
        "ephemeral vault helper must preserve #{property}")
end
check(failures,
      ephemeral_helper.include?('kernel_name=$(uname -s)') &&
        ephemeral_helper.include?('stat -f') && ephemeral_helper.include?('stat -c') &&
        ephemeral_helper.include?("refusing symlink temporary parent"),
      "ephemeral vault helper must preserve GNU/BSD checks and refuse TMPDIR symlinks")

repository_vault_nas_references = Dir[File.join(ROOT, "{inventory,roles,templates,tests}", "**", "*")]
                                  .select { |path| File.file?(path) }
                                  .filter_map do |path|
  relative = path.delete_prefix("#{ROOT}/")
  next if %w[tests/policy_test.rb tests/policy_manifest_test.rb].include?(relative)

  relative if File.binread(path).match?(/\bvault_nas_[a-z_]+\b/n)
end
check(failures, repository_vault_nas_references.empty?,
      "NAS connection coordinates must stay in inventory, not shared vault: " \
      "#{repository_vault_nas_references.join(', ')}")

vault_path = File.join(ROOT, "inventory", "group_vars", "all", "vault.yml")
if File.file?(vault_path)
  first = File.open(vault_path, &:readline).strip
  check(failures, first.start_with?("$ANSIBLE_VAULT;"), "vault.yml is present but not encrypted")
end

# The plays must be exercised, not merely parsed: the two worst bugs so far, a
# Darwin-only fact and command being skipped under --check, both survived syntax
# checking and were caught by running.
harness = File.read(File.join(ROOT, "tests", "integration.sh"))
dozzle_contract = File.read(File.join(ROOT, "tests", "contracts", "dozzle.sh"))
check(failures, dozzle_contract.include?('exec ruby - "$mode" "$@"'),
      "Dozzle contract must pass its default verify mode to the dynamic probe")
integration_lock_path = File.join(ROOT, "tests", "integration_lock.sh")
integration_lock = File.file?(integration_lock_path) ? File.read(integration_lock_path) : ""
mac_path_fixture = File.read(File.join(ROOT, "tests", "mac_inventory_path_test.yml"))
check(failures, harness.include?("MAC_PATH_CANONICAL") &&
                harness.include?("MAC_PATH_LEXICAL_REFUSED") &&
                harness.include?("mac_inventory_path_test.yml") &&
                mac_path_fixture.include?("tasks_from: target") &&
                mac_path_fixture.include?("EXPECTED_PLATFORM_DOCKER_ROOT"),
      "integration must prove canonical Mac paths pass target validation")
["IDEMPOTENT", "CHECK MODE"].each do |property|
  check(failures, harness.include?(property), "integration harness must assert #{property}")
end
first_converge = harness.index("\n    run_play\n")
contract_execution = harness.index("ruby /repo/tests/run_contracts.rb --execute")
idempotence_phase = harness.index("=== phase 2: asserting idempotence ===")
check(failures, first_converge && contract_execution && idempotence_phase &&
                first_converge < contract_execution && contract_execution < idempotence_phase,
      "integration must execute registered contracts after converge and before idempotence")
contract_abi_names = %w[
  PLATFORM_KIND PLATFORM_CONTRACT_VAULT_FILE PLATFORM_DOCKER_ROOT
  PLATFORM_MEDIA_ROOT PLATFORM_FIXTURE_ROOT PLATFORM_REPORT_ROOT
]
contract_environment_start = contract_execution && harness.rindex("\n      env \\", contract_execution)
contract_environment = if contract_environment_start && contract_execution
                         harness[contract_environment_start..contract_execution]
                       else
                         ""
                       end
check(failures, contract_execution && contract_abi_names.all? do |name|
  contract_environment.include?("#{name}=")
end, "integration must set the contract environment ABI before execution")
run_play_body = harness[/^    run_play\(\) \{.*?^    \}/m].to_s
check(failures, harness.match?(/^ruby_package='ruby=\d+\.\d+\.\d+-r\d+'$/) &&
                harness.match?(/^curl_package='curl=\d+\.\d+\.\d+-r\d+'$/),
      "integration must pin distro ruby and curl packages")
check(failures,
      harness.include?("/repo/tests/generate-ephemeral-vault.sh") &&
      harness.include?("--output \\\"\\$vault_file\\\"") &&
        harness.include?("--password-file") &&
        run_play_body.include?("--vault-password-file \\\"\\$vault_password_file\\\"") &&
        run_play_body.include?("-e @\\\"\\$vault_file\\\"") &&
        run_play_body.include?("-e platform_vault_file=\\\"\\$vault_file\\\"") &&
        harness.include?("TMPDIR='$sandbox' /repo/tests/generate-ephemeral-vault.sh --cleanup") &&
        contract_environment.include?("PLATFORM_CONTRACT_VAULT_FILE=\\\"\\$vault_file\\\"") &&
        !harness.include?("sandbox-vault.yml") &&
        !harness.include?("random_password()") &&
        !harness.include?("ntfy_token()"),
      "integration must consume the ephemeral encrypted vault without duplicate secret authoring")
check(failures,
      harness.include?('/repo/tests/mac/generate-immich-fixture-vars.rb') &&
        harness.include?('fixture_vars_file=\"\$fixture_input_directory/immich-fixture-vars.yml\"') &&
        harness.include?('PLATFORM_MAC_FIXTURE_VARS_FILE=\"\$fixture_vars_file\"') &&
        harness.include?('chmod 0600 \"\$fixture_vars_file\"') &&
        harness.include?('rm -f \"\$fixture_vault_view\"') &&
        harness.include?('trap cleanup_fixture_vault_view EXIT'),
      "integration must generate and protect the Immich fixture policy")
check(failures,
      harness.include?('controller_mount=$sandbox/repo') &&
        harness.include?('git clone --quiet --no-local --no-checkout "$repo_dir" "$controller_mount"') &&
        harness.include?('git -C "$controller_mount" checkout -q --detach "$expected_release_id"') &&
        harness.include?('-v "$controller_mount":/repo') &&
        harness.include?('install -m 0600 \"\$vault_file\" /repo/inventory/group_vars/all/vault.yml') &&
        !harness.include?('controller_mount=$repo_dir'),
      "integration must isolate normal and linked-worktree controllers before installing its ephemeral vault")
lock_acquire_index = harness.index("acquire_integration_lock")
sandbox_create_index = harness.index('sandbox=$(mktemp -d')
check(failures,
      harness.include?('. "$repo_dir/tests/integration_lock.sh"') &&
        lock_acquire_index && sandbox_create_index && lock_acquire_index < sandbox_create_index &&
        harness.include?("cleanup_sandbox") && harness.include?("release_integration_lock") &&
        integration_lock.include?('mkdir "$lock_candidate"') &&
        integration_lock.include?('rmdir "$integration_lock_path"') &&
        !integration_lock.match?(/rm\s+-rf/),
      "integration must serialize fixed-name containers with an atomic empty-directory lock")

# A release ID names committed controller content. Production must reject any
# modified or untracked file in the controller checkout; only the disposable
# integration platform may opt into the deliberately dirty pre-commit tree.
deployment_defaults_path = File.join(ROOT, "roles", "deployment_bundle", "defaults", "main.yml")
deployment_defaults = File.file?(deployment_defaults_path) ? YAML.safe_load_file(deployment_defaults_path) : {}
check(failures, deployment_defaults["deployment_bundle_allow_dirty_controller"] == false,
      "deployment bundle must refuse dirty controller sources by default")

deployment_spec = YAML.safe_load_file(
  File.join(ROOT, "roles", "deployment_bundle", "meta", "argument_specs.yml")
)
dirty_option = deployment_spec.dig(
  "argument_specs", "main", "options", "deployment_bundle_allow_dirty_controller"
)
check(failures, dirty_option.is_a?(Hash) && dirty_option["type"] == "bool" &&
                dirty_option["default"] == false,
      "deployment bundle dirty-source bypass must be an explicit false boolean option")
test_mode_option = deployment_spec.dig(
  "argument_specs", "main", "options", "deployment_bundle_test_mode"
)
check(failures, test_mode_option.is_a?(Hash) && test_mode_option["type"] == "bool" &&
                test_mode_option["default"] == false,
      "deployment bundle test mode must be an explicit false boolean option")
platform_kind_option = deployment_spec.dig("argument_specs", "main", "options", "platform_kind")
check(failures, platform_kind_option.is_a?(Hash) && platform_kind_option["choices"] == %w[nas mac],
      "deployment bundle platform_kind must allow only nas or mac")
compose_kind_option = deployment_spec.dig(
  "argument_specs", "main", "options", "platform_compose_kind"
)
check(failures, compose_kind_option.is_a?(Hash) && compose_kind_option["type"] == "str" &&
                compose_kind_option["required"] == true,
      "deployment bundle must require a separate platform_compose_kind")

deployment_tasks = flatten_tasks(YAML.safe_load_file(
  File.join(ROOT, "roles", "deployment_bundle", "tasks", "controller.yml")
))
dirty_guard = deployment_tasks.find { |task| task["name"] == "Restrict dirty controller bypass to integration" }
compose_override_guard = deployment_tasks.find do |task|
  task["name"] == "Restrict Compose override selection to explicit test mode"
end
cleanliness_check = deployment_tasks.find { |task| task["name"] == "Inspect controller bundle source cleanliness" }
cleanliness_assert = deployment_tasks.find { |task| task["name"] == "Require committed controller bundle sources" }
dirty_guard_conditions = dirty_guard&.dig("ansible.builtin.assert", "that").to_s
compose_override_conditions = compose_override_guard&.dig("ansible.builtin.assert", "that").to_s
check(failures, compose_override_conditions.include?("platform_kind in ['nas', 'mac']") &&
                compose_override_conditions.include?("platform_compose_kind == platform_kind") &&
                compose_override_conditions.include?("deployment_bundle_test_mode"),
      "Compose override selection must require explicit test mode")
check(failures, dirty_guard_conditions.include?("platform_compose_kind == 'integration'") &&
                dirty_guard_conditions.include?("deployment_bundle_test_mode"),
      "dirty controller bypass must require explicit integration Compose test mode")
cleanliness_argv = cleanliness_check&.dig("ansible.builtin.command", "argv")
expected_cleanliness_argv = [
  "git", "-C", "{{ playbook_dir }}", "status", "--porcelain=v1", "--untracked-files=all"
]
check(failures, cleanliness_argv == expected_cleanliness_argv,
      "deployment bundle must inspect the whole tracked and untracked controller checkout")
check(failures, cleanliness_assert&.dig("ansible.builtin.assert", "that").to_s
                .include?("deployment_bundle_allow_dirty_controller"),
      "deployment bundle must refuse dirty sources unless the guarded bypass is enabled")
check(failures, cleanliness_assert && !cleanliness_assert.key?("run_once"),
      "dirty controller refusal must be evaluated independently for every target host")
check(failures, !harness.include?("-e platform_kind=integration") &&
                harness.include?("-e platform_compose_kind=integration") &&
                harness.include?("-e deployment_bundle_test_mode=true") &&
                harness.include?("-e deployment_bundle_allow_dirty_controller=true"),
      "integration must preserve platform_kind and explicitly enable its Compose test override")
%w[
  DIRTY_TRACKED_REFUSED DIRTY_UNTRACKED_REFUSED
  DIRTY_MANIFEST_TEMPLATE_REFUSED DIRTY_ARBITRARY_CONTROLLER_FILE_REFUSED
  DIRTY_PRODUCTION_BYPASS_REFUSED DIRTY_INTEGRATION_ACCEPTED
  DIRTY_REFUSAL_TARGET_UNCHANGED
].each do |evidence|
  check(failures, harness.include?(evidence),
        "integration must execute and report #{evidence.downcase.tr('_', ' ')}")
end
site_play = YAML.safe_load_file(File.join(ROOT, "site.yml")).first
controller_preflight = Array(site_play["pre_tasks"]).find do |task|
  include_role = task["ansible.builtin.include_role"]
  include_role.is_a?(Hash) && include_role["name"] == "deployment_bundle" &&
    include_role["tasks_from"] == "controller" &&
    Array(include_role.dig("apply", "tags")).include?("always")
end
check(failures, !controller_preflight.nil?,
      "controller bundle cleanliness must be validated before target-mutating roles")

# Target-side deployment paths are hostile inputs until both their lexical form
# and existing filesystem ancestry have been checked. Validation is read-only,
# runs before preflight, is repeated next to destructive operations, and runs
# again before service roles write runtime configuration or consume `current`.
target_tasks_path = File.join(ROOT, "roles", "deployment_bundle", "tasks", "target.yml")
target_tasks_body = File.file?(target_tasks_path) ? File.read(target_tasks_path) : ""
target_validator_path = File.join(ROOT, "roles", "deployment_bundle", "files", "validate_target.py")
target_validator_body = File.file?(target_validator_path) ? File.read(target_validator_path) : ""
target_tasks = File.file?(target_tasks_path) ? YAML.safe_load_file(target_tasks_path) : []
target_validation_tasks = Array(target_tasks).select do |task|
  task["name"] == "Validate target path ancestry and canonical containment"
end
target_validation = target_validation_tasks.one? ? target_validation_tasks.first : {}
target_validation_argv = Array(target_validation.dig("ansible.builtin.command", "argv"))
validator_lookup = "{{ lookup('ansible.builtin.file', role_path ~ '/files/validate_target.py') }}"
check(failures, target_validation_tasks.one? &&
                target_validation_argv[1] == "-c" &&
                target_validation_argv[2] == validator_lookup &&
                target_validation_argv.count(validator_lookup) == 1,
      "target containment task must execute the exact extracted validator source")
check(failures, target_validation_argv.length == 12 &&
                target_validation_argv[3] == "{{ nas_docker_root }}" &&
                target_validation_argv[4] == "{{ nas_media_root }}" &&
                target_validation_argv[9].include?("deployment_target_candidate_paths") &&
                target_validation_argv[9].include?("to_json") &&
                target_validation_argv[10] == "{{ platform_adoption_root | default('') }}" &&
                target_validation_argv[11].include?("platform_adoption_enabled"),
      "target containment task must pass one JSON target batch and adoption binding")
check(failures, !target_validation.key?("loop") && !target_validation.key?("loop_control"),
      "target containment task must validate the batch without an Ansible loop")
%w[os.lstat os.path.realpath os.path.commonpath os.path.lexists].each do |primitive|
  check(failures, target_validator_body.include?(primitive),
        "target validator must use #{primitive} for symlink-safe canonical containment")
end
check(failures, target_tasks_body.include?("concurrent privileged filesystem mutation"),
      "target validator must document its adjacent-revalidation threat boundary")
check(failures, target_validator_body.include?("os.path.abspath(os.sep)") &&
                target_validator_body.include?("root_relative_parts"),
      "target validator must lstat every existing ancestor from filesystem root to nas_docker_root")
check(failures, target_tasks_body.include?("nas_docker_root ~ '/.nas-platform-preflight-probe'") ||
                target_tasks_body.include?("{{ nas_docker_root }}/.nas-platform-preflight-probe"),
      "target validator must guard the exact preflight probe leaf")
check(failures, target_tasks_body.include?("deployment_bundle_services") &&
                target_tasks_body.include?("platform_runtime_dir ~ '/services/'"),
      "target validator must guard every implemented runtime service leaf")

controller_input_path = File.join(ROOT, "roles", "deployment_bundle", "tasks", "controller_input.yml")
controller_input_body = File.file?(controller_input_path) ? File.read(controller_input_path) : ""
%w[os.lstat os.path.realpath os.path.commonpath stat.S_ISREG].each do |primitive|
  check(failures, controller_input_body.include?(primitive),
        "controller input validator must use #{primitive}")
end
inputs_path = File.join(ROOT, "roles", "deployment_bundle", "tasks", "inputs.yml")
inputs_body = File.file?(inputs_path) ? File.read(inputs_path) : ""
check(failures, inputs_body.include?("services/manifest.yml") &&
                inputs_body.include?("compose.yml") &&
                inputs_body.include?("compose.{{ platform_compose_kind }}.yml"),
      "controller inputs must validate manifest, canonical Compose, and platform overrides")

target_preflight_index = Array(site_play["pre_tasks"]).index do |task|
  include_role = task["ansible.builtin.include_role"]
  include_role.is_a?(Hash) && include_role["name"] == "deployment_bundle" &&
    include_role["tasks_from"] == "target" &&
    Array(include_role.dig("apply", "tags")).include?("always")
end
check(failures, !target_preflight_index.nil?,
      "target containment must be validated before preflight can mutate the target")

preflight_body = File.read(File.join(ROOT, "roles", "preflight", "tasks", "main.yml"))
check(failures, preflight_body.include?("{{ nas_docker_root }}/.nas-platform-preflight-probe") &&
                !preflight_body.include?("{{ platform_deploy_root }}/.preflight-probe"),
      "fresh-install preflight must probe the existing validated nas_docker_root")
probe_inspection = preflight_body.index("Inspect the deterministic write probe path")
probe_creation = preflight_body.index("Confirm the service state root is writable")
check(failures, probe_inspection && probe_creation && probe_inspection < probe_creation &&
                preflight_body.include?("not preflight_write_probe.stat.exists"),
      "preflight must refuse a pre-existing deterministic probe before creating it")

deployment_body = File.read(File.join(ROOT, "roles", "deployment_bundle", "tasks", "main.yml"))
deployment_tasks = flatten_tasks(YAML.safe_load(deployment_body))
input_tasks = flatten_tasks(YAML.safe_load(inputs_body))
manifest_path_validation = input_tasks.find do |task|
  task["name"] == "Validate manifest service path components before interpolation"
end
manifest_path_conditions = Array(
  manifest_path_validation&.dig("ansible.builtin.assert", "that")
).join(" ")
check(failures, manifest_path_conditions.include?("item.name is match") &&
                manifest_path_conditions.include?("item.role is match") &&
                manifest_path_conditions.include?("item.legacy_path =="),
      "deployment bundle must validate manifest service path components")
canonical_requirement = deployment_tasks.find do |task|
  task["name"] == "Require canonical Compose for each implemented service"
end
canonical_conditions = Array(canonical_requirement&.dig("ansible.builtin.assert", "that")).join(" ")
check(failures, canonical_conditions.include?("not item.stat.islnk"),
      "canonical Compose validation must explicitly reject symlinks")
%w[
  Revalidate_before_removing_the_staging_release
  Revalidate_before_replacing_an_inactive_release
  Revalidate_before_installing_the_immutable_release
  Revalidate_before_replacing_the_current_pointer
  Revalidate_before_activating_the_controller_release
].each do |task_token|
  check(failures, deployment_body.tr(" ", "_").include?(task_token),
        "deployment bundle must #{task_token.downcase.tr('_', ' ')}")
end
%w[stat.S_IMODE st.st_uid st.st_gid os.lstat].each do |metadata|
  check(failures, deployment_body.include?(metadata),
        "immutable release comparison must include #{metadata}")
end

%w[ntfy beszel].each do |service_name|
  service_body = File.read(File.join(ROOT, "roles", service_name, "tasks", "main.yml"))
  target_validation = service_body.index("tasks_from: target")
  runtime_use = [service_body.index("platform_runtime_dir"), service_body.index("platform_current_dir")].compact.min
  check(failures, !runtime_use || (target_validation && target_validation < runtime_use),
        "#{service_name} must revalidate target paths before runtime/current use")
  if target_validation
    check(failures, service_body.include?("/compose.yml") &&
                    service_body.include?("/compose.{{ platform_compose_kind }}.yml"),
          "#{service_name} must guard every Compose file consumed by selective runs")
  end
end

deployment_manifest_template = File.read(
  File.join(ROOT, "roles", "deployment_bundle", "templates", "manifest.yml.j2")
)
check(failures, deployment_manifest_template.include?("platform_release_id | to_json"),
      "deployment manifest must quote git_sha as a YAML string")
check(failures, deployment_manifest_template.include?("platform_compose") &&
                deployment_manifest_template.include?("canonical_compose") &&
                deployment_manifest_template.include?("compose_service_name"),
      "deployment manifest images must merge canonical and platform Compose services")
compose_metadata_filter = File.read(
  File.join(ROOT, "filter_plugins", "compose_metadata.py")
)
compose_metadata_behavior = File.read(
  File.join(ROOT, "tests", "compose_metadata_filter_test.yml")
)
check(failures, deployment_manifest_template.include?("| platform_compose_metadata") &&
                !deployment_manifest_template.match?(/regex_replace\(['\"]!override|regex_replace\(['\"]!reset/),
      "deployment manifest must parse Compose tags without rewriting source text")
check(failures, compose_metadata_filter.include?("yaml.SafeLoader") &&
                compose_metadata_filter.include?("(\"!override\", \"!reset\")") &&
                compose_metadata_filter.include?("except yaml.YAMLError") &&
                compose_metadata_filter.include?("unsupported YAML") &&
                !compose_metadata_filter.include?("add_multi_constructor"),
      "Compose metadata loader must allow only exact known tags and fail closed")
check(failures, compose_metadata_behavior.include?("quoted, block, and commented literal markers") &&
                compose_metadata_behavior.include?("Require unknown YAML tags to fail closed") &&
                File.read(File.join(ROOT, "tests", "validate-policy.sh"))
                    .include?("tests/compose_metadata_filter_test.yml"),
      "policy validation must execute Compose metadata parser behavior tests")

site_source = File.read(File.join(ROOT, "site.yml"))
check(failures, !site_source.include?("nothing is delegated to the controller"),
      "site documentation must acknowledge explicit controller delegation")

integration_evidence = harness + File.read(File.join(ROOT, "tests", "verify_deployment_manifest.rb"))
%w[
  STALE_ROOT_SEEDED STALE_BUNDLE_REPLACED STALE_BUNDLE_CLEAN STALE_MANIFEST_EXACT
  ISOLATED_IMAGE_MERGE_EXACT
  RUNTIME_SERVICE_SYMLINK_REFUSED RUNTIME_SERVICE_SYMLINK_PRESERVED
  CONTROLLER_MANIFEST_SYMLINK_REFUSED CONTROLLER_OVERRIDE_SYMLINK_REFUSED
  CONTROLLER_SYMLINK_TARGET_UNCHANGED SYMLINK_BESZEL_COMPOSE_REFUSED
  FRESH_ROOT_OK SYMLINK_DOCKER_ROOT_REFUSED SYMLINK_DEPLOY_ROOT_REFUSED SYMLINK_RELEASES_REFUSED
  SYMLINK_RUNTIME_REFUSED SYMLINK_ROOT_ANCESTOR_REFUSED
  SYMLINK_PREFLIGHT_PROBE_REFUSED SYMLINK_NTFY_COMPOSE_REFUSED
  EXISTING_PREFLIGHT_PROBE_REFUSED EXISTING_PREFLIGHT_PROBE_PRESERVED
  SYMLINK_ESCAPE_STATE_UNCHANGED
  ACTIVE_BYTE_DRIFT_REFUSED ACTIVE_MODE_DRIFT_REFUSED ACTIVE_OWNERSHIP_DRIFT_REFUSED
  ACTIVE_DRIFT_PRESERVED
  MANIFEST_EXACT MANIFEST_EFFECTIVE_IMAGES
].each do |evidence|
  check(failures, integration_evidence.include?(evidence),
        "integration must execute and report #{evidence.downcase.tr('_', ' ')}")
end
check(failures, harness.include?('stale_docker_root="$sandbox/stale-root/Docker"') &&
                harness.include?("test ! -e '$sandbox/volume1/Docker/nas-platform'"),
      "integration must isolate stale replacement from the genuinely fresh service root")
manifest_verifier = File.read(File.join(ROOT, "tests", "verify_deployment_manifest.rb"))
check(failures, manifest_verifier.include?("require-image-merge") &&
                manifest_verifier.include?("if require_image_merge"),
      "effective-image replacement proof must be opt-in for an isolated fixture")

# Identity reads must be server-filtered and retain totals so the role can refuse
# an identity result that exceeds the complete 500-record response page.
beszel_tasks = flatten_tasks(
  YAML.safe_load_file(File.join(ROOT, "roles", "beszel", "tasks", "main.yml"))
)

host_prep_tasks = YAML.safe_load_file(File.join(ROOT, "roles", "host_prep", "tasks", "main.yml"))
host_prep_create = host_prep_tasks.find do |task|
  task["name"] == "Create service state directories"
end
host_prep_file = host_prep_create&.fetch("ansible.builtin.file", {})
check(failures, host_prep_file["owner"].to_s.include?("platform_kind == 'nas'") &&
                host_prep_file["owner"].to_s.include?("platform_manage_linux_ownership | bool") &&
                host_prep_file["group"].to_s.include?("platform_kind == 'nas'") &&
                host_prep_file["group"].to_s.include?("platform_manage_linux_ownership | bool") &&
                host_prep_file["owner"].to_s.include?("else omit") &&
                host_prep_file["group"].to_s.include?("else omit"),
      "host preparation must restrict Linux ownership to the explicit integration capability")

preflight_tasks = YAML.safe_load_file(File.join(ROOT, "roles", "preflight", "tasks", "main.yml"))
ownership_guard = preflight_tasks.find do |task|
  task["name"] == "Restrict synthetic Linux ownership correction"
end&.dig("ansible.builtin.assert", "that")&.join(" ").to_s
%w[platform_manage_linux_ownership platform_compose_kind deployment_bundle_test_mode
   ansible_facts.system nas_docker_root nas_media_root].each do |token|
  check(failures, ownership_guard.include?(token),
        "integration Linux ownership guard must bind #{token}")
end

beszel_user_lists = beszel_tasks.select do |task|
  task["name"].to_s.start_with?("List application users") &&
    task["ansible.builtin.uri"].is_a?(Hash)
end
check(failures, beszel_user_lists.length == 2,
      "Beszel role must contain both application-user list operations")
beszel_user_lists.each do |task|
  url = task.dig("ansible.builtin.uri", "url")
  check(failures, url.is_a?(String) && url.include?("filter={{") && url.include?("urlencode") &&
                  !url.include?("skipTotal=1"),
        "#{task['name']}: must use a complete URL-encoded server identity filter")
end
check(failures,
      beszel_contract.include?('body: { role: "user" })') &&
        beszel_contract.include?('user["role"] == "user" && user["verified"] == true') &&
        !beszel_contract.include?('body: { role: "user", verified: false }'),
      "Beszel drift fixture must preserve the verified authentication prerequisite while drifting role")

beszel_complete_user_read = beszel_tasks.find do |task|
  task["name"] == "Read the complete PocketBase users collection for managed users"
end
check(failures,
      beszel_complete_user_read&.dig("ansible.builtin.uri", "url") ==
        "{{ beszel_api }}/api/collections/users/records?perPage=500",
      "Beszel managed users must reuse one explicitly bounded complete users collection")
beszel_complete_user_assert = beszel_tasks.find do |task|
  task["name"] == "Require a complete PocketBase users collection"
end
complete_user_conditions = Array(
  beszel_complete_user_assert&.dig("ansible.builtin.assert", "that")
).join(" ")
check(failures, complete_user_conditions.include?("totalPages") &&
                complete_user_conditions.include?("totalItems"),
      "Beszel complete users collection must prove pagination and item-count completeness")

beszel_alert_tasks = flatten_tasks(
  YAML.safe_load_file(File.join(ROOT, "roles", "beszel", "tasks", "alert.yml"))
)
identity_reads = (beszel_tasks + beszel_alert_tasks).select do |task|
  uri = task["ansible.builtin.uri"]
  uri.is_a?(Hash) && uri["method"].nil? && uri["url"].to_s.match?(%r{/collections/(users|universal_tokens|user_settings|systems|alerts)/records\?})
end
check(failures, identity_reads.length >= 11,
      "Beszel reconciliation must retain all filtered collection readbacks")
identity_reads.each do |task|
  next if task["name"] == "Read the complete PocketBase users collection for managed users"

  url = task.dig("ansible.builtin.uri", "url").to_s
  check(failures, url.include?("filter={{") && url.include?("urlencode") && !url.include?("skipTotal=1"),
        "#{task['name']}: collection readback must use a URL-encoded identity filter with totals")
end

beszel_create_user = beszel_tasks.find { |task| task["name"] == "Create the application user" }
beszel_plan_user = beszel_tasks.find { |task| task["name"] == "Report planned application user creation" }
check(failures, beszel_create_user && beszel_create_user["changed_when"] == true &&
                beszel_plan_user && beszel_plan_user["changed_when"] == true &&
                Array(beszel_plan_user["when"]).include?("ansible_check_mode"),
      "Beszel user creation must report real and check-mode predicted changes")

webhook_assert = beszel_tasks.find { |task| task["name"] == "Verify the managed ntfy webhook" }
webhook_failure = webhook_assert&.dig("ansible.builtin.assert", "fail_msg").to_s
webhook_summary = beszel_tasks.find do |task|
  task["name"] == "Summarize the managed ntfy webhook without URL bodies"
end
check(failures, webhook_failure.include?("scheme=") && webhook_failure.include?("[REDACTED]") &&
                !webhook_failure.match?(/actual=|expected=|webhooks/) &&
                webhook_summary && webhook_summary["no_log"] == true &&
                Array(webhook_assert&.dig("ansible.builtin.assert", "that")).all? do |condition|
                  !condition.match?(/notification|webhook.*url|webhooks/)
                end,
      "Beszel webhook mismatch diagnostics must never include URL bodies")
wrong_owner_assert = beszel_tasks.find do |task|
  task["name"] == "Refuse same-name systems outside the managed user relation"
end
check(failures, wrong_owner_assert && wrong_owner_assert.dig("ansible.builtin.assert", "that").to_s.include?("beszel_wrong_owner_systems"),
      "Beszel must reject same-name systems outside the managed user relation")
check(failures, beszel_contract.include?("URI.encode_www_form") &&
                beszel_contract.include?("same-name wrong-owner system IDs") &&
                !beszel_contract.include?("skipTotal=1"),
      "Beszel contract must use complete encoded identity filters and enforce system ownership")
%w[sentinel-user sentinel-password sentinel-query-key].each do |sentinel|
  check(failures, harness.include?(sentinel),
        "integration must test redaction of arbitrary webhook sentinel #{sentinel}")
end

# PocketBase validates relations through a separate SQLite connection. Refresh
# that pool exactly once after the one-time user insert and before relation writes.
beszel_create_index = beszel_tasks.index do |task|
  task["name"] == "Create the application user"
end
beszel_refresh_indexes = beszel_tasks.each_index.select do |index|
  beszel_tasks[index]["name"] ==
    "Refresh Beszel database connections after creating the application user"
end
beszel_second_list_index = beszel_tasks.index do |task|
  task["name"] == "List application users again to resolve the id"
end
check(failures, beszel_refresh_indexes.length == 1,
      "Beszel must refresh database connections exactly once after creating its user")
unless beszel_refresh_indexes.empty?
  refresh_index = beszel_refresh_indexes.first
  refresh = beszel_tasks[refresh_index]
  compose = refresh["community.docker.docker_compose_v2"]
  check(failures, beszel_create_index && beszel_second_list_index &&
                  beszel_create_index < refresh_index && refresh_index < beszel_second_list_index,
        "Beszel database refresh must follow user creation and precede relation setup")
  check(failures, compose.is_a?(Hash) && compose["services"] == ["hub"] &&
                  compose["state"] == "restarted" && compose["wait"] == true,
        "Beszel database refresh must restart and wait for only the hub")
  check(failures, refresh["when"] == "beszel_matching_users | length == 0",
        "Beszel database refresh must run only when the application user is created")
end

# The Mac proof harness is an orchestration contract: later service tranches
# plug their fixture, drift, and verification behavior into these stable phases.
mac_harness_files = %w[
  lib.sh run.sh cleanup.sh fixtures.sh verify.sh drift.sh report.rb
  sanitize-logs.rb manual-review.md manual-validation-handoff.rb
]
mac_harness_files.each do |name|
  check(failures, File.file?(File.join(ROOT, "tests", "mac", name)),
        "Mac proof harness must provide tests/mac/#{name}")
end

mac_run_path = File.join(ROOT, "tests", "mac", "run.sh")
mac_run = File.file?(mac_run_path) ? File.read(mac_run_path) : ""
mac_phases = %w[
  preflight deploy seed verify idempotence drift reconcile recreate persistence
  report cleanup
]
mac_phases.each do |phase|
  check(failures, mac_run.match?(/(?:^|[[:space:]])#{Regexp.escape(phase)}(?:$|[[:space:]])/),
        "Mac proof harness must support the #{phase} phase")
end
%w[--lane --vault-file --vault-password-file --keep-on-failure --manual-validation --phase].each do |option|
  check(failures, mac_run.include?(option), "Mac proof harness must accept #{option}")
end

manual_handoff_path = File.join(ROOT, "tests", "mac", "manual-validation-handoff.rb")
manual_handoff = File.file?(manual_handoff_path) ? File.read(manual_handoff_path) : ""
check(failures, manual_handoff.include?('YAML.safe_load($stdin.read, aliases: false)') &&
                manual_handoff.include?("read_deployed_manifest") &&
                manual_handoff.include?('File.join(deployment_root, "current", "manifest.yml")') &&
                manual_handoff.include?('File::RDONLY | File::NOFOLLOW') &&
                manual_handoff.include?('File.realpath(current) == release_root') &&
                manual_handoff.include?('services = service_entries.map') &&
                manual_handoff.include?('services.sort == PORT_FIELDS.keys.sort') &&
                manual_handoff.include?("Shellwords.shellescape") &&
                manual_handoff.include?("Passwords remain in the encrypted vault source."),
      "Mac manual-validation handoff must derive safe identities and services from the immutable deployment")
check(failures, mac_run.include?('if [ "$manual_validation" = true ] && [ "$phase" = verify ]') &&
                mac_run.include?('preserve_sandbox_on_exit=true') &&
                mac_run.include?("emit_manual_validation_handoff || exit $?") &&
                mac_run.include?('> "$manual_vault_plaintext" 2>/dev/null || vault_view_status=$?') &&
                mac_run.include?('< "$manual_vault_plaintext" || handoff_status=$?') &&
                mac_run.include?("remove_manual_vault_plaintext"),
      "Mac manual validation must stop through the preserved-sandbox EXIT trap after verify")

mac_cleanup_path = File.join(ROOT, "tests", "mac", "cleanup.sh")
mac_cleanup = File.file?(mac_cleanup_path) ? File.read(mac_cleanup_path) : ""
mac_lib_path = File.join(ROOT, "tests", "mac", "lib.sh")
mac_lib = File.file?(mac_lib_path) ? File.read(mac_lib_path) : ""
check(failures, (mac_cleanup + mac_lib).include?("refusing to remove unowned Mac sandbox"),
      "Mac cleanup must refuse a sandbox outside its validated prefix")

verify_play_path = File.join(ROOT, "verify.yml")
check(failures, File.file?(verify_play_path), "Mac proof harness must provide verify.yml")
verify_play = File.file?(verify_play_path) ? File.read(verify_play_path) : ""
verify_play_data = File.file?(verify_play_path) ? YAML.safe_load_file(verify_play_path).first : {}
verification_roles = Array(verify_play_data["roles"])
mac_verify_path = File.join(ROOT, "tests", "mac", "verify.sh")
mac_verify = File.file?(mac_verify_path) ? File.read(mac_verify_path) : ""
check(failures, mac_verify.include?('"$mac_repo_dir/verify.yml"') &&
                !mac_verify.include?('"$mac_repo_dir/site.yml"') &&
                !verify_play.include?("community.docker.docker_compose_v2") &&
                !verify_play.include?("role: deployment_bundle") &&
                !verify_play.include?("role: host_prep"),
      "Mac verification must not deploy or converge services")
check(failures, verification_roles.any? && verification_roles.all? do |role|
                  role.is_a?(Hash) && Array(role["tags"]).include?("never")
                end,
      "verify.yml roles must be inert unless an explicit verification tag is selected")
execute_phase_offset = mac_run.index("execute_phase()")
execute_phase_source = execute_phase_offset ? mac_run[execute_phase_offset..] : ""
cutover_phase = execute_phase_source[/cutover\)\n(.*?)\n\s*;;/m, 1].to_s
snapshot_validation = cutover_phase.index("enable_adoption_mapping")
target_deployment = cutover_phase.index("run_site")
adoption_verification = cutover_phase.index('"$mac_script_dir/verify.sh"')
check(failures, mac_run.scan('"$mac_script_dir/verify.sh"').length >= 3 &&
                [snapshot_validation, target_deployment, adoption_verification].all? &&
                snapshot_validation < target_deployment &&
                target_deployment < adoption_verification,
      "Mac lifecycle must verify after seed, drift reconciliation, recreation, and adoption")
check(failures, mac_run.include?("resume vault checksum does not match") &&
                mac_run.include?("resume Git revision does not match"),
      "Mac lifecycle must refuse mixed vault or Git evidence when resuming")
run_exit_handler = mac_run[/on_run_exit\(\) \{.*?^\}/m].to_s
check(failures, run_exit_handler.index("release_run_lock") &&
                run_exit_handler.index("Cleanup command:") &&
                run_exit_handler.index("release_run_lock") <
                  run_exit_handler.index("Cleanup command:"),
      "Mac lifecycle must include lock-release failures in cleanup-command reporting")
check(failures, mac_lib.include?("No Mac hooks registered for") &&
                !mac_lib.include?("No %s hooks are registered yet."),
      "Mac lifecycle must fail rather than pass a phase with no registered hooks")
check(failures, mac_run.include?('mktemp -d "$temporary_parent/nas-platform-mac.XXXXXX"') &&
                mac_run.include?('acquire_integration_lock "$temporary_parent"') &&
                mac_run.include?('report_root=$sandbox.reports') &&
                mac_run.include?(".nas-platform-mac-report-owned"),
      "Mac lifecycle must use a locked unique sandbox with reports outside service data")
%w[
  PLATFORM_MAC_SANDBOX PLATFORM_DOCKER_ROOT PLATFORM_MEDIA_ROOT
  PLATFORM_FIXTURE_ROOT PLATFORM_REPORT_ROOT PLATFORM_PROOF_LANE
  PLATFORM_PROJECT_NAME PLATFORM_BESZEL_PORT PLATFORM_NTFY_PORT PLATFORM_DOZZLE_PORT
  PLATFORM_AUDIOBOOKSHELF_PORT
  PLATFORM_PAPERLESS_PORT
  COMPOSE_PROJECT_NAME
].each do |variable|
  check(failures, mac_run.include?("export #{variable}="),
        "Mac lifecycle must export #{variable}")
end
check(failures, mac_cleanup.include?('. "$mac_repo_dir/tests/sandbox_cleanup.sh"') &&
                mac_cleanup.include?('. "$mac_repo_dir/tests/integration_lock.sh"') &&
                mac_cleanup.include?('acquire_integration_lock "$mac_cleanup_parent"') &&
                mac_cleanup.include?("release_integration_lock") &&
                mac_cleanup.include?("cleanup_sandbox_contents") &&
                (mac_cleanup + mac_lib).include?(".nas-platform-mac-owned") &&
                !(mac_cleanup + mac_lib).match?(/rm\s+-rf/),
      "Mac cleanup must reuse descriptor-safe cleanup with an owned marker")
integration_cleanup = File.read(File.join(ROOT, "tests", "sandbox_cleanup.sh"))
check(failures, integration_cleanup.include?("beszel_agent_portable"),
      "integration cleanup must remove the portable Beszel agent")
check(failures, integration_cleanup.include?("audiobookshelf"),
      "integration cleanup must remove Audiobookshelf")
check(failures, mac_run.include?('cleanup) release_run_lock && "$mac_script_dir/cleanup.sh" "$sandbox"') &&
                mac_run.scan("Cleanup command:").length == 1,
      "Mac runner must transfer the shared lock and emit cleanup commands once")
check(failures, mac_cleanup.include?('cleanup_sandbox_contents "$(dirname -- "$mac_cleanup_target")"') &&
                mac_cleanup.include?('".nas-platform-mac-owned"') &&
                !mac_cleanup.include?('rmdir -- "$mac_cleanup_target"'),
      "Mac cleanup must preserve its marker through descriptor-safe final removal")
check(failures, mac_run.include?('diagnostic_temporary=$(mktemp') &&
                mac_run.include?('mv -f -- "$diagnostic_temporary" "$report_root/$diagnostic_name" || {') &&
                mac_run.include?('unlink "$diagnostic_temporary" >/dev/null 2>&1 || true'),
      "Mac diagnostics must replace prior evidence only after successful capture")
mac_log_sanitizer_path = File.join(ROOT, "tests", "mac", "sanitize-logs.rb")
mac_log_sanitizer = if File.file?(mac_log_sanitizer_path)
                      File.read(mac_log_sanitizer_path)
                    else
                      ""
                    end
check(failures, mac_run.include?('"$mac_script_dir/sanitize-logs.rb"') &&
                mac_log_sanitizer.include?("[REDACTED]") &&
                mac_log_sanitizer.include?("--timestamps") &&
                mac_log_sanitizer.include?("docker_error"),
      "Mac failure diagnostics must capture only structurally redacted container logs")
mac_sanitizer_result = if File.file?(mac_log_sanitizer_path)
                         Open3.capture3(RbConfig.ruby, mac_log_sanitizer_path, "--self-test")
                       end
check(failures, mac_sanitizer_result && mac_sanitizer_result[2].success? &&
                mac_sanitizer_result[0] == "log sanitizer: all secrecy properties hold\n" &&
                mac_sanitizer_result[1].empty?,
      "Mac log sanitizer self-test must pass without raw values")
check(failures, mac_run.include?('IFS= read -r vault_header < "$vault_file"') &&
                !mac_run.include?("grep -q '^\\$ANSIBLE_VAULT;'"),
      "Mac lifecycle must require the Ansible Vault header on the first line")

mac_report_path = File.join(ROOT, "tests", "mac", "report.rb")
mac_report = File.file?(mac_report_path) ? File.read(mac_report_path) : ""
%w[password secret token authorization private_key hash].each do |forbidden_key|
  check(failures, mac_report.downcase.include?(forbidden_key),
        "Mac report must redact #{forbidden_key} keys")
end
check(failures, mac_report.include?("when Hash") && mac_report.include?("when Array") &&
                mac_report.include?("JSON.pretty_generate") &&
                mac_report.include?("markdown_report") &&
                mac_report.include?("deployment_manifest") &&
                mac_report.include?("diagnostic_locations"),
      "Mac reporter must recursively sanitize structured input into JSON and Markdown")

readme = File.read(File.join(ROOT, "README.md"))
gitignore = File.read(File.join(ROOT, ".gitignore"))
check(failures, readme.include?("tests/mac/run.sh") &&
                readme.include?("--lane fresh") && readme.include?("--lane adoption") &&
                readme.include?("--keep-on-failure"),
      "README must document both Mac proof lanes and failure preservation")
check(failures, gitignore.include?("mac-proof-reports"),
      "gitignore must exclude local Mac proof report copies")

beszel_verification_prerequisites = {
  "Select the Beszel mounted state root" => "ansible.builtin.set_fact",
  "Authenticate as the superuser" => "ansible.builtin.uri",
  "Read the public key the hub advertises" => "ansible.builtin.uri",
  "Verify the advertised key matches vault, proving no read-back is needed" =>
    "ansible.builtin.assert"
}
beszel_verification_prerequisites.each do |name, module_name|
  task = beszel_tasks.find { |candidate| candidate["name"] == name }
  check(failures, task && task.key?(module_name) &&
                  Array(task["tags"]).include?("platform_verify_beszel"),
        "Beszel verification-only run must include #{name.downcase}")
end

tinymediamanager_tasks = flatten_tasks(
  YAML.safe_load_file(File.join(ROOT, "roles", "tinymediamanager", "tasks", "main.yml"))
)
tinymediamanager_state_root = tinymediamanager_tasks.find do |task|
  task["name"] == "Select the tinyMediaManager mounted state root"
end
check(failures,
      tinymediamanager_state_root&.key?("ansible.builtin.set_fact") &&
        Array(tinymediamanager_state_root["tags"]).include?("platform_verify_tinymediamanager"),
      "tinyMediaManager verification-only run must derive its mounted state root")

if failures.empty?
  puts "policy: all properties hold"
else
  failures.each { |f| warn "FAIL #{f}" }
  abort "#{failures.length} policy violation(s)"
end
