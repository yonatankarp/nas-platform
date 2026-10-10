#!/usr/bin/env ruby
# Property-based policy checks. The source-platform inventory is the exception:
# pinning that finite set keeps an omitted service from vanishing silently.

require "find"
require "open3"
require "rbconfig"
require "set"
require "yaml"
require_relative "nas_storage_support"
require_relative "policy_support"

include PolicySupport
include TestScaffold

failures = []
ACQUISITION_JOB_SERVICES = Set["configarr"].freeze

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

# The controller pin lives only in controller-requirements.in (#827); a guide
# restating the version is a mirror nothing bumps.
beginner_guides.each do |relative_path|
  guide_path = File.join(ROOT, relative_path)
  guide_source = File.file?(guide_path) ? File.read(guide_path) : ""
  check(failures, !guide_source.match?(/ansible-(?:core|lint)==\d/),
        "#{relative_path} must install the controller pins with " \
        "pip install -r controller-requirements.txt rather than restate " \
        "an ansible-core or ansible-lint version")
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
# CLAUDE.md is here because a retired declaration once survived only there (#276).
active_root_files = %w[
  CLAUDE.md
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
active_sources.reject! { |path| path.match?(%r{\Ainventory/group_vars/all/vault(?:_[a-z0-9_]+)?\.yml\z}) }

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

# The Beszel proof must require both the hub's `err: false` and a recorded POST
# carrying the test message; either alone passes a hub that sent nothing.
beszel_contract_path = File.join(ROOT, "tests", "contracts", "beszel-runtime.rb")
beszel_contract = File.file?(beszel_contract_path) ? File.read(beszel_contract_path) : ""
check(failures,
      beszel_contract.include?('generic://') &&
        beszel_contract.include?('disabletls=yes') &&
        beszel_contract.include?('This is a notification from Beszel.') &&
        beszel_contract.include?('notification["err"] == false') &&
        beszel_contract.include?('record["body"].include?') &&
        !beszel_contract.include?("baseline_id"),
      "Beszel notification proof must require a recorded POST carrying Beszel's test message, not only err: false")

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
# Port exports are derived from MAC_SERVICE_PORT_ORDER; tests/policy_mac_test.rb
# executes the derivation.
mac_lib_roster_path = File.join(ROOT, "tests", "mac", "lib.sh")
mac_lib_roster = if File.file?(mac_lib_roster_path)
                   File.read(mac_lib_roster_path)[/^MAC_SERVICE_PORT_ORDER='([^']*)'/m, 1].to_s.split
                 else
                   []
                 end
# Failure diagnostics apply the namespace prefix to tests/sandbox_cleanup.sh's
# shared roster rather than to literals, which once fell eight services behind.
mac_cleanup_registry_path = File.join(ROOT, "tests", "sandbox_cleanup.sh")
mac_cleanup_projects = if File.file?(mac_cleanup_registry_path)
                         File.read(mac_cleanup_registry_path).lines
                             .select { |line| line.start_with?("cleanup_sandbox_projects=") }
                             .flat_map do |line|
                               line.sub(/\Acleanup_sandbox_projects=/, "").delete("'\"")
                                   .sub("$cleanup_sandbox_projects", "").split
                             end
                       else
                         []
                       end
check(failures,
      mac_run.include?("export PLATFORM_PROJECT_NAME=") &&
        mac_run.match?(/^mac_export_service_ports$/) &&
        mac_run.include?('. "$mac_repo_dir/tests/sandbox_cleanup.sh"') &&
        mac_run.include?("diagnostic_project=$project_name-$diagnostic_kind") &&
        mac_run.include?('"label=com.docker.compose.project=$project_name-$diagnostic_kind"') &&
        %w[beszel dozzle audiobookshelf nextcloud].all? do |name|
          mac_lib_roster.include?(name) && mac_cleanup_projects.include?(name)
        end,
      "Mac runner must export dynamic project/port facts and isolate every Compose project")

PLATFORM_INVENTORIES = {
  "local.yml" => ["nas_hosts", "nas", "local", "nas"],
  "remote.yml" => ["nas_hosts", "nas", "ssh", "nas"],
  "mac.yml" => ["mac_hosts", "mac", "local", "mac"]
}.freeze
# Each transport coordinate reads one environment variable, and an undef() hint
# must name that same variable, or it sends the operator to export the wrong one.
TRANSPORT_COORDINATE_SOURCES = {
  "ansible_host" => "PLATFORM_NAS_ADDRESS",
  "ansible_user" => "PLATFORM_NAS_USER"
}.freeze
PLATFORM_CAPABILITIES = %w[
  platform_container_cpu_budget
  platform_render_device_available platform_render_device_path
  platform_smart_sata_devices platform_smart_nvme_namespaces
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
  # platform_public_host is the address clients are handed; inherited from the
  # SSH address it silently hands out an unreachable one. Stated, never derived.
  public_host_source = host.is_a?(Hash) ? host["platform_public_host"].to_s : ""
  borrowed = ["PLATFORM_NAS_ADDRESS", "ansible_host", "default("].find do |fragment|
    public_host_source.include?(fragment)
  end
  check(failures, borrowed.nil?,
        "inventory/#{inventory_name} platform_public_host must be stated " \
        "explicitly, not derived from another coordinate (found #{borrowed.inspect})")
  # An empty ansible_host/ansible_user silently falls back to `nas` and the local
  # login; undef() makes the unset case fail. Required present on ssh, absent on
  # local connections.
  TRANSPORT_COORDINATE_SOURCES.each do |coordinate, variable|
    coordinate_source = host.is_a?(Hash) ? host[coordinate] : nil
    if connection == "ssh"
      check(failures, coordinate_source.is_a?(String) && coordinate_source.include?("undef("),
            "inventory/#{inventory_name} must define #{coordinate} and fail on an " \
            "unset environment value with undef(), not fall back to Ansible's default")
      # The expression must read this coordinate's variable, name it in the hint,
      # and mention no other.
      hint = coordinate_source.to_s[/undef\(\s*hint\s*=\s*'([^']*)'/, 1]
      named_variables = coordinate_source.to_s.scan(/PLATFORM_[A-Z0-9_]+/).uniq
      check(failures,
            coordinate_source.to_s.match?(/lookup\(\s*'env',\s*'#{Regexp.escape(variable)}'\s*\)/) &&
              hint.to_s.include?(variable) && named_variables == [variable],
            "inventory/#{inventory_name} #{coordinate} must read #{variable} and name " \
            "that same variable in its undef() hint, so the refusal says which " \
            "variable to export (reads #{named_variables.inspect}, hint #{hint.inspect})")
    else
      check(failures, coordinate_source.nil?,
            "inventory/#{inventory_name} uses a #{connection} connection and must " \
            "not declare #{coordinate}")
    end
  end
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

# Filter plugins load module_utils by path: putting the repo root on sys.path
# would shadow site-packages for the whole Ansible process.
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

%w[beszel].each do |role_name|
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

# Handed whole to a filter or posted verbatim under no_log, so an undeclared
# shape would surface only as a redacted error; nested options make it a shape.
{
  "arr" => {
    "arr_servarr_instances" => %w[
      name api api_key admin_username admin_password root_folder category rename_field
    ],
    "arr_prowlarr_applications" => %w[
      name implementation config_contract base_url api_key sync_categories
    ]
  },
  "jellyfin" => { "jellyfin_encoding_policy" => %w[HardwareAccelerationType] }
}.each do |role_name, declarations|
  role_options = YAML.safe_load_file(
    File.join(ROOT, "roles", role_name, "meta", "argument_specs.yml")
  ).dig("argument_specs", "main", "options")
  declarations.each do |variable, required_suboptions|
    declared = role_options[variable]
    check(failures, declared.is_a?(Hash) && declared["options"].is_a?(Hash),
          "#{role_name} argument specs must declare the shape of #{variable}")
    next unless declared.is_a?(Hash) && declared["options"].is_a?(Hash)

    missing = required_suboptions - declared["options"].keys
    check(failures, missing.empty?,
          "#{role_name} #{variable} must declare the fields its filter reads: " \
          "#{missing.join(', ')}")
  end
end

jellyfin_options = YAML.safe_load_file(
  File.join(ROOT, "roles", "jellyfin", "meta", "argument_specs.yml")
).dig("argument_specs", "main", "options")
check(failures,
      jellyfin_options.dig("jellyfin_retired_plugin_repository_urls", "type") == "list" &&
      jellyfin_options.dig("jellyfin_retired_plugin_repository_urls", "elements") == "str",
      "Jellyfin argument specs must declare the retired repository URLs as a list of strings")

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
# group_vars outranks role defaults, which is what the comparison is about.
shared_vars = YAML.safe_load_file(File.join(ROOT, "inventory", "group_vars", "all", "service_immich.yml"))
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

paperless_env_assignments = environment_assignments(
  File.join(ROOT, "roles", "paperless_ngx", "templates", "env.j2")
)
[
  ["PAPERLESS_TASK_WORKERS", "{{ paperless_task_workers }}"],
  ["PAPERLESS_THREADS_PER_WORKER", "{{ paperless_threads_per_worker }}"]
].each do |name, value|
  check(failures, paperless_env_assignments.include?([name, value]),
        "Paperless environment template must contain exact line: #{name}=#{value}")
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

# `cpus` is a per-container ceiling on one shared cpuset, oversubscribed on
# purpose; the total is not a budget. A ceiling wider than the NAS set is the
# error (Docker clamps it). `<=`: a ceiling equal to the budget is deliberate.
nas_host_vars = begin
  YAML.safe_load_file(File.join(ROOT, "inventory", "group_vars", "nas_hosts", "main.yml"))
rescue Errno::ENOENT, Psych::Exception
  nil
end
container_cpu_budget = nas_host_vars.is_a?(Hash) ? nas_host_vars["platform_container_cpu_budget"] : nil
check(failures, container_cpu_budget.is_a?(Integer) && container_cpu_budget.positive?,
      "inventory/group_vars/nas_hosts/main.yml must declare a positive integer " \
      "platform_container_cpu_budget for the CPU ceilings to be measured against")
if container_cpu_budget.is_a?(Integer) && container_cpu_budget.positive?
  EXPECTED_CONTAINER_CPUS.each do |service, ceilings|
    ceilings.each do |container, ceiling|
      # A non-numeric ceiling is already reported against its own file.
      next unless ceiling.is_a?(Numeric)

      check(failures, ceiling <= container_cpu_budget,
            "#{service}/#{container}: CPU ceiling #{ceiling} exceeds the " \
            "#{container_cpu_budget}-CPU cpuset it shares -- the ceilings oversubscribe " \
            "that set on purpose, but none may be wider than it (see " \
            "platform_container_cpu_budget in inventory/group_vars/nas_hosts/main.yml)")
    end
  end
end

# config/media-acquisition.yml ships in the release, so it must stay authored and
# is related here to tests/expected/<service>.yml, by name and in both directions.
if acquisition_projects.any?
  acquisition_projects.each do |project, definition|
    pinned = EXPECTED_CONTAINER_CPUS[project]
    next unless pinned.is_a?(Hash)

    services = definition.is_a?(Hash) && definition["services"].is_a?(Hash) ? definition["services"] : {}
    check(failures, services.keys.sort == pinned.keys.sort,
          "#{project}: config/media-acquisition.yml must declare a cpus ceiling for exactly the " \
          "containers pinned in tests/expected/#{project}.yml " \
          "(catalog: #{services.keys.sort.join(', ')}; pinned: #{pinned.keys.sort.join(', ')})")

    (services.keys & pinned.keys).each do |container|
      catalog_ceiling = services.fetch(container).is_a?(Hash) ? services.fetch(container)["cpus"] : nil
      check(failures, catalog_ceiling == pinned.fetch(container),
            "#{project}/#{container}: config/media-acquisition.yml cpus " \
            "#{catalog_ceiling.inspect} must equal the #{pinned.fetch(container).inspect} pinned in " \
            "tests/expected/#{project}.yml -- a ceiling has one home and the catalog restates it")
    end
  end
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

# The manifest roster and config/managed-user-capabilities.yml must agree; only a
# check reading both can see drift between them.
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

%w[beszel].each do |name|
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

# README states the catalog size in English; derive the words from the manifest.
COUNT_WORDS = %w[
  zero one two three four five six seven eight nine ten eleven twelve thirteen
  fourteen fifteen sixteen seventeen eighteen nineteen twenty
].freeze
readme_prose = readme_source.gsub("`", "").gsub(/\s+/, " ")
{
  "implemented service project" =>
    service_statuses.count { |_name, status| IMPLEMENTED_STATUSES.include?(status) },
  "planned media-acquisition project" =>
    service_statuses.count { |_name, status| status == "planned" }
}.each do |phrase, count|
  # Singular noun for one; "no", not "zero", for none.
  word = count.zero? ? "no" : COUNT_WORDS[count]
  noun = count == 1 ? phrase : "#{phrase}s"
  check(failures, !word.nil? && readme_prose.include?("#{word} #{noun}"),
        "README must state \"#{word || count} #{noun}\" to match services/manifest.yml")
end
service_statuses.each do |name, status|
  next unless status == "planned"

  check(failures, readme_prose.match?(/(?<![[:alnum:]])#{Regexp.escape(name)}(?![[:alnum:]])/i),
        "README must name the planned project #{name}")
end

# Digest pinning with a readable tag; the approved version is whatever compose.yml
# declares, so nothing here restates it.
IMAGE = %r{\A\S+:[^@\s]+@sha256:[0-9a-f]{64}\z}

# Platform Compose fragments: anchors resolve only within one file, so each stack
# carries its own copy, pinned equal here. `extends:` was not taken: checking
# through it would mean reimplementing Compose's merge, and an undeployed shared
# file would break every stack at once.
PLATFORM_LOGGING = {
  "driver" => "json-file",
  "options" => { "max-size" => "10m", "max-file" => "3" }
}.freeze

# The tuple most timed health checks already carried; deviations override only
# the fields they change.
PLATFORM_HEALTHCHECK_DEFAULTS = {
  "interval" => "30s",
  "timeout" => "10s",
  "retries" => 5,
  "start_period" => "60s"
}.freeze

# Stacks allowed to declare no fragment. immich: its containers use their images'
# own health timing; its compose.yml records the reason.
FRAGMENT_EXEMPTIONS = {
  "x-healthcheck-defaults" => %w[immich].freeze
}.freeze

# A health check must reach the service (URL, TCP, readiness client or health
# subcommand), not observe the process table: unpackerr's `kill -0 1` could
# never fail. Stated positively because the next no-op is never on a denylist.
HEALTHCHECK_PROBE = %r{https?://|/dev/tcp/|\bping\b|isready|\bhealth(check)?\b}

# Images whose runtime sizes its own memory (a JVM takes a share of host RAM
# without a limit, #447), so a limit is what makes the heap a decision. Stated,
# not derivable from Compose; matched on the repository half of the reference.
MEMORY_SELF_SIZING_IMAGES = ["docker.io/apache/tika"].freeze

# Pinned both ways, so losing Tika cannot pass having examined nothing.
EXPECTED_SELF_SIZING_CONTAINERS = { "paperless-ngx" => ["tika"] }.freeze

# Containers bind-mounting a file from the release pointer, derived and pinned
# both ways: a refactor could silently empty this set.
EXPECTED_RELEASE_MOUNT_CONTAINERS = {
  "downloaders" => ["sabnzbd"],
  "dozzle" => ["alert-relay"],
  "kapowarr" => ["kapowarr"]
}.freeze

# ES_JAVA_OPTS is Elasticsearch's; JAVA_TOOL_OPTIONS is honoured by any JVM.
HEAP_DECLARATION_KEYS = %w[JAVA_TOOL_OPTIONS JAVA_OPTS ES_JAVA_OPTS].freeze

BYTE_SUFFIXES = { "b" => 1, "k" => 1024, "kb" => 1024, "m" => 1024**2, "mb" => 1024**2,
                  "g" => 1024**3, "gb" => 1024**3 }.freeze

# An unreadable form raises: nil would read as "no limit declared".
def parse_bytes(value, what)
  text = value.to_s.strip.downcase
  return Integer(text, 10) if text.match?(/\A\d+\z/)

  match = text.match(/\A(\d+(?:\.\d+)?)(b|kb?|mb?|gb?)\z/)
  raise ArgumentError, "#{what}: cannot read #{value.inspect} as a byte quantity" if match.nil?

  (match[1].to_f * BYTE_SUFFIXES.fetch(match[2])).round
end

# The heap requested, in bytes: -Xmx outright, or MaxRAMPercentage of the limit.
def declared_heap_bytes(environment, limit_bytes, what)
  text = HEAP_DECLARATION_KEYS.filter_map { |key| environment[key] }.join(" ")
  if (explicit = text.match(/-Xmx(\d+(?:\.\d+)?[bkmg]?)\b/i))
    return parse_bytes(explicit[1], "#{what} -Xmx")
  end
  if (share = text.match(/MaxRAMPercentage=(\d+(?:\.\d+)?)/))
    return limit_bytes.nil? ? nil : (limit_bytes * share[1].to_f / 100).round
  end

  nil
end

# Keys every long-running container shares. stop_grace_period is deliberately
# absent: the platform uses several windows on purpose.
PLATFORM_SERVICE_DEFAULTS = {
  "cpuset" => "${PLATFORM_CONTAINER_CPUSET:?}",
  "security_opt" => ["no-new-privileges:true"],
  "restart" => "unless-stopped",
  "logging" => PLATFORM_LOGGING
}.freeze

# Storage contributors are held against the manifest both ways: deleting every
# contributor leaves nas_storage as [] and the play reports ok.
implemented_roles = Array(manifest["services"]).filter_map do |entry|
  entry["role"] if entry.is_a?(Hash) && IMPLEMENTED_STATUSES.include?(entry["status"])
end.uniq
NasStorage.problems(ROOT, implemented_roles).each { |problem| check(failures, false, problem) }

# Nothing outside group_vars/all may define nas_storage_*: q('varnames') would
# pick up a role default partway through a run. Read as YAML (a root key may be
# indented); an unreadable file is reported, not skipped (#599).
storage_prefix_offenders = []
storage_prefix_unreadable = []
Find.find(ROOT) do |path|
  Find.prune if File.basename(path) == ".git"
  # Prune nested checkouts (worktrees, clones): they are another tree (#665). A
  # mutation sandbox has no .git, so planted files are still seen.
  Find.prune if path != ROOT && File.directory?(path) && File.exist?(File.join(path, ".git"))
  next unless File.file?(path) && path.end_with?(".yml")

  relative = path.delete_prefix("#{ROOT}/")
  next if relative.start_with?("inventory/group_vars/all/")

  document = begin
    YAML.safe_load_file(path, aliases: true)
  rescue StandardError => error
    storage_prefix_unreadable << "#{relative} (#{error.class})"
    next
  end
  next unless document.is_a?(Hash)

  document.each_key do |key|
    next unless key.is_a?(String) && key.start_with?(NasStorage::CONTRIBUTOR_PREFIX)

    storage_prefix_offenders << "#{relative}: #{key}"
  end
end
check(failures, storage_prefix_unreadable.empty?,
      "#{storage_prefix_unreadable.join(', ')} could not be read as YAML, so the " \
      "#{NasStorage::CONTRIBUTOR_PREFIX}* namespace sweep did not clear them: a subject a scan " \
      "cannot read is not a subject it checked")
check(failures, storage_prefix_offenders.empty?,
      "#{storage_prefix_offenders.join(', ')} define a #{NasStorage::CONTRIBUTOR_PREFIX}* variable " \
      "outside inventory/group_vars/all: the composition reads every such name in scope, so a " \
      "definition elsewhere joins the storage inventory where it is visible and leaves it where " \
      "it is not")

declared_paths = NasStorage.entries(ROOT).map { |entry| entry.fetch("path") }

# A mounted path is accounted for when nas_storage declares it or an ancestor.
storage_declared = lambda do |path|
  declared_paths.include?(path) ||
    declared_paths.any? { |declared| path.start_with?("#{declared}/") }
end

# How many library/staging pairs the same-mount import check below found. It
# derives its own subject list, so the count is asserted after the sweep.
import_pairs = 0

# Compared afterwards both ways: the guarded failure is the subject list emptying.
self_sizing_containers = Hash.new { |hash, key| hash[key] = [] }

# Which containers were found bind-mounting a file out of ${PLATFORM_CURRENT_DIR:?}.
# Collected during the sweep and compared against the stated expectation after it.
release_mount_containers = Hash.new { |hash, key| hash[key] = [] }

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

  {
    "x-logging" => PLATFORM_LOGGING,
    "x-healthcheck-defaults" => PLATFORM_HEALTHCHECK_DEFAULTS
  }.each do |fragment, expected|
    # Presence first, then equality: absence must be recorded as an exemption.
    exempt = FRAGMENT_EXEMPTIONS.fetch(fragment, []).include?(name)
    check(failures, compose.key?(fragment) || exempt,
          "#{name}: #{fragment} must be declared, or exempted with the reason recorded " \
          "beside FRAGMENT_EXEMPTIONS and in the stack's own comment")
    next unless compose.key?(fragment)

    check(failures, compose[fragment] == expected,
          "#{name}: #{fragment} must hold the values every stack's copy of it shares")
  end

  if compose.key?("x-service-defaults")
    shared = compose.fetch("x-service-defaults")
    check(failures, shared.is_a?(Hash) &&
                    PLATFORM_SERVICE_DEFAULTS.all? { |key, value| shared[key] == value },
          "#{name}: x-service-defaults must carry the platform cpuset, " \
          "security_opt, restart and logging")
  end

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

    # Docker resolves a bind source once at start, so a file mounted from the
    # moving `current` symlink needs its sha256 in a label to force a recreate
    # (#810). This checks a sha256 label exists, not that it names the right key.
    release_mounts = Array(spec["volumes"]).grep(%r{\A\$\{PLATFORM_CURRENT_DIR:\?\}/})
    unless release_mounts.empty?
      release_mount_containers[name] << container
      declared = spec["labels"]
      declared = declared.map { |entry| entry.to_s.split("=", 2) }.to_h if declared.is_a?(Array)
      check(failures, Hash(declared).any? do |key, value|
                        key.to_s.end_with?("-sha256") &&
                          value.to_s.match?(/\A\$\{[A-Z0-9_]+_SHA256:\?\}\z/)
                      end,
            "#{label}: a file bind-mounted out of the release pointer must be labelled with " \
            "its own sha256, or Compose leaves this container on an older release's copy")
    end

    # A self-sizing image must carry a limit; recorded per container and compared
    # after the sweep.
    image_repository = spec["image"].to_s.split("@").first.to_s.rpartition(":").first
    if MEMORY_SELF_SIZING_IMAGES.include?(image_repository)
      self_sizing_containers[name] << container
      check(failures, spec.key?("mem_limit"),
            "#{label}: an image that sizes its own memory from what it can see must " \
            "declare mem_limit, or its runtime reads the host's RAM instead")
    end

    # A declared heap must be at most half the limit (off-heap runs to about the
    # heap again). No subject yet; the tests/policy_manifest_test.rb mutations
    # are this half's only proof.
    limit_bytes = spec.key?("mem_limit") ? parse_bytes(spec.fetch("mem_limit"), label) : nil
    heap_bytes = declared_heap_bytes(spec["environment"] || {}, limit_bytes, label)
    unless heap_bytes.nil?
      check(failures, !limit_bytes.nil?,
            "#{label}: a container declaring a JVM heap must declare mem_limit, " \
            "so the heap is bounded by a number this repository chose")
      check(failures, limit_bytes.nil? || heap_bytes * 2 <= limit_bytes,
            "#{label}: declared heap must be at most half of mem_limit, leaving " \
            "off-heap the room it needs")
    end
    check(failures, spec["privileged"] != true,
          "#{label}: privileged mode is not allowed")
    # no_new_privs: no escalation after start via a setuid binary. Every image
    # honours it (entrypoints drop privileges via setuid(2), which it allows); a
    # genuine exception would need a stated allowlist entry with its reason.
    check(failures, Array(spec["security_opt"]).include?("no-new-privileges:true"),
          "#{label}: must refuse privilege escalation with security_opt no-new-privileges:true")
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

    # The probe must be able to say no: read the command in any Compose shape and
    # hold it to HEALTHCHECK_PROBE. `disable: false` with no test defers to the image.
    probe = spec.dig("healthcheck", "test")
    unless probe.nil?
      words = Array(probe).map(&:to_s)
      words = words.drop(1) if %w[CMD CMD-SHELL].include?(words.first)
      check(failures, words.join(" ").match?(HEALTHCHECK_PROBE),
            "#{label}: health check must reach the service -- an HTTP or TCP endpoint, " \
            "a readiness client, or the image's own health command -- not merely " \
            "observe that a process exists")
    end

    logging = spec["logging"] || {}
    check(failures, logging["driver"] == "json-file",
          "#{label}: logging must use the json-file driver")
    options = logging["options"] || {}
    check(failures, options["max-size"] && options["max-file"],
          "#{label}: logging must be bounded by max-size and max-file")
    # Same two numbers everywhere: the drift a presence check never sees.
    check(failures, logging == PLATFORM_LOGGING,
          "#{label}: logging must be the platform fragment, not a variant of it")

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

    # A library and its `.acquisition` staging directory must share one bind
    # mount: rename(2) refuses to cross a mount boundary, turning every import into
    # a copy with no visible error. Pairs are derived from environment paths.
    mount_targets = Array(spec["volumes"]).filter_map do |mount|
      mount.match(%r{\A.*?:(?<target>/[^:]*)(?::(?:ro|rw))?\z})&.[](:target)
    end
    covering_mount = lambda do |path|
      mount_targets.select { |target| path == target || path.start_with?("#{target}/") }
                   .max_by(&:length)
    end
    environment = spec["environment"].is_a?(Hash) ? spec["environment"] : {}
    container_paths = environment.select do |_name, value|
      value.is_a?(String) && value.match?(%r{\A/[A-Za-z0-9._/-]+\z})
    end
    staging = %r{\A(?<share>.+?)/\.acquisition(?:/|\z)}
    container_paths.each do |staging_name, staging_path|
      share = staging_path[staging, :share]
      next if share.nil?

      container_paths.each do |library_name, library_path|
        next if library_path.match?(staging)
        next unless library_path.start_with?("#{share}/")

        import_pairs += 1
        library_mount = covering_mount.call(library_path)
        staging_mount = covering_mount.call(staging_path)
        check(failures, !library_mount.nil? && library_mount == staging_mount,
              "#{label}: #{library_name} and #{staging_name} must share one bind mount so an " \
              "import is a rename rather than a cross-device copy " \
              "(#{library_path} is inside #{library_mount || 'no mount'}, " \
              "#{staging_path} inside #{staging_mount || 'no mount'})")
      end
    end
  end
end

# Floored: the pairing discovers its own subjects. Bindery declares both of today's
# pairs.
check(failures, import_pairs >= 2,
      "the same-mount import check paired #{import_pairs} libraries with their staging roots; " \
      "at least the two Bindery declares must stay discoverable")

# Exactly, in both directions; a floor would pass a lost subject.
check(failures,
      self_sizing_containers.transform_values(&:sort).sort.to_h ==
        EXPECTED_SELF_SIZING_CONTAINERS.transform_values(&:sort).sort.to_h,
      "containers on self-sizing images are " \
      "#{self_sizing_containers.transform_values(&:sort).sort.to_h.inspect}, and the pinned " \
      "expectation is #{EXPECTED_SELF_SIZING_CONTAINERS.inspect}; update both together")

# The same shape for the release-mounted files, and for the same reason: a
# container that stops mounting one is a subject this check silently loses.
check(failures,
      release_mount_containers.transform_values(&:sort).sort.to_h ==
        EXPECTED_RELEASE_MOUNT_CONTAINERS.transform_values(&:sort).sort.to_h,
      "containers bind-mounting a file out of the release pointer are " \
      "#{release_mount_containers.transform_values(&:sort).sort.to_h.inspect}, and the pinned " \
      "expectation is #{EXPECTED_RELEASE_MOUNT_CONTAINERS.inspect}; update both together")

# Template storage literals are a second declaration of nas_storage, compared
# here as source text (templates span many grammars). Only the media root may be
# mounted as an ancestor of declared entries (Jellyfin mounts the whole tree);
# under the Docker root a path must be declared at or below an entry.
STORAGE_ROOT_ANCESTOR_ALLOWED = {
  "nas_media_root" => true,
  "nas_docker_root" => false
}.freeze
# Floored: a glob that stops matching iterates zero times and passes. Sized
# against the smaller mutation sandbox.
storage_root_templates = Dir[File.join(ROOT, "roles", "*", "templates", "*.j2")].sort
check_floor(failures, storage_root_templates.length, 15,
            "role templates swept for undeclared storage roots")
storage_root_templates.each do |template_path|
  relative_template = template_path.delete_prefix("#{ROOT}/")
  contents = File.read(template_path)
  STORAGE_ROOT_ANCESTOR_ALLOWED.each do |root_variable, ancestor_allowed|
    literal = %r{\{\{\s*#{root_variable}\s*\}\}(/[A-Za-z0-9._/-]+)}
    contents.scan(literal).each do |(suffix)|
      expected = "{{ #{root_variable} }}#{suffix}"
      covered = storage_declared.call(expected) ||
                (ancestor_allowed &&
                 declared_paths.any? { |declared| declared.start_with?("#{expected}/") })
      check(failures, covered,
            "#{relative_template}: #{expected} is not declared in nas_storage")
    end
  end
end

# An override may restate an image only so platform keys sit beside it, never to
# deploy something different; a nil canonical value fails like a mismatch.
Dir[File.join(ROOT, "services", "*", "compose.{mac,integration}.yml")].sort.each do |override_path|
  relative_override = override_path.delete_prefix("#{ROOT}/")
  canonical_path = File.join(File.dirname(override_path), "compose.yml")
  canonical = File.file?(canonical_path) ? YAML.safe_load_file(canonical_path, aliases: true) : {}
  override = YAML.safe_load_file(override_path, aliases: true)
  override.fetch("services", {}).each do |container, spec|
    next unless spec.is_a?(Hash)

    # A ${PLATFORM_CURRENT_DIR:?} mount belongs in compose.yml, where the label
    # rule reads it; overrides would escape the rule.
    check(failures, Array(spec["volumes"]).none? { |volume| volume.to_s.include?("PLATFORM_CURRENT_DIR") },
          "#{relative_override}/#{container}: a file mounted out of the release pointer belongs " \
          "in the canonical compose.yml, where the content-label rule reaches it")
    next unless spec.key?("image")

    check(failures, spec.fetch("image") == canonical.dig("services", container, "image"),
          "#{relative_override}/#{container}: platform image overrides differ from the canonical compose.yml image")
  end
end

# Who can reach a Docker socket proxy (#829): CONTAINERS exposes every
# container's environment, so the reachable set is stated per proxy and compared
# exactly, both ways. Proxy networks must be internal unless the proxy's alone,
# and never external.
SOCKET_PROXY_CONSUMERS = {
  "beszel/socket-proxy" => ["agent-portable"],
  "dozzle/socket-proxy" => ["dozzle"]
}.freeze

# The one publication allowed: Beszel's host-networked agent (#607) cannot join a
# Compose network. Its ceiling is stated beside the port in services/beszel/compose.yml.
SOCKET_PROXY_PORTS = {
  "beszel/socket-proxy" => ["127.0.0.1:2375:2375"],
  "dozzle/socket-proxy" => []
}.freeze

socket_proxy_subjects = []
service_dirs.sort.each do |dir|
  compose_path = File.join(dir, "compose.yml")
  next unless File.file?(compose_path)

  stack = File.basename(dir)
  compose = YAML.safe_load_file(compose_path, aliases: true)
  services = compose.fetch("services", {})
  memberships = services.transform_values do |spec|
    next [] if spec.key?("network_mode")

    spec.key?("networks") ? Array(spec["networks"]).map(&:to_s) : ["default"]
  end
  services.each do |container, spec|
    next unless Array(spec["volumes"]).any? { |volume| volume.to_s.start_with?("/var/run/docker.sock:") }

    subject = "#{stack}/#{container}"
    socket_proxy_subjects << subject
    proxy_networks = memberships.fetch(container)
    reachers = memberships.filter_map do |other, networks|
      other if other != container && !(networks & proxy_networks).empty?
    end
    check(failures, reachers.sort == SOCKET_PROXY_CONSUMERS.fetch(subject, []).sort,
          "#{subject}: shares a network with #{reachers.sort.inspect}, and the stated consumers are " \
          "#{SOCKET_PROXY_CONSUMERS.fetch(subject, []).inspect}; a socket proxy serves every " \
          "container's environment to whatever can reach it")
    proxy_networks.each do |network|
      definition = compose.dig("networks", network) || {}
      shared = memberships.any? { |other, networks| other != container && networks.include?(network) }
      check(failures, definition["external"] != true && (definition["internal"] == true || !shared),
            "#{subject}: network #{network} must be internal, or joined by the proxy alone, and never external")
    end
    check(failures, Array(spec["ports"]).map(&:to_s) == SOCKET_PROXY_PORTS.fetch(subject, []),
          "#{subject}: publishes #{Array(spec["ports"]).inspect}, and the stated exception is " \
          "#{SOCKET_PROXY_PORTS.fetch(subject, []).inspect}")
  end
  # Overrides may narrow a proxy's ports and nothing more.
  next unless services.any? { |container, _spec| socket_proxy_subjects.include?("#{stack}/#{container}") }

  Dir[File.join(dir, "compose.{mac,integration}.yml")].sort.each do |override_path|
    relative_override = override_path.delete_prefix("#{ROOT}/")
    override = YAML.safe_load_file(override_path, aliases: true)
    check(failures, !override.key?("networks"),
          "#{relative_override}: an override may not declare networks in a stack carrying a " \
          "socket proxy; state them in compose.yml, where the consumer map reads them")
    override.fetch("services", {}).each do |container, spec|
      next unless spec.is_a?(Hash)

      proxy = socket_proxy_subjects.include?("#{stack}/#{container}")
      check(failures, !spec.key?("networks") && !spec.key?("network_mode") &&
                      (!proxy || Array(spec["ports"]).empty?),
            "#{relative_override}/#{container}: an override may not change who reaches this stack's " \
            "socket proxy; state it in compose.yml, where the consumer map reads it")
    end
  end
end
check(failures, socket_proxy_subjects.sort == SOCKET_PROXY_CONSUMERS.keys.sort &&
                SOCKET_PROXY_PORTS.keys.sort == SOCKET_PROXY_CONSUMERS.keys.sort,
      "services mounting the Docker socket are #{socket_proxy_subjects.sort.inspect}, and the stated " \
      "consumer map covers #{SOCKET_PROXY_CONSUMERS.keys.sort.inspect}; update both together")

# `!override`/`!reset` need Compose 2.24.4 while nas_compose_minimum is 2.18.0,
# right for the NAS (no tags) and wrong for both disposable lanes. Found as text
# because Psych silently drops unknown tags; checked both ways against what the
# harnesses request.
compose_override_tag_minimum = Gem::Version.new("2.24.4")
compose_override_tag = /^[ \t]*(?:-[ \t]+)?[\w.\-]+:[ \t]+!(?:override|reset)(?:[ \t]|$)/
compose_tagged_kinds = Dir[File.join(ROOT, "services", "*", "compose.*.yml")].sort.filter_map do |path|
  kind = File.basename(path)[/\Acompose\.(.+)\.yml\z/, 1]
  next if kind.nil?

  kind if File.read(path).match?(compose_override_tag)
end.uniq.sort
check(failures, compose_tagged_kinds == %w[integration mac],
      "Compose !override/!reset tags belong to the disposable lanes alone, " \
      "found in: #{compose_tagged_kinds.join(', ')}")
# Neither harness can put this in inventory (host groups hold machine facts;
# the sandbox is a nas_hosts run), so both pass it on the command line.
{
  "tests/mac/lib.sh" => "the Mac lifecycle harness",
  "tests/integration_controller_lib.sh" => "the integration controller"
}.each do |relative_path, label|
  path = File.join(ROOT, relative_path)
  source = File.file?(path) ? File.read(path) : ""
  requested = source.scan(/nas_compose_minimum=([0-9]+(?:\.[0-9]+)*)/).flatten
  check(failures, !requested.empty? &&
                  requested.all? { |value| Gem::Version.new(value) >= compose_override_tag_minimum },
        "#{relative_path}: #{label} must request a Compose floor of at least " \
        "#{compose_override_tag_minimum}, because the overrides it deploys use !override")
end

# Every role declares its interface. Floored (#556): a glob that stops matching
# passes vacuously; sized against the smaller mutation sandbox.
interface_roles = Dir[File.join(ROOT, "roles", "*")].select { |p| File.directory?(p) }
check_floor(failures, interface_roles.length, 15, "roles declaring an interface")
interface_roles.each do |role|
  name = File.basename(role)
  spec_path = File.join(role, "meta", "argument_specs.yml")
  check(failures, File.file?(spec_path), "role #{name}: missing meta/argument_specs.yml")
  next unless File.file?(spec_path)

  spec = YAML.safe_load_file(spec_path)
  # Non-empty, not merely a Hash: `options: {}` declares an interface of nothing.
  declared_options = spec.dig("argument_specs", "main", "options")
  check(failures, declared_options.is_a?(Hash) && !declared_options.empty?,
        "role #{name}: argument_specs declares no options")
end

# Deployment goes through the module: a shell-out always claims a change and
# cannot run under --check. Read from parsed tasks, not a text window.
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

# Timing is platform policy: a bare number is neither the shared value nor a
# documented deviation. retries/delay are read as task keywords (modules have
# arguments of the same names); wait_timeout wherever a task carries it.
literal_wait_timeout = lambda do |node|
  case node
  when Hash
    node.any? do |key, value|
      (key.to_s == "wait_timeout" && value.is_a?(Integer)) || literal_wait_timeout.call(value)
    end
  when Array then node.any? { |value| literal_wait_timeout.call(value) }
  else false
  end
end
# Checked as "reads a declared *_retries/*_delay variable", not "is not an
# integer": `"20"` and `"{{ 20 }}"` are strings (#844). An expression around the
# name stays allowed.
shared_timing_variables = YAML.safe_load_file(File.join(ROOT, "inventory/group_vars/all/main.yml"),
                                              aliases: true).keys
TIMING_KEYWORD_POLICY = {
  "retries" => "platform_readiness_retries",
  "delay" => "platform_readiness_delay"
}.freeze
role_task_files.each do |path|
  relative_path = path.delete_prefix("#{ROOT}/")
  role_root = relative_path[%r{\Aroles/[^/]+}]
  role_defaults_path = File.join(ROOT, role_root, "defaults/main.yml")
  role_defaults = File.exist?(role_defaults_path) ? (YAML.safe_load_file(role_defaults_path, aliases: true) || {}).keys : []
  declared_timing = shared_timing_variables + role_defaults
  flatten_tasks(YAML.safe_load_file(path, aliases: true)).each do |task|
    task_name = task["name"] || "an unnamed task"
    TIMING_KEYWORD_POLICY.each do |keyword, shared_variable|
      next unless task.key?(keyword)

      value = task[keyword]
      read = value.is_a?(String) && value.include?("{{") ? value.scan(/\b[a-z][a-z0-9_]*_(?:retries|delay)\b/).uniq : []
      undeclared = read - declared_timing
      check(failures, !read.empty? && undeclared.empty?,
            "#{relative_path}: \"#{task_name}\" writes #{keyword}: #{value.inspect}" \
            "#{undeclared.empty? ? ' as a literal' : ", reading undeclared #{undeclared.join(', ')}"}; " \
            "read #{shared_variable} or a role default that says why it differs")
    end
    check(failures, !literal_wait_timeout.call(task),
          "#{relative_path}: \"#{task_name}\" writes wait_timeout as a literal; " \
          "read platform_compose_wait_timeout or a role default that says why it differs")
  end
end

# --- whitespace backslash escapes inside Jinja expressions -------------------
# Inside `{{ }}` Ansible pre-escapes backslashes, so '\n' stays two characters and
# a split on it finds nothing (#513, #530); `{% %}` is exempt, and YAML quoting
# does not change it. Only \n, \t and \r are refused, so backreferences still
# work; a regex-filter argument would be a false positive (none today).
root_playbook_files = Dir[File.join(ROOT, "*.yml")].sort.select do |path|
  document = YAML.safe_load_file(path, aliases: true)
  document.is_a?(Array) && document.all? { |play| play.is_a?(Hash) && play.key?("hosts") }
end
# Floors sized against the mutation sandbox, not the tree.
check_floor(failures, role_task_files.length, 60,
            "the Jinja escape scanner found too few role task files")
check_floor(failures, root_playbook_files.length, 5,
            "the Jinja escape scanner found too few root playbooks")
(role_task_files + root_playbook_files).each do |path|
  relative_path = path.delete_prefix("#{ROOT}/")
  # The whole document: a playbook's strings live in pre_tasks, vars and play keywords too.
  task_strings(YAML.safe_load_file(path, aliases: true)).each do |value|
    jinja_expression_regions(value).each do |region|
      next unless region.match?(/\\[ntr]/)

      check(failures, false,
            "#{relative_path}: the Jinja expression {{#{region}}} contains a whitespace " \
            "backslash escape, which Ansible will not process -- AnsibleLexer pre-escapes " \
            "every backslash in an expression's string constants, so \\n stays two " \
            "characters and a split or join on it finds no separator. The YAML quoting " \
            "does not decide it: folded, single-quoted and double-quoted scalars all read " \
            "one element. Hoist the separator into a double-quoted vars entry, where YAML " \
            "resolves it before Jinja sees it, or drop the separator entirely with " \
            "splitlines")
    end
  end
end

# A public-internet fetch fails on somebody else's outage, and the poller then
# refuses the revision (#330). get_url is today's only such module; it must carry
# retries, delay, a non-literal timeout, and an `until` naming its register.
EXTERNAL_FETCH_MODULES = %w[ansible.builtin.get_url get_url].freeze
DOWNLOAD_KEYWORD_POLICY = {
  "retries" => "platform_download_retries",
  "delay" => "platform_download_delay"
}.freeze
external_fetch_tasks = 0
role_task_files.each do |path|
  relative_path = path.delete_prefix("#{ROOT}/")
  flatten_tasks(YAML.safe_load_file(path, aliases: true)).each do |task|
    fetch_module = EXTERNAL_FETCH_MODULES.find { |name| task.key?(name) }
    next if fetch_module.nil?

    external_fetch_tasks += 1
    task_name = task["name"] || "an unnamed task"
    arguments = task[fetch_module].is_a?(Hash) ? task[fetch_module] : {}
    check(failures,
          arguments.key?("timeout") && !arguments["timeout"].is_a?(Integer),
          "#{relative_path}: \"#{task_name}\" fetches an external URL without a " \
          "non-literal timeout; read platform_download_timeout or a role default that " \
          "says why it differs")
    DOWNLOAD_KEYWORD_POLICY.each do |keyword, shared_variable|
      check(failures, task.key?(keyword),
            "#{relative_path}: \"#{task_name}\" fetches an external URL without #{keyword}; " \
            "read #{shared_variable} so one network blip cannot fail the converge")
    end
    registered = task["register"].to_s
    check(failures,
          !registered.empty? && task["until"].to_s.include?(registered),
          "#{relative_path}: \"#{task_name}\" must register its result and retry " \
          "until that result is not failed; retries without such an until run once")
  end
end

# Floored: Paperless and Pinchflat are the two external fetches.
check(failures, external_fetch_tasks >= 2,
      "the external fetch policy inspected #{external_fetch_tasks} get_url tasks; " \
      "at least the Paperless OCR model and the Pinchflat yt-dlp build must stay discoverable")

check(failures, deploys_through_module,
      "no role deploys anything through docker_compose_v2")

# docker_compose_v2_exec checks rc only when `detach` is true (#521), so every
# other exec task must state failed_when; `failed_when: false` satisfies it. Only
# a literal `detach: true` is exempt.
compose_exec_tasks = 0
role_task_files.each do |path|
  relative_path = path.delete_prefix("#{ROOT}/")
  flatten_tasks(YAML.safe_load_file(path, aliases: true)).each do |task|
    arguments = task["community.docker.docker_compose_v2_exec"]
    next unless arguments.is_a?(Hash)

    compose_exec_tasks += 1
    next if arguments["detach"] == true

    check(failures, task.key?("failed_when"),
          "#{relative_path}: \"#{task['name'] || 'an unnamed task'}\" runs " \
          "docker_compose_v2_exec without failed_when; the module sets check_rc only " \
          "for detach, so this task reports success on any exit code. State the rc " \
          "condition it requires, or state failed_when: false and say why the failure " \
          "is tolerated")

    # failed_when replaces the module's verdict, so a condition on a register the
    # task does not set disarms it; it must name this task's own register.
    guard = task["failed_when"]
    next if guard == false || !task.key?("failed_when")

    registered = task["register"]
    check(failures, registered.is_a?(String) && !registered.empty?,
          "#{relative_path}: \"#{task['name'] || 'an unnamed task'}\" states a " \
          "failed_when condition but registers nothing, so the condition cannot be " \
          "reading this task's result")
    next unless registered.is_a?(String) && !registered.empty?

    check(failures, Array(guard).join(" ").include?(registered),
          "#{relative_path}: \"#{task['name'] || 'an unnamed task'}\" states a " \
          "failed_when condition that never names #{registered}, the register it " \
          "writes; an undefined lookup there evaluates false and disarms the module " \
          "rather than guarding it")
  end
end
# Floored at twelve, not today's count: the sandbox omits include_tasks targets.
check_floor(failures, compose_exec_tasks, 12,
            "docker_compose_v2_exec tasks the exit-code policy inspected")

# Every deployed service reports its own deployment, gated on a registered
# Compose result so unchanged converges send nothing.
deployment_reports_declared = false
shared_recovery_callers = 0
pre_upgrade_backup_callers = 0
# Roles with `state: present` Compose but no plain deployment owe no report and
# are not container_health subjects either, so they are stated both ways.
# pre_upgrade_backup (#836): its callers name its register instead.
REPORT_FREE_COMPOSE_ROLES = %w[container_health pre_upgrade_backup].freeze
# Stated, because the list below is narrowed against the inspected tree and a
# narrowed list that empties passes vacuously (#646).
REPORT_FREE_COMPOSE_ROLE_COUNT = 2
# The only legitimate narrowing: roles the mutation fixture omits on purpose
# (reasons in tests/policy_mutation_support.rb).
MUTATION_FIXTURE_ABSENT_ROLES = %w[container_cpu container_health image_downgrade_guard
                                   image_prune].freeze
report_free_deployers = []
Dir[File.join(ROOT, "roles", "*")].select { |p| File.directory?(p) }.each do |role|
  name = File.basename(role)
  tasks = load_role_tasks(role, failures)
  deployments = tasks.select do |task|
    compose = task["community.docker.docker_compose_v2"]
    next false unless compose.is_a?(Hash)

    compose["state"] == "present"
  end
  next if deployments.empty?

  # Every `up` must register, the shared recovery included: the report is gated on it.
  registers = deployments.map { |task| task["register"] }
  check(failures, registers.all? { |register| register.is_a?(String) },
        "role #{name}: every Compose deployment must register its result for the deployment report")

  # The report is owed by a role holding a plain `up` (#646); the shared
  # force-recreate in roles/container_health is reported by its caller (below).
  plain_deployments = deployments.reject { |task| task["community.docker.docker_compose_v2"].key?("recreate") }
  if plain_deployments.empty?
    report_free_deployers << name
    next
  end

  reports = tasks.select do |task|
    task.dig("ansible.builtin.include_role", "name") == "deployment_bundle" &&
      task.dig("ansible.builtin.include_role", "tasks_from") == "report"
  end
  check(failures, reports.length == 1,
        "role #{name}: deploys Compose services but declares #{reports.length} deployment reports, not one")
  next unless reports.length == 1

  deployment_reports_declared = true

  report_vars = reports.first["vars"] || {}
  check(failures, report_vars["deployment_report_service"].to_s.strip != "",
        "role #{name}: deployment report names no service")
  gate = report_vars["deployment_report_changed"].to_s
  check(failures, registers.compact.all? { |register| gate.include?(register) },
        "role #{name}: deployment report ignores a registered Compose deployment")

  # The same for the shared pre-upgrade copy: its rescue start is an `up` the
  # caller's report has to name, as the caller's own copy of it used to.
  if tasks.any? { |task| task.dig("ansible.builtin.include_role", "name") == "pre_upgrade_backup" }
    pre_upgrade_backup_callers += 1
    check(failures, gate.include?("pre_upgrade_backup_restart"),
          "role #{name}: includes roles/pre_upgrade_backup but its deployment report ignores " \
          "pre_upgrade_backup_restart, the register that role's rescue start writes")
  end

  # A caller spending the shared recovery must name its register, or a repairing
  # recreate goes unreported.
  next unless tasks.any? do |task|
    task.dig("ansible.builtin.include_role", "name") == "container_health" &&
      task.dig("ansible.builtin.include_role", "tasks_from") == "recover"
  end

  shared_recovery_callers += 1
  check(failures, gate.include?("container_health_wedged_recreate"),
        "role #{name}: includes the shared container-health recovery but its deployment report " \
        "ignores container_health_wedged_recreate, the register that recovery writes; a converge " \
        "that repaired a wedged container would report nothing")
end
# Floored at four of today's six callers, so one legitimate conversion passes.
check_floor(failures, shared_recovery_callers, 4,
            "roles whose deployment report must name the shared recovery's register")
# Six callers today; the floor stops every caller quietly dropping it.
check_floor(failures, pre_upgrade_backup_callers, 6,
            "roles whose deployment report must name the shared pre-upgrade copy's register")
# Held against the roles the inspected tree has, so the mutation sandbox (which
# omits roles/container_health) passes while both directions hold elsewhere.
expected_report_free = REPORT_FREE_COMPOSE_ROLES.select { |role| Dir.exist?(File.join(ROOT, "roles", role)) }
check(failures, REPORT_FREE_COMPOSE_ROLES.length == REPORT_FREE_COMPOSE_ROLE_COUNT,
      "REPORT_FREE_COMPOSE_ROLES holds #{REPORT_FREE_COMPOSE_ROLES.length} role(s), not " \
      "#{REPORT_FREE_COMPOSE_ROLE_COUNT}; the pin below is narrowed against the inspected tree " \
      "before it is compared, so an emptied constant would compare [] against [] and report a " \
      "clean sweep having checked nothing")
narrowed = REPORT_FREE_COMPOSE_ROLES - expected_report_free
check(failures, (narrowed - MUTATION_FIXTURE_ABSENT_ROLES).empty?,
      "#{(narrowed - MUTATION_FIXTURE_ABSENT_ROLES).inspect} is pinned as running a Compose `up` " \
      "with no plain deployment but its role directory is not in the inspected tree, and the " \
      "mutation fixture does not omit it; a role that left the tree is a stale pin rather than a " \
      "narrowing")
# Deleting roles/container_health from the real tree narrows this legally; the
# shared-recovery floor and tests/container_health_wiring_test.rb catch that.
check(failures, report_free_deployers.sort == expected_report_free.sort,
      "roles that run a Compose `up` without a plain deployment are " \
      "#{report_free_deployers.sort.inspect}, not #{expected_report_free.sort.inspect}. Such " \
      "a role owes no deployment report here and is not a container-health subject either, so a " \
      "new one deploys Compose with nothing asking anything of it; argue it here or give it a " \
      "plain deployment")

# A pre-upgrade copy that stops a container must, when the copy fails, start it
# again on its old image, only over a store still present, and still fail the
# run. The pg_dump entry (#826) is exempt by name from the store clause: it never
# stops the store's container.
pre_upgrade_stops = 0
pre_upgrade_paths = %w[main.yml pg_dump.yml].map { |f| File.join(ROOT, "roles", "pre_upgrade_backup", "tasks", f) }
                                           .select { |p| File.file?(p) } +
                    Dir[File.join(ROOT, "roles", "*", "tasks", "pre_upgrade_backup.yml")].sort
pre_upgrade_paths.each do |path|
  name = File.basename(File.dirname(path, 2))
  dumps = path.end_with?(File.join("pre_upgrade_backup", "tasks", "pg_dump.yml"))
  document = YAML.safe_load_file(path, aliases: true)
  stops = ->(task) { task.dig("community.docker.docker_compose_v2", "state") == "stopped" }
  next unless flatten_tasks(document).any?(&stops)

  pre_upgrade_stops += 1
  unit = Array(document).find { |task| task.is_a?(Hash) && flatten_tasks(task["block"]).any?(&stops) }
  rescue_tasks = flatten_tasks(unit&.fetch("rescue", nil))
  start = rescue_tasks.find { |task| task.dig("community.docker.docker_compose_v2", "state") == "present" }
  start_index = start ? rescue_tasks.index(start) : 0
  check(failures,
        start && unit["always"].nil? &&
          rescue_tasks.first(start_index).none? { |task| task.key?("ansible.builtin.fail") } &&
          rescue_tasks.all? do |task|
            !task.key?("community.docker.docker_compose_v2") ||
              task.dig("community.docker.docker_compose_v2", "recreate") == "never"
          end,
        "role #{name}: a failed pre-upgrade copy must start the stopped container again, on its old image")
  # Exactly this shape: re-read the pre-stop path, tolerate that read failing,
  # and start only on a regular file (`exists` or looser let the bug back in).
  pre_stop_read = Array(document).find { |task| task.is_a?(Hash) && task.key?("ansible.builtin.stat") }
  store_read = rescue_tasks.find { |task| task.key?("ansible.builtin.stat") }
  check(failures,
        start.nil? || dumps || (store_read && pre_stop_read && rescue_tasks.index(store_read) < start_index &&
                       store_read.dig("ansible.builtin.stat", "path") ==
                         pre_stop_read.dig("ansible.builtin.stat", "path") &&
                       store_read["failed_when"] == false &&
                       Array(start["when"]) == ["#{store_read['register']}.stat.isreg | default(false)"]),
        "role #{name}: a failed pre-upgrade copy must not start the old container over a missing store")
  check(failures, rescue_tasks.last&.key?("ansible.builtin.fail"),
        "role #{name}: a failed pre-upgrade copy must still fail the run")
  next unless dumps

  # The dump runs after every writer stops, fails on any rc (unset included),
  # and a failure restarts exactly what was stopped.
  block_tasks = flatten_tasks(unit&.fetch("block", nil))
  stop = block_tasks.find(&stops)
  dump = block_tasks.find { |task| task.key?("community.docker.docker_compose_v2_exec") }
  check(failures,
        stop && dump && block_tasks.index(stop) < block_tasks.index(dump) &&
          dump["failed_when"].to_s.include?(".rc | default(1) != 0") &&
          start && start.dig("community.docker.docker_compose_v2", "services") ==
                   stop.dig("community.docker.docker_compose_v2", "services"),
        "role #{name}: tasks/pg_dump.yml must dump the database after stopping the application, fail on " \
        "any exit code, and start again every service it stopped when the dump fails")
  # The code archive (#884): inside the rescued block, after the dump, from the
  # application's running image, never the pin.
  archive = block_tasks.find { |task| Array(task.dig("ansible.builtin.command", "argv"))[0, 2] == %w[docker run] }
  check(failures,
        archive && dump && block_tasks.index(dump) < block_tasks.index(archive) &&
          Array(archive.dig("ansible.builtin.command", "argv")).include?("{{ pre_upgrade_backup_deployed_image_id }}") &&
          !archive.key?("ignore_errors") && !archive.key?("failed_when"),
        "role #{name}: tasks/pg_dump.yml must archive the code tree after the dump, inside the block its " \
        "rescue covers, from the image the application ran, and fail when the archive does")
end
# Two since #826: the shared role's copy and its dump. The callers that reach it
# are floored at six by the deployment-report clause above.
check_floor(failures, pre_upgrade_stops, 2, "pre-upgrade copies that stop a container")

# Vaultwarden's call site, argument by argument: this decides the platform's one
# credential-bearing copy (rsa_key*). Kapowarr's is held by its static contract.
VAULTWARDEN_PRE_UPGRADE_ARGUMENTS = {
  "pre_upgrade_backup_service_name" => "vaultwarden",
  "pre_upgrade_backup_compose_service" => "vaultwarden",
  "pre_upgrade_backup_project_name" => "{{ vaultwarden_compose_project_name }}",
  "pre_upgrade_backup_store_dir" => "{{ vaultwarden_data_host_path }}",
  "pre_upgrade_backup_store_file" => "db.sqlite3",
  "pre_upgrade_backup_path" => "{{ vaultwarden_pre_upgrade_backup_path }}",
  "pre_upgrade_backup_manage_ownership" => true
}.freeze
vaultwarden_deploy_path = File.join(ROOT, "roles", "vaultwarden", "tasks", "deploy.yml")
check(failures, File.file?(vaultwarden_deploy_path),
      "role vaultwarden: tasks/deploy.yml is missing, so its pre-upgrade copy arguments cannot be read")
if File.file?(vaultwarden_deploy_path)
  vaultwarden_copies = flatten_tasks(YAML.safe_load_file(vaultwarden_deploy_path, aliases: true)).select do |task|
    task.dig("ansible.builtin.include_role", "name") == "pre_upgrade_backup"
  end
  check(failures, vaultwarden_copies.length == 1,
        "role vaultwarden: roles/vaultwarden/tasks/deploy.yml includes roles/pre_upgrade_backup " \
        "#{vaultwarden_copies.length} times, not once, so its store is not copied before a pinned upgrade")
  copy_vars = vaultwarden_copies.first&.fetch("vars", nil) || {}
  VAULTWARDEN_PRE_UPGRADE_ARGUMENTS.each do |argument, expected|
    check(failures, copy_vars[argument] == expected,
          "role vaultwarden: the pre-upgrade copy must be given #{argument}: #{expected.inspect}, " \
          "not #{copy_vars[argument].inspect}")
  end
  check(failures, Array(copy_vars["pre_upgrade_backup_extra_patterns"]).include?("rsa_key*"),
        "role vaultwarden: the pre-upgrade copy must carry rsa_key*, the key every session it issued " \
        "is signed with, not #{copy_vars['pre_upgrade_backup_extra_patterns'].inspect}")
end

# Karakeep's call site (#826): queue.db travels with db.db, and the application's
# guard must come first under the same when and tags.
KARAKEEP_PRE_UPGRADE_ARGUMENTS = {
  "pre_upgrade_backup_service_name" => "karakeep",
  "pre_upgrade_backup_compose_service" => "karakeep",
  "pre_upgrade_backup_project_name" => "{{ karakeep_compose_project_name }}",
  "pre_upgrade_backup_store_dir" => "{{ karakeep_data_host_path }}",
  "pre_upgrade_backup_store_file" => "db.db",
  "pre_upgrade_backup_extra_patterns" => ["queue.db"],
  "pre_upgrade_backup_path" => "{{ karakeep_pre_upgrade_backup_path }}",
  "pre_upgrade_backup_manage_ownership" => "{{ platform_kind == 'nas' or (platform_manage_linux_ownership | bool) }}"
}.freeze
karakeep_deploy_path = File.join(ROOT, "roles", "karakeep", "tasks", "deploy.yml")
check(failures, File.file?(karakeep_deploy_path),
      "role karakeep: tasks/deploy.yml is missing, so its pre-upgrade copy arguments cannot be read")
if File.file?(karakeep_deploy_path)
  karakeep_tasks = flatten_tasks(YAML.safe_load_file(karakeep_deploy_path, aliases: true))
  includes_of = ->(role) { karakeep_tasks.each_index.select { |i| karakeep_tasks[i].dig("ansible.builtin.include_role", "name") == role } }
  karakeep_copies = includes_of.call("pre_upgrade_backup")
  check(failures, karakeep_copies.length == 1,
        "role karakeep: roles/karakeep/tasks/deploy.yml includes roles/pre_upgrade_backup " \
        "#{karakeep_copies.length} times, not once, so its store is not copied before a pinned upgrade")
  copy_task = karakeep_copies.first && karakeep_tasks[karakeep_copies.first]
  copy_vars = copy_task&.fetch("vars", nil) || {}
  KARAKEEP_PRE_UPGRADE_ARGUMENTS.each do |argument, expected|
    check(failures, copy_vars[argument] == expected,
          "role karakeep: the pre-upgrade copy must be given #{argument}: #{expected.inspect}, " \
          "not #{copy_vars[argument].inspect}")
  end
  app_guard = includes_of.call("image_downgrade_guard")
                         .select { |i| karakeep_copies.first && i < karakeep_copies.first }
                         .map { |i| karakeep_tasks[i] }
                         .find { |task| task.dig("vars", "image_downgrade_guard_compose_service") == "karakeep" }
  check(failures, app_guard &&
                  Array(app_guard["when"]) == Array(copy_task&.fetch("when", nil)) &&
                  Array(app_guard["tags"]) == Array(copy_task&.fetch("tags", nil)),
        "role karakeep: the pre-upgrade copy must follow the application's image_downgrade_guard, under " \
        "the same when and tags, so a downgraded pin is refused before the copy stops anything")
  karakeep_deploy_index = karakeep_tasks.index { |task| task["register"] == "karakeep_deploy" }
  check(failures, karakeep_copies.first && karakeep_deploy_index && karakeep_copies.first < karakeep_deploy_index,
        "role karakeep: the pre-upgrade copy must run before the Compose deployment that registers " \
        "karakeep_deploy, or the migration it exists to undo has already run")
end

# No caller hands roles/pre_upgrade_backup a pin (#858): an include parameter
# outranks the role's own set_fact, so a passed pin would silently win. Floored
# at the six callers.
pre_upgrade_includes = Dir[File.join(ROOT, "roles", "*", "tasks", "*.yml")].sort.flat_map do |path|
  flatten_tasks(YAML.safe_load_file(path, aliases: true)).select do |task|
    task.is_a?(Hash) && task.dig("ansible.builtin.include_role", "name") == "pre_upgrade_backup"
  end.map { |task| [path.delete_prefix("#{ROOT}/"), task] }
end
pre_upgrade_includes.each do |relative, task|
  check(failures, !(task["vars"] || {}).key?("pre_upgrade_backup_pinned_image"),
        "#{relative}: \"#{task['name']}\" hands roles/pre_upgrade_backup a pre_upgrade_backup_pinned_image, " \
        "which outranks the pin the role reads from the service's own Compose file")
end
check_floor(failures, pre_upgrade_includes.length, 6, "includes of roles/pre_upgrade_backup")

# Nextcloud's and Paperless-ngx's pg_dump call sites (#826): every writer (cron
# included) is stopped, the guard comes first, and the dump sits after the data
# service deploys and before the application migrates.
POSTGRES_PRE_UPGRADE_CALLERS = {
  "nextcloud" => {
    "service" => "nextcloud", "stop" => %w[nextcloud cron], "project" => "{{ nextcloud_compose_project_name }}",
    "data_deploy" => "nextcloud_data_deploy", "deploy" => "nextcloud_deploy",
    # #884: the data root is also the code, so it is archived beside the dump,
    # and outside that root, which the next upgrade's rsync --delete empties.
    "code_root" => "{{ nextcloud_data_host_path }}",
    "code_archive_dir" => "{{ nextcloud_postgres_host_path }}/pre-upgrade-backup"
  },
  "paperless_ngx" => {
    "service" => "webserver", "stop" => %w[webserver], "project" => "{{ paperless_compose_project_name }}",
    "data_deploy" => "paperless_data_deploy", "deploy" => "paperless_deploy"
  }
}.freeze
POSTGRES_PRE_UPGRADE_CALLERS.each do |role, expected|
  deploy_path = File.join(ROOT, "roles", role, "tasks", "deploy.yml")
  check(failures, File.file?(deploy_path),
        "role #{role}: tasks/deploy.yml is missing, so its pre-upgrade dump arguments cannot be read")
  next unless File.file?(deploy_path)

  tasks = flatten_tasks(YAML.safe_load_file(deploy_path, aliases: true))
  includes_of = ->(name) { tasks.each_index.select { |i| tasks[i].dig("ansible.builtin.include_role", "name") == name } }
  dumps = includes_of.call("pre_upgrade_backup")
  check(failures, dumps.length == 1,
        "role #{role}: roles/#{role}/tasks/deploy.yml includes roles/pre_upgrade_backup #{dumps.length} " \
        "times, not once, so its database is not dumped before a pinned upgrade")
  dump_task = dumps.first && tasks[dumps.first]
  dump_vars = dump_task&.fetch("vars", nil) || {}
  {
    "tasks_from" => ["pg_dump", dump_task&.dig("ansible.builtin.include_role", "tasks_from")],
    "pre_upgrade_backup_service_name" => [role.tr("_", "-"), dump_vars["pre_upgrade_backup_service_name"]],
    "pre_upgrade_backup_compose_service" => [expected["service"], dump_vars["pre_upgrade_backup_compose_service"]],
    "pre_upgrade_backup_stop_services" => [expected["stop"], dump_vars["pre_upgrade_backup_stop_services"]],
    "pre_upgrade_backup_database_service" => ["db", dump_vars["pre_upgrade_backup_database_service"]],
    "pre_upgrade_backup_project_name" => [expected["project"], dump_vars["pre_upgrade_backup_project_name"]],
    "pre_upgrade_backup_code_root" => [expected["code_root"], dump_vars["pre_upgrade_backup_code_root"]],
    "pre_upgrade_backup_code_archive_dir" => [expected["code_archive_dir"],
                                              dump_vars["pre_upgrade_backup_code_archive_dir"]]
  }.each do |argument, (want, got)|
    check(failures, want == got,
          "role #{role}: the pre-upgrade dump must be given #{argument}: #{want.inspect}, not #{got.inspect}")
  end
  guard = includes_of.call("image_downgrade_guard").select { |i| dumps.first && i < dumps.first }
                     .map { |i| tasks[i] }
                     .find { |task| task.dig("vars", "image_downgrade_guard_compose_service") == expected["service"] }
  check(failures, guard &&
                  Array(guard["when"]) == Array(dump_task&.fetch("when", nil)) &&
                  Array(guard["tags"]) == Array(dump_task&.fetch("tags", nil)),
        "role #{role}: the pre-upgrade dump must follow the #{expected['service']} image_downgrade_guard, " \
        "under the same when and tags, so a downgraded pin is refused before the dump stops anything")
  data_index = tasks.index { |task| task["register"] == expected["data_deploy"] }
  deploy_index = tasks.index { |task| task["register"] == expected["deploy"] }
  check(failures, dumps.first && data_index && deploy_index && data_index < dumps.first && dumps.first < deploy_index,
        "role #{role}: the pre-upgrade dump must run after the deployment registering " \
        "#{expected['data_deploy']}, which brings the database up, and before the one registering " \
        "#{expected['deploy']}, or the migration it exists to undo has already run")
end

# The per-service report publishes via pushover_publish.yml (#558) only outside
# --check, as a redacted, changeless POST. The run summary must never publish,
# or poller-deployed releases would be announced twice.
report_path = File.join(ROOT, "roles/deployment_bundle/tasks/report.yml")
summary_path = File.join(ROOT, "roles/deployment_bundle/tasks/summary.yml")
publish_path = File.join(ROOT, "roles/deployment_bundle/tasks/pushover_publish.yml")
if deployment_reports_declared
  check(failures, File.file?(report_path),
        "roles/deployment_bundle/tasks/report.yml is missing but roles report deployments")
end
if File.file?(summary_path)
  summary_publish = flatten_tasks(Array(YAML.safe_load_file(summary_path, aliases: true))).find do |task|
    task.is_a?(Hash) && task.values.any? { |value| value.to_s.include?("pushover_publish") }
  end
  check(failures, summary_publish.nil?,
        "deployment summary includes pushover_publish.yml again (#{summary_publish&.fetch('name', nil).inspect}): " \
        "the poller announces every release it deploys, so a summary that publishes sends it twice")
end
{ report_path => "deployment report" }.each do |path, label|
  next unless File.file?(path)

  publish = Array(YAML.safe_load_file(path, aliases: true)).find do |task|
    task.is_a?(Hash) && task["ansible.builtin.include_tasks"] == "pushover_publish.yml"
  end
  check(failures, publish,
        "#{label}: no task includes pushover_publish.yml to deliver it")
  next unless publish

  check(failures, Array(publish["when"]).any? { |c| c.to_s.include?("not ansible_check_mode") },
        "#{label} must not publish under --check")
  # Each message belongs to one Pushover application (#558): the per-service
  # report is container lifecycle.
  application_token = { report_path => "vault_pushover_containers_token" }.fetch(path)
  check(failures, publish.dig("vars", "deployment_pushover_token_variable") == application_token,
        "#{label} must send with #{application_token}")
end
publish_tasks = File.file?(publish_path) ? YAML.safe_load_file(publish_path, aliases: true) : []
publish_task = Array(publish_tasks).find { |task| task.is_a?(Hash) && task.key?("ansible.builtin.uri") }
check(failures, publish_task || !deployment_reports_declared,
      "roles/deployment_bundle/tasks/pushover_publish.yml: no uri task publishes the report")
if publish_task
  request = publish_task.fetch("ansible.builtin.uri")
  body = request["body"].is_a?(Hash) ? request["body"] : {}
  check(failures, request["url"] == "{{ deployment_pushover_api_url }}",
        "deployment report must POST to deployment_pushover_api_url, which the lanes redirect")
  check(failures, request["body_format"] == "form-urlencoded",
        "deployment report must be a form POST, which is what Pushover's API reads")
  check(failures, body["token"] == "{{ lookup('ansible.builtin.vars', deployment_pushover_token_variable) }}" &&
                  body["user"].to_s.include?("vault_pushover_user_key"),
        "deployment report must publish with the application token its caller names and the vault's user key")
  check(failures, body["title"].to_s.include?("truncate(250") &&
                  body["message"].to_s.include?("truncate(1024"),
        "deployment report must bound title and message to Pushover's 250/1024 limits")
  check(failures, publish_task["changed_when"] == false && publish_task["no_log"] == true,
        "deployment report must claim no change and must not log its credentials")
  check(failures, publish_task["failed_when"] == false,
        "deployment report must leave the verdict to its assert, or an unreachable Pushover fails the converge")
end

# /System/Info/Public answers 503 while Jellyfin initializes. Read through
# static_role_tasks, or the nil guard below would pass on an unread role.
jellyfin_tasks_path = File.join(ROOT, "roles/jellyfin/tasks/main.yml")
jellyfin_tasks = File.exist?(jellyfin_tasks_path) ? static_role_tasks(jellyfin_tasks_path) : []
jellyfin_startup = jellyfin_tasks.find do |task|
  task.dig("ansible.builtin.uri", "url").to_s.include?("/System/Info/Public")
end
# The retry count is a role default now that timing literals are refused in
# tasks, so the property is read through whichever variable the task names.
jellyfin_role_defaults = YAML.safe_load_file(File.join(ROOT, "roles/jellyfin/defaults/main.yml"))
jellyfin_startup_retries = jellyfin_startup && jellyfin_startup["retries"]
resolved_startup_retries =
  if jellyfin_startup_retries.is_a?(Integer)
    jellyfin_startup_retries
  else
    jellyfin_role_defaults[
      jellyfin_startup_retries.to_s[/\A\{\{\s*(\w+)\s*\}\}\z/, 1].to_s
    ].to_i
  end
check(failures,
      jellyfin_startup.nil? ||
        (jellyfin_startup.key?("until") && resolved_startup_retries > 0),
      "reading Jellyfin startup state must retry until the server finishes loading")

# The Paperless contract's runtime half lives in paperless-runtime.rb (#147).
paperless_contract = File.read(File.join(ROOT, "tests", "contracts", "paperless-runtime.rb"))
# The snapshot's Ruby is snapshot-paperless.rb (#315); the .sh is only a wrapper.
paperless_snapshot = File.read(File.join(ROOT, "tests", "mac", "snapshot-paperless.rb"))
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
  # One include carrying this service's own name, read from parsed tasks.
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
  # The role gates itself; a caller repeating the guard copies a condition it does not own.
  container_cpu_conditions = container_cpu_includes.flat_map { |task| Array(task["when"]) }
  check(failures,
        container_cpu_conditions.none? { |condition| condition.to_s.include?("ansible_check_mode") },
        "#{name}: container CPU verification must not repeat the role's own check-mode gate")
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

# include_tasks never applies argument_specs, so a phase matching no gate is a
# silent no-op. Each gated file opens with an assert naming its phases, every
# gated literal is in it, and callers pass exactly that set.
PHASE_GATE_PATTERN = /\b([a-z][a-z0-9_]*_phase)\b\s*(?:==|in)(?![a-z0-9_])/
PHASE_DECLARATION_PATTERN = /\A\s*([a-z][a-z0-9_]*_phase)\s+in\s+\[([^\]]*)\]\s*\z/
def phase_literals(strings, variable)
  escaped = Regexp.escape(variable)
  strings.flat_map do |value|
    value.scan(/#{escaped}\s*==\s*'([a-z0-9_]+)'/).flatten +
      value.scan(/#{escaped}\s*in\s*\[([^\]]*)\]/).flatten
           .flat_map { |list| list.scan(/'([a-z0-9_]+)'/).flatten }
  end.uniq
end

phase_task_files = Dir[File.join(ROOT, "roles", "*")].sort.flat_map do |role_root|
  recursive_role_yaml_paths(File.join(role_root, "tasks"), failures)
end
# Floored separately (handlers could satisfy the other floor); sized against the
# mutation sandbox.
check_floor(failures, phase_task_files.length, 25,
            "the phase-gate check found too few role task files")
declared_phases = {}
phase_task_files.each do |path|
  relative_path = path.delete_prefix("#{ROOT}/")
  document = YAML.safe_load_file(path, aliases: true)
  next unless document.is_a?(Array) && document.first.is_a?(Hash)

  tasks = flatten_tasks(document)
  gated_variables = task_strings(tasks)
                    .flat_map { |value| value.scan(PHASE_GATE_PATTERN).flatten }.uniq.sort
  next if gated_variables.empty?

  opening = document.first
  opens_with_assert = opening.key?("ansible.builtin.assert") && !opening.key?("when")
  check(failures, opens_with_assert,
        "#{relative_path}: gates tasks on #{gated_variables.join(', ')} but does not open with " \
        "an unconditional assert; an unrecognised phase would skip the whole file silently")
  declarations = {}
  Array(opening.dig("ansible.builtin.assert", "that")).each do |condition|
    match = PHASE_DECLARATION_PATTERN.match(condition.to_s)
    declarations[match[1]] = match[2].scan(/'([a-z0-9_]+)'/).flatten.sort if match
  end
  body_strings = task_strings(tasks.drop(1))
  gated_variables.each do |variable|
    unless declarations.key?(variable)
      check(failures, false,
            "#{relative_path}: opening assert does not name the phases #{variable} implements")
      next
    end

    unnamed = phase_literals(body_strings, variable) - declarations[variable]
    check(failures, unnamed.empty?,
          "#{relative_path}: gates on #{variable} #{unnamed.sort.join(', ')} without declaring " \
          "#{unnamed.length == 1 ? 'it' : 'them'} in the opening assert")
  end
  declared_phases[relative_path] = declarations
end
passed_phases = Hash.new { |store, key| store[key] = {} }
phase_task_files.each do |path|
  relative_path = path.delete_prefix("#{ROOT}/")
  flatten_tasks(YAML.safe_load_file(path, aliases: true)).each do |task|
    included = task["ansible.builtin.include_tasks"]
    file_name = included.is_a?(Hash) ? included["file"] : included
    variables = task["vars"]
    next unless file_name.is_a?(String) && variables.is_a?(Hash)

    target_path = File.expand_path(File.join(File.dirname(path), file_name))
    # A missing file is reported elsewhere; the reduced fixture carries callers
    # without the files they include.
    next unless File.file?(target_path)

    target = target_path.delete_prefix("#{ROOT}/")
    variables.each do |name, value|
      next unless name.to_s.end_with?("_phase")

      declaration = declared_phases.dig(target, name.to_s)
      check(failures, !declaration.nil? && declaration.include?(value.to_s),
            "#{relative_path}: \"#{task['name']}\" includes #{file_name} with " \
            "#{name}: #{value}, which that file does not declare it implements")
      (passed_phases[target][name.to_s] ||= []) << value.to_s if declaration
    end
  end
end
# A role's own tasks/main.yml reached by include_role counts as called: its
# argument spec's required `choices` enforce the phases on every caller. This
# applies to the entrypoint only.
declared_phases.each do |relative_path, declarations|
  role_name = relative_path.split("/")[1].to_s
  entrypoint = relative_path == "roles/#{role_name}/tasks/main.yml"
  spec_path = File.join(ROOT, "roles", role_name, "meta", "argument_specs.yml")
  spec_options = if entrypoint && File.file?(spec_path)
                   YAML.safe_load_file(spec_path).dig("argument_specs", "main", "options") || {}
                 else
                   {}
                 end
  declarations.each do |variable, phases|
    reached = (passed_phases.dig(relative_path, variable) || []).uniq.sort
    option = spec_options[variable]
    enforced_by_argument_spec = option.is_a?(Hash) && option["required"] == true &&
                                Array(option["choices"]).map(&:to_s).sort == phases
    check(failures, reached == phases || enforced_by_argument_spec,
          "#{relative_path}: declares #{variable} phases #{phases.join(', ')} but its callers " \
          "pass #{reached.empty? ? 'none' : reached.join(', ')}, and " \
          "roles/#{role_name}/meta/argument_specs.yml does not declare #{variable} as a required " \
          "option whose choices are exactly those phases")
  end
end

# The controller runs inside the tree it inspects, so it must take both roots
# from the launcher's environment, never from $0, dirname or BASH_SOURCE.
controller_program = File.join(ROOT, "tests", "integration_controller.sh")
controller_source = File.file?(controller_program) ? File.read(controller_program) : nil
check(failures, !controller_source.nil?,
      "tests/integration_controller.sh: the integration controller program is missing")
unless controller_source.nil?
  self_relative = controller_source.lines.each_with_index.filter_map do |line, index|
    next if line.lstrip.start_with?("#")
    next unless line.match?(/\$\{?0\b|\bdirname\b|\bBASH_SOURCE\b/)

    "#{index + 1}: #{line.strip}"
  end
  check(failures, self_relative.empty?,
        "tests/integration_controller.sh: resolves a path from where the file " \
        "sits rather than from CONTROLLER_REPO_DIR or CONTROLLER_SANDBOX at " \
        "#{self_relative.join('; ')}")

  # The shellcheck exclusion list is empty and pinned: unquoted expansions once
  # hid real bugs (SC2070 ran the nightly over 88 of 1495 tasks; #640). A
  # deliberate site carries its own per-line disable.
  manifest = File.read(File.join(ROOT, "tests", "validate-policy.sh"))
  controller_check = manifest.lines.map(&:chomp).find do |line|
    line.end_with?(" tests/integration_controller.sh")
  end
  check(failures, controller_check ==
        "shellcheck --shell=sh -x tests/integration_controller.sh",
        "tests/validate-policy.sh: the integration controller must be " \
        "shellchecked with no --exclude at all, not " \
        "#{controller_check.inspect}")
end

# The controller must not go back to being text inside a shell string: that is
# the shape that made it unreachable by sh -n and shellcheck in the first place.
launcher_source = File.read(File.join(ROOT, "tests", "integration.sh"))
check(failures, !launcher_source.include?(%(sh -eu -c ")),
      "tests/integration.sh: the controller is a program again pasted into an " \
      "sh -c argument, where no syntax check or linter can read it")

# Every top-level def as raw source text, as a list so a redefinition is visible.
# Comments above a def belong to no definition.
def python_top_level_definitions(path)
  lines = File.readlines(path, chomp: true)
  definitions = Hash.new { |hash, key| hash[key] = [] }
  lines.each_index do |index|
    name = lines[index][/\Adef ([A-Za-z_][A-Za-z_0-9]*)\(/, 1]
    next if name.nil?

    body = [lines[index]]
    # A top-level definition ends at the next line that is neither blank nor
    # indented, which is the next top-level statement.
    lines[(index + 1)..].each do |line|
      break if !line.empty? && !line.start_with?(" ", "\t")

      body << line
    end
    definitions[name] << body.join("\n").rstrip
  end
  # No default: an absent name must raise, not compare [nil, nil] as agreement.
  definitions.default_proc = nil
  definitions
end

# A Python line with string literals removed, so brackets and `#` inside strings
# are not counted. Triple-quoted strings are unsupported (none at module level).
PYTHON_STRING_LITERAL = /
  (?:[rRbBfFuU]{0,2})
  (?: "(?:\\.|[^"\\])*" | '(?:\\.|[^'\\])*' )
/x
def python_bracket_delta(line)
  code = line.gsub(PYTHON_STRING_LITERAL, "").sub(/#.*\z/, "")
  code.count("([{") - code.count(")]}")
end

# Every top-level constant assignment as raw source text, as a list so a
# reassignment is visible. Extent is bracket depth, not indentation.
def python_top_level_constants(path)
  lines = File.readlines(path, chomp: true)
  constants = Hash.new { |hash, key| hash[key] = [] }
  index = 0
  while index < lines.length
    name = lines[index][/\A(_?[A-Z][A-Z_0-9]*)\s*=(?!=)/, 1]
    if name.nil?
      index += 1
      next
    end

    body = [lines[index]]
    depth = python_bracket_delta(lines[index])
    while (depth.positive? || body.last.end_with?("\\")) && index + 1 < lines.length
      index += 1
      body << lines[index]
      depth += python_bracket_delta(lines[index])
    end
    constants[name] << body.join("\n").rstrip
    index += 1
  end
  # Same reason as python_top_level_definitions: [nil, nil].uniq.length == 1, so
  # an absent name would read as two files agreeing rather than raising.
  constants.default_proc = nil
  constants
end

# scripts/production_auto_deploy.py and scripts/image_prune.py stay single files
# (each is installed by one copy task); their shared helpers are compared byte for
# byte so they cannot drift again (#354, #423). alert_relay.py's html_escape is a
# relative, deliberately outside this glob.
duplicated_scripts = Dir.glob(File.join(ROOT, "scripts/*.py")).sort
check_floor(failures, duplicated_scripts.length, 2, "scripts/*.py programs")
script_definitions = duplicated_scripts.to_h do |path|
  [File.basename(path), python_top_level_definitions(path)]
end

# The fewest lines each definition can honestly be, per name: an extractor that
# stopped at the first blank line would yield two.
duplicated_helper_floors = {
  "_write_private" => 20,
  "_record_lock_holder" => 12,
  "_timestamp" => 6,
  "html_escape" => 8,
  "fit_message" => 8,
  "pushover_verdict" => 8,
  # Seven since #558 gave every message one shape: a lead line, labelled details
  # and a closing line, which the details give way inside.
  "compose_message" => 8,
  # Converged in #658 from near-copies one literal apart.
  "rotate_logs" => 16,
  "run_log" => 14,
  "format_duration" => 10,
}
check_floor(failures, duplicated_helper_floors.length, 10,
            "helpers held identical across scripts/*.py")

# Retired by #558 and refused by name: the derived stanzas need both scripts to
# define a name, so a leftover in one would pass.
RETIRED_SCRIPT_NAMES = %w[markdown_escape MARKDOWN_PATTERN].freeze
duplicated_scripts.each do |path|
  retired = (python_top_level_definitions(path).keys + python_top_level_constants(path).keys) &
            RETIRED_SCRIPT_NAMES
  check(failures, retired.empty?,
        "scripts/#{File.basename(path)} still defines #{retired.inspect}, retired when both " \
        "scripts moved from Markdown to Pushover's HTML (#558); html_escape is the " \
        "escape now, and a leftover copy is one nothing else compares")
end

duplicated_helper_floors.each do |helper, floor|
  sources = script_definitions.select { |_, definitions| definitions.key?(helper) }
  check_floor(failures, sources.length, 2, "scripts defining #{helper}")
  sources.each do |script, definitions|
    # Only the first definition is compared, so a second one further down the
    # file would be a copy nothing reads.
    check(failures, definitions[helper].length == 1,
          "scripts/#{script}: defines #{helper} #{definitions[helper].length} times, " \
          "and only the first is compared")
    body = definitions[helper].first
    # Too-short and run-on extractions would each compare equal to themselves.
    check(failures, body.lines.length >= floor,
          "scripts/#{script}: #{helper} extracted as #{body.lines.length} lines, " \
          "fewer than the #{floor} it must be -- the extractor stopped early")
    check(failures, body.scan(/^def /).length == 1,
          "scripts/#{script}: the #{helper} extraction ran past the definition " \
          "into #{body.scan(/^def .*/).drop(1).inspect}")
  end
  bodies = sources.values.map { |definitions| definitions[helper].first }
  check(failures, bodies.uniq.length == 1,
        "every script must define #{helper} identically, and " \
        "#{sources.keys.inspect} do not. These are verbatim copies that cannot " \
        "share a module; when _write_private was allowed to drift, one copy " \
        "fsynced and never repaired the mode while the other repaired the mode " \
        "and never fsynced, so each carried the bug the other had fixed (#354)")
end

script_definitions.each do |script, definitions|
  next unless definitions.key?("_write_private")

  check(failures, definitions["_write_private"].first.include?("os.replace("),
        "scripts/#{script}: _write_private must replace the target rather than " \
        "truncate it in place; a crash in that window loses the record (#401)")
end

# The reverse direction, derived: a name both scripts define whose bodies already
# agree is a fresh duplicate and must be listed above (#423).
shared_definition_names = script_definitions.values.map { |definitions| definitions.keys.to_set }.reduce(:&)
check_floor(failures, shared_definition_names.length, 4,
            "top-level names both scripts/*.py programs define")
unlisted_identical = shared_definition_names.sort.reject do |helper|
  duplicated_helper_floors.key?(helper)
end.select do |helper|
  script_definitions.values.map { |definitions| definitions[helper].first }.uniq.length == 1
end
check(failures, unlisted_identical.empty?,
      "#{unlisted_identical.inspect} are defined identically in every " \
      "scripts/*.py program but are not listed in duplicated_helper_floors, so " \
      "nothing would notice them drifting apart. A verbatim copy is identical " \
      "only until someone edits one side; name it there, with a floor")

# --- the same rule one level down, and one file wider (#515) -----------------
# Shared constants are data and get pinned too, and services/dozzle/alert_relay.py
# is a third copy site the scripts/*.py glob cannot see.
DUPLICATION_SITES = (duplicated_scripts + [File.join(ROOT, "services/dozzle/alert_relay.py")])
                    .map { |path| path.delete_prefix("#{ROOT}/") }.uniq.sort
check_floor(failures, DUPLICATION_SITES.length, 3, "single-file programs sharing copied helpers")

site_definitions = DUPLICATION_SITES.to_h do |relative|
  [relative, python_top_level_definitions(File.join(ROOT, relative))]
end
site_constants = DUPLICATION_SITES.to_h do |relative|
  constants = python_top_level_constants(File.join(ROOT, relative))
  # An extractor that matched nothing would compare empty to empty and report
  # every property below as holding. The smallest of the three carries 14.
  check_floor(failures, constants.length, 10, "#{relative}: top-level constants")
  [relative, constants]
end

# Which sites hold each constant, exact in both directions, and its exact line count.
duplicated_constant_sites = {
  # The Pushover caps are pinned at all three sites; the link caps only where a
  # link is sent.
  "MAX_ESCAPED_FIELD_CHARACTERS" => {
    "sites" => %w[scripts/image_prune.py scripts/production_auto_deploy.py services/dozzle/alert_relay.py],
    "lines" => 1
  },
  "MAX_MESSAGE_CHARACTERS" => {
    "sites" => %w[scripts/image_prune.py scripts/production_auto_deploy.py services/dozzle/alert_relay.py],
    "lines" => 1
  },
  "MAX_TITLE_CHARACTERS" => {
    "sites" => %w[scripts/image_prune.py scripts/production_auto_deploy.py services/dozzle/alert_relay.py],
    "lines" => 1
  },
  "MAX_URL_CHARACTERS" => {
    "sites" => %w[scripts/production_auto_deploy.py services/dozzle/alert_relay.py],
    "lines" => 1
  },
  "MAX_URL_TITLE_CHARACTERS" => {
    "sites" => %w[scripts/production_auto_deploy.py services/dozzle/alert_relay.py],
    "lines" => 1
  },
  # Configuration keys load_config reads as "cannot publish" rather than refusing
  # (#327): the union of every application either script sends to.
  "_PUSHOVER_FIELDS" => {
    "sites" => %w[scripts/image_prune.py scripts/production_auto_deploy.py],
    "lines" => 3
  },
  "NOTIFICATION_TIMEOUT_SECONDS" => {
    "sites" => %w[scripts/image_prune.py scripts/production_auto_deploy.py],
    "lines" => 1
  },
  # The whole palette at all three sites, since it is one palette (#558).
  "COLOR_GREEN" => {
    "sites" => %w[scripts/image_prune.py scripts/production_auto_deploy.py services/dozzle/alert_relay.py],
    "lines" => 1
  },
  "COLOR_RED" => {
    "sites" => %w[scripts/image_prune.py scripts/production_auto_deploy.py services/dozzle/alert_relay.py],
    "lines" => 1
  },
  "COLOR_AMBER" => {
    "sites" => %w[scripts/image_prune.py scripts/production_auto_deploy.py services/dozzle/alert_relay.py],
    "lines" => 1
  },
  "COLOR_GREY" => {
    "sites" => %w[scripts/image_prune.py scripts/production_auto_deploy.py services/dozzle/alert_relay.py],
    "lines" => 1
  }
}
check_floor(failures, duplicated_constant_sites.length, 11,
            "module-level constants held identical across the copy sites")

duplicated_constant_sites.each do |constant, expectation|
  sources = site_constants.select { |_relative, constants| constants.key?(constant) }
  check(failures, sources.keys.sort == expectation.fetch("sites").sort,
        "#{constant} is defined in #{sources.keys.sort.inspect}, and this table says " \
        "#{expectation.fetch('sites').sort.inspect}. A copy that disappeared is as much a " \
        "change to this contract as one that diverged; say which happened here")
  sources.each do |relative, constants|
    # Only the first assignment is compared, so a second one further down the
    # file would be a value nothing reads.
    check(failures, constants[constant].length == 1,
          "#{relative}: assigns #{constant} #{constants[constant].length} times, " \
          "and only the first is compared")
    body = constants[constant].first
    check(failures, body.lines.length == expectation.fetch("lines"),
          "#{relative}: #{constant} extracted as #{body.lines.length} lines rather than the " \
          "#{expectation.fetch('lines')} this table states -- the extraction stopped early or " \
          "ran past the assignment, and either way the comparison below is not reading the " \
          "whole value")
    assignments = body.lines.count { |line| line.match?(/\A_?[A-Z][A-Z_0-9]*\s*=(?!=)/) }
    check(failures, assignments == 1,
          "#{relative}: the #{constant} extraction covers #{assignments} top-level " \
          "assignments, so it ran past the one it is supposed to compare")
  end
  bodies = sources.values.map { |constants| constants[constant].first }
  check(failures, bodies.uniq.length == 1,
        "every copy site must spell #{constant} identically, and " \
        "#{sources.keys.sort.inspect} do not. This is the input to a helper the check " \
        "above already pins: html_escape can be byte-identical in both scripts while one " \
        "of them bounds its result to a different MAX_ESCAPED_FIELD_CHARACTERS, and that " \
        "reads as the copies agreeing (#515)")
end

# The reverse direction over the three sites: any byte-identical PAIR must be
# pinned, so two agreeing copies are not excused by a third differing on purpose.
site_names = DUPLICATION_SITES.to_h do |relative|
  [relative, site_definitions.fetch(relative).keys.to_set + site_constants.fetch(relative).keys.to_set]
end
shared_across_sites = site_names.values.combination(2).map { |left, right| left & right }
                                .reduce(Set.new, :|).sort
check_floor(failures, shared_across_sites.length, 15,
            "top-level names shared by at least two of the copy sites")
# A separate floor on the relay's own participation, since most names come from
# the two scripts alone.
relay_site = "services/dozzle/alert_relay.py"
check(failures, DUPLICATION_SITES.include?(relay_site),
      "#{relay_site} must be one of the copy sites: CLAUDE.md names it as the third place these " \
      "helpers are duplicated, and the reduce(:&) stanza above cannot see it")
relay_shared = (site_names[relay_site] || Set.new).select do |name|
  DUPLICATION_SITES.any? { |relative| relative != relay_site && site_names.fetch(relative).include?(name) }
end
check_floor(failures, relay_shared.length, 16,
            "top-level names #{relay_site} shares with a scripts/*.py program")
# The relay's verbatim copies of the message helpers (#558), which the pairwise
# stanza skips as listed names.
RELAY_VERBATIM_HELPERS = %w[fit_message compose_message].freeze
RELAY_VERBATIM_HELPERS.each do |helper|
  relay_bodies = site_definitions.fetch(relay_site, {}).fetch(helper, [])
  script_body = script_definitions.fetch("production_auto_deploy.py", {}).fetch(helper, []).first
  check(failures, relay_bodies.length == 1,
        "#{relay_site} must define #{helper} exactly once, and defines it " \
        "#{relay_bodies.length} times: it fits its messages with the scripts' own helper")
  check(failures, !script_body.nil? && relay_bodies.first == script_body,
        "#{relay_site} must define #{helper} identically to scripts/production_auto_deploy.py. " \
        "The relay cannot import it -- it runs inside a container -- so the copy is verbatim, " \
        "and a copy that drifts fits one program's messages differently from the other's (#354)")
end

listed_by_name = duplicated_helper_floors.keys.to_set | duplicated_constant_sites.keys.to_set
unlisted_pairwise = shared_across_sites.reject { |name| listed_by_name.include?(name) }.select do |name|
  bodies = DUPLICATION_SITES.flat_map do |relative|
    [site_definitions.fetch(relative), site_constants.fetch(relative)]
      .filter_map { |table| table[name].first if table.key?(name) }
  end
  # Comparing lengths: a third differing site must not excuse an identical pair.
  bodies.length != bodies.uniq.length
end
check(failures, unlisted_pairwise.empty?,
      "#{unlisted_pairwise.inspect} are spelled byte-identically in two or more of " \
      "#{DUPLICATION_SITES.inspect} but are listed in neither duplicated_helper_floors nor " \
      "duplicated_constant_sites, so nothing would notice them drifting apart. These files " \
      "cannot share a module -- each is installed as exactly one file, and the relay's copy " \
      "lives inside a container -- so a verbatim copy is identical only until someone edits " \
      "one side. Name it in the table that fits, with its floor or its line count")

report(failures, "policy: all properties hold", "policy violation(s)")
