#!/usr/bin/env ruby
# Property-based policy checks.
#
# Most checks deliberately assert properties rather than per-service values.
# The source-platform inventory is the exception: pinning that finite set keeps
# an omitted service from silently disappearing from the platform scope.

require "find"
require "open3"
require "rbconfig"
require "set"
require "yaml"
require_relative "policy_support"

include PolicySupport

ROOT = File.expand_path("..", __dir__)
failures = []
ACQUISITION_JOB_SERVICES = Set["configarr"].freeze

def check(failures, condition, message)
  failures << message unless condition
end

def task_list_document?(tasks)
  tasks.is_a?(Array) && tasks.all? do |task|
    task.is_a?(Hash) && %w[block rescue always].all? do |section|
      !task.key?(section) || task_list_document?(task[section])
    end
  end
end

def recursive_role_yaml_paths(tree_root, failures)
  begin
    root_stat = File.lstat(tree_root)
  rescue Errno::ENOENT
    return []
  rescue SystemCallError => e
    check(failures, false, "#{tree_root}: cannot inspect role YAML tree: #{e.class}")
    return []
  end
  unless root_stat.directory? && !root_stat.symlink? &&
         owned_directory?(tree_root, File.dirname(tree_root))
    check(failures, false, "#{tree_root}: role YAML tree must be a regular owned directory")
    return []
  end

  paths = []
  begin
    Find.find(tree_root) do |path|
      next if path == tree_root

      relative_path = path.delete_prefix("#{ROOT}/")
      entry_stat = File.lstat(path)
      if entry_stat.symlink?
        check(failures, false, "#{relative_path}: role YAML tree must not contain symlinks")
        Find.prune
      elsif entry_stat.directory?
        unless owned_directory?(path, File.dirname(path))
          check(failures, false, "#{relative_path}: role YAML directory must be owned")
          Find.prune
        end
      elsif %w[.yml .yaml].include?(File.extname(path))
        if entry_stat.file? && owned_file?(path, tree_root)
          paths << path
        else
          check(failures, false, "#{relative_path}: role YAML file must be a regular owned file")
        end
      end
    end
  rescue SystemCallError => e
    check(failures, false, "#{tree_root}: cannot enumerate role YAML tree: #{e.class}")
  end
  paths.sort
end

def load_role_tasks(role_root, failures)
  tasks_root = File.join(role_root, "tasks")
  recursive_role_yaml_paths(tasks_root, failures).flat_map do |path|
    relative_path = path.delete_prefix("#{ROOT}/")
    begin
      parsed = YAML.safe_load_file(path, aliases: true)
    rescue Psych::Exception => e
      check(failures, false,
            "#{relative_path}: role task file is malformed: #{e.message.lines.first.strip}")
      next []
    end
    unless task_list_document?(parsed)
      check(failures, false, "#{relative_path}: role task file must contain an array of task mappings")
      next []
    end

    flatten_tasks(parsed)
  end
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

policy_runner = File.read(File.join(ROOT, "tests", "validate-policy.sh"))
retired_token = %w[tiny media manager].join
active_prefixes = %w[
  .github/workflows/
  config/
  filter_plugins/
  inventory/
  roles/
  services/
  templates/
  tests/
  scripts/
].freeze
active_root_files = %w[
  README.md
  site.yml
  verify.yml
  generate-secrets.yml
  validate-vault.yml
].freeze
clean_git_environment = ENV.each_key.grep(/\AGIT_/).to_h { |name| [name, nil] }
tracked_and_untracked, enumeration_error, enumeration_status = Open3.capture3(
  clean_git_environment,
  "git", "-C", ROOT, "ls-files", "--cached", "--others", "--exclude-standard", "-z"
)
check(failures, enumeration_status.success?,
      "could not enumerate active policy sources: #{enumeration_error.lines.first&.strip}")
active_sources = if enumeration_status.success?
                   tracked_and_untracked.split("\0").select do |path|
                     active_prefixes.any? { |prefix| path.start_with?(prefix) } ||
                       active_root_files.include?(path) ||
                       (path.start_with?("docs/") &&
                        !path.start_with?("docs/superpowers/") &&
                        File.extname(path) == ".md")
                   end
                 else
                   []
                 end
active_sources.delete("inventory/group_vars/all/vault.yml")

retired_migration_sources = %w[
  scripts/migrate-media-acquisition-vault.py
  tests/media_acquisition_vault_migration_test.py
].freeze
check(failures, retired_migration_sources.none? { |path| File.exist?(File.join(ROOT, path)) },
      "the temporary encrypted-vault migration audit is incomplete")

active_sources.sort.each do |relative_path|
  components = relative_path.split("/")
  unless !components.empty? && components.none? { |component| component.empty? || %w[. ..].include?(component) }
    check(failures, false, "#{relative_path}: active source path is unsafe")
    next
  end

  current = ROOT
  valid_source = components.each_with_index.all? do |component, index|
    current = File.join(current, component)
    begin
      stat = File.lstat(current)
    rescue SystemCallError => e
      check(failures, false, "#{relative_path}: cannot inspect active source: #{e.class}")
      break false
    end

    if index == components.length - 1
      regular = stat.file? && !stat.symlink?
      check(failures, regular, "#{relative_path}: active source must be a regular file")
      regular
    else
      safe_ancestor = stat.directory? && !stat.symlink?
      check(failures, safe_ancestor,
            "#{relative_path}: active source path must not contain symlinks")
      safe_ancestor
    end
  end
  next unless valid_source
  path = File.join(ROOT, relative_path)

  begin
    contains_retired_token = File.binread(path).downcase.include?(retired_token)
  rescue SystemCallError => e
    check(failures, false, "#{relative_path}: cannot read active source: #{e.class}")
    next
  end
  check(failures, !contains_retired_token, "retired declaration remains: #{relative_path}")
end

retired_role = File.join(ROOT, "roles", retired_token)
retired_service = File.join(ROOT, "services", retired_token)
check(failures, !File.exist?(retired_role) && !File.symlink?(retired_role),
      "retired role directory must be absent")
check(failures, !File.exist?(retired_service) && !File.symlink?(retired_service),
      "retired service directory must be absent")

beszel_contract_path = File.join(ROOT, "tests", "contracts", "beszel.sh")
beszel_contract = File.file?(beszel_contract_path) ? File.read(beszel_contract_path) : ""
check(failures,
      beszel_contract.include?('since: baseline_id') &&
        beszel_contract.include?('message["id"] != baseline_id') &&
        !beszel_contract.include?("iso8601"),
      "Beszel notification proof must poll after a captured ntfy message ID")

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
dozzle_task_names = if File.file?(dozzle_tasks_path)
                      flatten_tasks(YAML.safe_load_file(dozzle_tasks_path, aliases: true))
                        .filter_map { |task| task["name"] }
                    else
                      []
                    end
dozzle_planned_tasks = [
  "Report planned managed Dozzle dispatcher creation",
  "Report planned managed Dozzle dispatcher repair",
  "Report planned managed Dozzle alert rule creation",
  "Report planned managed Dozzle alert rule repair",
  "Report planned managed Dozzle alert rule enabled-state repair",
  "Report planned unmanaged Dozzle alert rule removal",
  "Report planned unmanaged Dozzle dispatcher removal"
]
check(failures, dozzle_planned_tasks.all? { |name| dozzle_task_names.include?(name) },
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

PLATFORM_INVENTORIES = {
  "local.yml" => ["nas_hosts", "nas", "local", "nas"],
  "remote.yml" => ["nas_hosts", "nas", "ssh", "nas"],
  "mac.yml" => ["mac_hosts", "mac", "local", "mac"]
}.freeze
PLATFORM_CAPABILITIES = %w[
  platform_container_cpu_budget
  platform_render_device_available platform_render_device_path
  platform_beszel_agent_available platform_beszel_agent_kind
].freeze
PLATFORM_TELEMETRY_POLICY = %w[
  beszel_required_telemetry_categories beszel_require_gpu_telemetry
].freeze
HOST_SCOPED_VARS = (
  %w[platform_kind nas_docker_root nas_media_root media_usenet_enabled media_torrent_enabled] + PLATFORM_CAPABILITIES +
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
  # The transport coordinate and the client-facing coordinate are different
  # audiences. ntfy hashes platform_public_host into the topic it registers with
  # its upstream push server, so a value inherited from the SSH address routes
  # notifications to a topic no device subscribes to, with nothing to observe:
  # deployment succeeds, the server is healthy, and no notification arrives.
  # The endpoint guard above can only see emptiness, and an inherited value is
  # not empty, which is how a coordinate can be non-empty without being chosen.
  # So the audience split is enforced on the expression itself: this coordinate
  # is stated, never derived, and no fallback may reintroduce a second audience.
  public_host_source = host.is_a?(Hash) ? host["platform_public_host"].to_s : ""
  borrowed = ["PLATFORM_NAS_ADDRESS", "ansible_host", "default("].find do |fragment|
    public_host_source.include?(fragment)
  end
  check(failures, borrowed.nil?,
        "inventory/#{inventory_name} platform_public_host must be stated " \
        "explicitly, not derived from another coordinate (found #{borrowed.inspect})")
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

# Filter plugins cannot import module_utils/ by name. Reaching it by putting the
# repository root on sys.path would shadow site-packages with library/,
# module_utils/, roles/, services/ and tests/ for the whole Ansible process, so
# shared code has to be loaded by path instead.
sys_path_probe = <<~PYTHON
  import importlib.util
  import sys
  from pathlib import Path

  root = Path(sys.argv[1]).resolve()
  for plugin in sorted((root / "filter_plugins").glob("*.py")):
      spec = importlib.util.spec_from_file_location(f"probe_{plugin.stem}", plugin)
      module = importlib.util.module_from_spec(spec)
      try:
          spec.loader.exec_module(module)
      except Exception:
          pass
      if str(root) in sys.path:
          raise SystemExit(f"{plugin.name} put the repository root on sys.path")
PYTHON
_sys_path_stdout, sys_path_stderr, sys_path_status = Open3.capture3(
  "python3", "-c", sys_path_probe, ROOT
)
check(failures, sys_path_status.success?,
      "filter plugins must reach shared code without mutating sys.path: #{sys_path_stderr.strip}")

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
shared_vars = YAML.safe_load_file(File.join(ROOT, "inventory", "group_vars", "all", "main.yml"))
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
  manifest_source = File.read(manifest_path)
  manifest_stream = Psych.parse_stream(manifest_source)
  check(failures, manifest_stream.children.length == 1,
        "service manifest must contain exactly one YAML document")
  duplicate_yaml_keys(manifest_stream).uniq.each do |key|
    check(failures, false, "service manifest contains duplicate mapping key #{key}")
  end
  YAML.safe_load(manifest_source)
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

check(failures, !manifest.key?("legacy_source"),
      "service manifest must not reintroduce a legacy migration source") if manifest_loaded

manifest_entries = manifest["services"]
unless manifest_entries.is_a?(Array)
  check(failures, false, "service manifest must contain a services list") if manifest_loaded
  manifest_entries = []
end

acquisition_catalog = begin
  YAML.safe_load_file(File.join(ROOT, "config", "media-acquisition.yml"), aliases: false)
rescue Errno::ENOENT
  check(failures, false, "media acquisition catalog is missing")
  {}
rescue Psych::Exception => e
  check(failures, false,
        "media acquisition catalog is malformed: #{e.message.lines.first.strip}")
  {}
end
acquisition_projects = if acquisition_catalog.is_a?(Hash) &&
                          acquisition_catalog["projects"].is_a?(Hash)
                         acquisition_catalog["projects"]
                       else
                         {}
                       end
parsed_acquisition_jobs = acquisition_projects.values.flat_map do |project|
  services = project.is_a?(Hash) && project["services"].is_a?(Hash) ? project["services"] : {}
  services.filter_map do |service_name, definition|
    service_name if definition.is_a?(Hash) && definition["class"] == "one_shot"
  end
end.to_set
check(failures, parsed_acquisition_jobs == ACQUISITION_JOB_SERVICES,
      "Configarr must be the sole one-shot acquisition service")

service_statuses = if manifest["services"].is_a?(Array) && manifest_entries.all? do |entry|
                        entry.is_a?(Hash) && entry.key?("name") && entry.key?("status")
                      end
                     manifest.fetch("services").to_h do |entry|
                       [entry.fetch("name"), entry.fetch("status")]
                     end
                   else
                     {}
                   end

# The roster and pinned expectations are loaded only after the strict manifest
# parse, so status-dependent contracts cannot consult a divergent second copy.
SERVICE_EXPECTATIONS, expectation_problems =
  pinned_service_expectations(ROOT, service_statuses)
expectation_problems.each { |problem| check(failures, false, problem) }
EXPECTED_SERVICE_MAPPINGS =
  SERVICE_EXPECTATIONS.transform_values { |expectation| { "role" => expectation.fetch("role") } }.freeze
EXPECTED_CONTAINER_CPUS =
  SERVICE_EXPECTATIONS.transform_values { |expectation| expectation.fetch("container_cpus") }.freeze
EXPECTED_VAULT_KEYS = pinned_vault_keys(SERVICE_EXPECTATIONS)

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
  check(failures, ALLOWED_SERVICE_STATUSES.include?(service["status"]),
        "#{service['name'] || '<unnamed>'}: status must be planned, implemented, or accepted")

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

# The service roster is restated in two independent artifacts: services/manifest.yml
# declares what gets deployed, and config/managed-user-capabilities.yml declares the
# managed-user contract each service honours. Both are pinned, but until now each was
# pinned only against its own test's hardcoded list, so a service could be added to the
# manifest and this roster while never gaining a capability contract: this file would
# pass because the manifest matched, and managed_user_capabilities_test.rb would pass
# because the matrix still matched its own untouched list. Drift between the two is only
# visible from a check that reads both, so the matrix is pinned to the roster here.
capabilities_path = File.join(ROOT, "config", "managed-user-capabilities.yml")
capabilities = begin
  YAML.safe_load_file(capabilities_path)
rescue Errno::ENOENT
  check(failures, false, "managed-user capability matrix is missing: config/managed-user-capabilities.yml")
  {}
rescue Psych::Exception => e
  check(failures, false,
        "managed-user capability matrix is malformed: #{e.message.lines.first.strip}")
  {}
end
capability_names = capabilities.is_a?(Hash) && capabilities["services"].is_a?(Hash) ? capabilities["services"].keys : []
managed_user_service_names = service_statuses.filter_map do |name, status|
  name if name.is_a?(String) && IMPLEMENTED_STATUSES.include?(status)
end
check(failures, capabilities.is_a?(Hash) && capabilities["services"].is_a?(Hash),
      "managed-user capability matrix must contain a services mapping")
check(failures, capability_names.sort == managed_user_service_names.sort,
      "managed-user capability matrix must cover the complete source platform " \
      "(missing: #{(managed_user_service_names - capability_names).join(', ')}; " \
      "unknown: #{(capability_names - managed_user_service_names).join(', ')})")

%w[ntfy beszel].each do |name|
  entry = manifest_entries.find { |service| service.is_a?(Hash) && service["name"] == name }
  check(failures, entry && IMPLEMENTED_STATUSES.include?(entry["status"]),
        "#{name}: status must be implemented or accepted")
end

%w[name role].each do |field|
  values = manifest_entries.filter_map { |service| service[field] if service.is_a?(Hash) }
  duplicates = values.tally.select { |_value, count| count > 1 }.keys
  check(failures, duplicates.empty?,
        "service manifest #{field} values must be unique: #{duplicates.join(', ')}")
end

service_dir_names = service_dirs.map { |dir| File.basename(dir) }
undeclared_dirs = service_dir_names - manifest_names
check(failures, undeclared_dirs.empty?,
      "service directories must be declared in the manifest: #{undeclared_dirs.join(', ')}")

# Digest pinning with a human-readable version tag, so an update bot can propose
# a bump and a reader can tell what is deployed. The approved version is whatever
# compose.yml declares; pinning a copy of it here would mean every image update
# had to edit this file too, which is what a property check exists to avoid.
IMAGE = %r{\A\S+:[^@\s]+@sha256:[0-9a-f]{64}\z}

declared_paths = YAML.safe_load_file(File.join(ROOT, "inventory", "group_vars", "all", "main.yml"))
                     .fetch("nas_storage").map { |entry| entry.fetch("path") }

# A mounted path is accounted for when nas_storage declares it, or declares an
# entry it sits under: host_prep creates that entry with the right ownership and
# recovery class, and anything beneath it comes into existence with it. This is
# the relation the Compose volume check has always applied, stated once here now
# that a second caller needs it.
storage_declared = lambda do |path|
  declared_paths.include?(path) ||
    declared_paths.any? { |declared| path.start_with?("#{declared}/") }
end

service_dirs.each do |dir|
  name = File.basename(dir)
  compose_path = File.join(dir, "compose.yml")
  check(failures, File.file?(compose_path), "#{name}: missing compose.yml")
  next unless File.file?(compose_path)

  compose = YAML.safe_load_file(compose_path, aliases: true)
  containers = compose.fetch("services")
  expected_cpus = EXPECTED_CONTAINER_CPUS.fetch(name)
  acquisition_services = acquisition_projects.dig(name, "services")
  expected_compose_services = if acquisition_services.is_a?(Hash)
                                acquisition_services.filter_map do |service_name, definition|
                                  service_name if !definition.is_a?(Hash) ||
                                                  !definition.key?("compose_profile") ||
                                                  ACQUISITION_JOB_SERVICES.include?(service_name)
                                end
                              else
                                expected_cpus.keys
                              end
  check(failures, containers.keys.sort == expected_compose_services.sort,
        "#{name}: CPU policy must cover the exact Compose service set")

  containers.each do |container, spec|
    label = "#{name}/#{container}"
    expected_cpu = expected_cpus[container]
    acquisition_job = ACQUISITION_JOB_SERVICES.include?(container)

    if acquisition_job
      check(failures, spec["profiles"] == ["jobs"],
            "#{label}: one-shot acquisition service must use only the jobs profile")
      check(failures, Array(spec["ports"]).empty?,
            "#{label}: one-shot acquisition service must not publish ports")
    else
      check(failures, !Array(spec["profiles"]).include?("jobs"),
            "#{label}: long-running service must not claim the jobs profile")
    end

    check(failures, spec["cpuset"] == "${PLATFORM_CONTAINER_CPUSET:?}",
          "#{label}: must require the Ansible-rendered platform CPU set")
    check(failures, !expected_cpu.nil? && spec["cpus"] == expected_cpu,
          "#{label}: CPU ceiling must match the pinned service policy")
    check(failures, !spec.key?("cpu_shares"),
          "#{label}: must retain Docker's equal default CPU shares")

    check(failures, spec["image"].to_s.match?(IMAGE),
          "#{label}: image must be digest-pinned with a version tag")
    check(failures, !spec.key?("build"),
          "#{label}: must use a published image, not build")
    check(failures, spec["privileged"] != true,
          "#{label}: privileged mode is not allowed")
    unless acquisition_job
      check(failures, spec["restart"] == "unless-stopped",
            "#{label}: long-running services must restart unless-stopped")
      check(failures, spec["healthcheck"].is_a?(Hash) && !spec["healthcheck"].empty?,
            "#{label}: long-running services must define a health check")
      labels = spec["labels"]
      dozzle_name = labels.is_a?(Hash) ? labels["dev.dozzle.name"] : nil
      check(failures, dozzle_name.is_a?(String) && !dozzle_name.empty?,
            "#{label}: long-running services must declare a Dozzle event identity")
    end

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
                         elsif source.include?("NAS_MEDIA_ROOT")
                           source.sub(/\A\$\{NAS_MEDIA_ROOT:\?\}/, "{{ nas_media_root }}")
                         elsif source == "${AUDIOBOOKSHELF_BACKUP_PATH:?}"
                           "{{ nas_docker_root }}/audiobookshelf/backups"
                         end
      next unless inventory_source

      # Service state must be declared in the storage inventory so host_prep
      # creates it with the right ownership and it gets a recovery class.
      expected = inventory_source
      check(failures, storage_declared.call(expected),
            "#{label}: #{source} is not declared in nas_storage (expected #{expected})")
    end
  end
end

# Service templates write their media library paths as literals, and Compose
# takes those rendered values straight through as bind sources. That makes the
# library path a second declaration of what nas_storage already declares, with
# nothing comparing the two: renaming one side leaves host_prep creating one
# directory while the service mounts another. Compose volume sources cannot
# reach these, because they arrive as an opaque ${SERVICE_..._PATH:?} the
# template supplies, so the templates are read directly here.
#
# Only a literal with a path suffix is a library path. Several templates export
# the volume root itself (NAS_MEDIA_ROOT, PLATFORM_MEDIA_ROOT) for a service to
# join onto, and requiring the suffix is what keeps those out of this check.
#
# A library root may also sit above the declared entries rather than at or below
# one, which is how Jellyfin mounts the whole media tree while nas_storage
# declares only the libraries below it: Ansible's file
# module creates the parent, and the leaves are where a mode and a recovery
# class belong. Demanding an exact entry would reject that legitimate parent
# mount. Accepting it is confined to these templates on purpose, because letting
# a Compose volume source name an ancestor would let a container see a whole
# service state tree where the declared entry gave it one subdirectory.
MEDIA_ROOT_LITERAL = %r{\{\{\s*nas_media_root\s*\}\}(/[A-Za-z0-9._/-]+)}
Dir[File.join(ROOT, "roles", "*", "templates", "*.j2")].sort.each do |template_path|
  relative_template = template_path.delete_prefix("#{ROOT}/")
  File.read(template_path).scan(MEDIA_ROOT_LITERAL).each do |(suffix)|
    expected = "{{ nas_media_root }}#{suffix}"
    covered = storage_declared.call(expected) ||
              declared_paths.any? { |declared| declared.start_with?("#{expected}/") }
    check(failures, covered,
          "#{relative_template}: #{expected} is not declared in nas_storage")
  end
end

# Platform Compose files may add capabilities (devices, mounts, profiles, and
# similar host-specific wiring). An override may restate an image only so that
# platform keys sit beside it, never to deploy something different. The
# relationship is the invariant, so the canonical file stays the only place a
# version is written and a nil canonical value fails the same way a mismatch does.
Dir[File.join(ROOT, "services", "*", "compose.{mac,integration}.yml")].sort.each do |override_path|
  relative_override = override_path.delete_prefix("#{ROOT}/")
  canonical_path = File.join(File.dirname(override_path), "compose.yml")
  canonical = File.file?(canonical_path) ? YAML.safe_load_file(canonical_path, aliases: true) : {}
  override = YAML.safe_load_file(override_path, aliases: true)
  override.fetch("services", {}).each do |container, spec|
    next unless spec.is_a?(Hash) && spec.key?("image")

    check(failures, spec.fetch("image") == canonical.dig("services", container, "image"),
          "#{relative_override}/#{container}: platform image overrides differ from the canonical compose.yml image")
  end
end

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
#
# Read from the parsed tasks. The 120-character window this used to scan was
# neither a task nor a whole one: a shell-out that named the module further down
# its own arguments slipped past, and a comment naming Compose next to any
# command task was reported as a violation that did not exist.
shell_modules = %w[
  ansible.builtin.command ansible.builtin.shell command shell raw
].freeze
role_task_files = Dir[File.join(ROOT, "roles", "*")].sort.flat_map do |role_root|
  %w[tasks handlers].flat_map do |tree|
    recursive_role_yaml_paths(File.join(role_root, tree), failures)
  end
end
deploys_through_module = false
role_task_files.each do |path|
  tasks = flatten_tasks(YAML.safe_load_file(path, aliases: true))
  deploys_through_module ||= tasks.any? { |task| task.key?("community.docker.docker_compose_v2") }
  shells_out = tasks.any? do |task|
    shell_modules.any? do |module_name|
      task.key?(module_name) &&
        task_strings(task[module_name]).any? { |value| value.match?(/docker[[:space:]]+compose/) }
    end
  end
  check(failures, !shells_out,
        "#{path}: shells out to Compose; use community.docker.docker_compose_v2")
end
check(failures, deploys_through_module,
      "no role deploys anything through docker_compose_v2")

# Every deployed service reports its own deployment, so adding a tenth service
# cannot silently ship without one. The report is gated on the Compose result,
# which is why each deploying task must register: an ungated report would send
# one message per service on every converge, including the ones that changed
# nothing.
deployment_reports_declared = false
Dir[File.join(ROOT, "roles", "*")].select { |p| File.directory?(p) }.each do |role|
  name = File.basename(role)
  tasks = load_role_tasks(role, failures)
  deployments = tasks.select do |task|
    compose = task["community.docker.docker_compose_v2"]
    next false unless compose.is_a?(Hash)

    compose["state"] == "present"
  end
  next if deployments.empty?

  registers = deployments.map { |task| task["register"] }
  check(failures, registers.all? { |register| register.is_a?(String) },
        "role #{name}: every Compose deployment must register its result for the deployment report")

  reports = tasks.select do |task|
    task.dig("ansible.builtin.include_role", "tasks_from") == "deployment_report" ||
      task["ansible.builtin.include_tasks"] == "deployment_report.yml"
  end
  check(failures, reports.length == 1,
        "role #{name}: deploys Compose services but declares #{reports.length} deployment reports, not one")
  next unless reports.length == 1

  deployment_reports_declared = true

  report_vars = reports.first["vars"] || {}
  check(failures, report_vars["ntfy_deployment_report_service"].to_s.strip != "",
        "role #{name}: deployment report names no service")
  gate = report_vars["ntfy_deployment_report_changed"].to_s
  check(failures, registers.compact.all? { |register| gate.include?(register) },
        "role #{name}: deployment report ignores a registered Compose deployment")
end

# The report itself must stay a report: it publishes with the deploy publisher's
# write-only token to the deployment topic, and claims no host change.
report_path = File.join(ROOT, "roles/ntfy/tasks/deployment_report.yml")
if deployment_reports_declared
  check(failures, File.file?(report_path),
        "roles/ntfy/tasks/deployment_report.yml is missing but roles report deployments")
end
report_tasks = File.file?(report_path) ? YAML.safe_load_file(report_path, aliases: true) : []
report_task = Array(report_tasks).find { |task| task.is_a?(Hash) && task.key?("ansible.builtin.uri") }
check(failures, report_task || !deployment_reports_declared,
      "roles/ntfy/tasks/deployment_report.yml: no uri task publishes the report")
if report_task
  request = report_task.fetch("ansible.builtin.uri")
  check(failures, request["body"].is_a?(Hash) && request["body"]["topic"] == "{{ ntfy_deployment_topic }}",
        "deployment report must publish to the deployment topic")
  check(failures, request["url"].to_s.end_with?("/"),
        "deployment report must POST JSON to the ntfy root, not to a topic path")
  check(failures, request.dig("headers", "Authorization").to_s.include?("vault_ntfy_deploy_token"),
        "deployment report must publish with the deploy publisher token")
  check(failures, report_task["changed_when"] == false && report_task["no_log"] == true,
        "deployment report must claim no change and must not log its token")
  check(failures, Array(report_task["when"]).any? { |c| c.to_s.include?("not ansible_check_mode") },
        "deployment report must not publish under --check")
end

# Compose interpolation runs against the newly published bundle while the
# on-disk .env can still be the previous deployment's. Any compose invocation
# that precedes its role's env render must supply the required variables itself.
ntfy_tasks_path = File.join(ROOT, "roles/ntfy/tasks/main.yml")
ntfy_tasks = File.exist?(ntfy_tasks_path) ? YAML.safe_load_file(ntfy_tasks_path) : []
ntfy_listing = ntfy_tasks.find do |task|
  task.dig("community.docker.docker_compose_v2_run", "argv")&.include?("list")
end
# Assert the property when the task is present. Its existence is another
# check's business, and claiming it here fires on unrelated role mutations.
check(failures,
      ntfy_listing.nil? ||
        ntfy_listing.dig("environment", "PLATFORM_CONTAINER_CPUSET").to_s.include?("platform_effective_container_cpuset"),
      "the ntfy user listing must supply PLATFORM_CONTAINER_CPUSET, which its " \
      "role does not render until later")

# /System/Info/Public answers 503 while Jellyfin initializes, and the preceding
# wait polls a different endpoint that can succeed earlier.
jellyfin_tasks_path = File.join(ROOT, "roles/jellyfin/tasks/main.yml")
jellyfin_tasks = File.exist?(jellyfin_tasks_path) ? YAML.safe_load_file(jellyfin_tasks_path) : []
jellyfin_startup = jellyfin_tasks.find do |task|
  task.dig("ansible.builtin.uri", "url").to_s.include?("/System/Info/Public")
end
check(failures,
      jellyfin_startup.nil? ||
        (jellyfin_startup.key?("until") && jellyfin_startup["retries"].to_i > 0),
      "reading Jellyfin startup state must retry until the server finishes loading")

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
  env_path = File.join(role_root, "templates", "env.j2")
  env_source = File.file?(env_path) ? File.read(env_path) : ""
  check(failures,
        env_source.lines.map(&:strip).count(
          "PLATFORM_CONTAINER_CPUSET={{ platform_effective_container_cpuset }}"
        ) == 1,
        "#{name}: environment must render the effective container CPU set exactly once")
  service_tasks = role_root_owned ? load_role_tasks(role_root, failures) : []
  compose_tasks = service_tasks.select do |task|
    task["community.docker.docker_compose_v2"].is_a?(Hash)
  end
  deploys_compose = compose_tasks.any?
  # One include, carrying this service's own name. Counted from the source text
  # this was two independent substring checks that never had to describe the same
  # task: the count matched any line spelling "name: container_cpu", including a
  # commented-out one, and the service name could be supplied by anything else.
  container_cpu_includes = service_tasks.select do |task|
    %w[ansible.builtin.include_role ansible.builtin.import_role].any? do |module_name|
      task[module_name].is_a?(Hash) && task[module_name]["name"] == "container_cpu"
    end
  end
  check(failures,
        !deploys_compose ||
          (container_cpu_includes.length == 1 &&
           container_cpu_includes.fetch(0).dig("vars", "container_cpu_service_name") == name),
        "#{name}: role must verify its effective container CPU policy exactly once")
  acquisition_state_names = acquisition_projects.dig(name, "services")&.keys || []
  service_storage_declared =
    declared_paths.any? { |path| path.include?("/#{name}/") || path.end_with?("/#{name}") } ||
    acquisition_state_names.any? do |state_name|
      declared_paths.any? do |path|
        path.include?("/#{state_name}/") || path.end_with?("/#{state_name}")
      end
    end
  check(failures, service_storage_declared,
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



if failures.empty?
  puts "policy: all properties hold"
else
  failures.each { |f| warn "FAIL #{f}" }
  abort "#{failures.length} policy violation(s)"
end
