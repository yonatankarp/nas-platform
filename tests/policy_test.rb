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

# The controller pin is authored once, in controller-requirements.txt: every CI
# job that needs the toolchain installs from it, and tests/ci/workflow_test.rb
# holds the two restatements that cannot be a pip requirement -- the sandbox's
# image tag and the Beszel telemetry test -- against it. A guide that restates
# the version is a further mirror that nothing bumps, so a
# reader following it builds a controller CI never validated against and then
# fails ansible-lint for reasons the guide cannot explain.
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
# CLAUDE.md is here because it was the one place the retired declaration
# survived: it named the retired service as an integration lane and as a Compose
# allowlist exception long after both were gone, and the guard below did not read
# it (issue #276).
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

# tests/contracts/beszel-runtime.rb, not the wrapper: #147 moved the contract's
# runtime body out of a `<<'RUBY'` heredoc into that file, and all three subjects
# below -- the captured message ID, the anti-replay comparison and the absence of
# a timestamp-based poll -- travelled with it. The negated conjunct matters most
# here: "iso8601" matches nothing today, which makes it satisfied rather than
# vacuous, and left reading the 54-line wrapper it could never match again.
beszel_contract_path = File.join(ROOT, "tests", "contracts", "beszel-runtime.rb")
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
# The per-service port exports are derived from tests/mac/lib.sh's
# MAC_SERVICE_PORT_ORDER rather than written out one line per service, so what
# this file can assert is that the roster names the service and that the runner
# runs the derivation. tests/policy_mac_test.rb executes that derivation and
# checks the variable each service actually lands in.
mac_lib_roster_path = File.join(ROOT, "tests", "mac", "lib.sh")
mac_lib_roster = if File.file?(mac_lib_roster_path)
                   File.read(mac_lib_roster_path)[/^MAC_SERVICE_PORT_ORDER='([^']*)'/m, 1].to_s.split
                 else
                   []
                 end
#
# The failure diagnostics are derived too, from a second roster, and this check
# used to read their Compose projects as eight literal `"$project_name-<name>"`
# strings. That is what let them fall eight services behind: arr, downloaders,
# bindery, kapowarr, pinchflat, trailarr and seerr were all deployed by the lane
# and none of them appeared in a failed run's evidence, and the literals here
# said nothing about it because four of the eight were still present. So the
# roster is now tests/sandbox_cleanup.sh's, which cleanup already holds current,
# and what is asserted is the shape that cannot go stale: the namespace prefix is
# applied to a roster rather than to a list, that roster is the shared one, and
# the sample services are in both it and the port roster.
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
        %w[beszel ntfy dozzle audiobookshelf nextcloud].all? do |name|
          mac_lib_roster.include?(name) && mac_cleanup_projects.include?(name)
        end,
      "Mac runner must export dynamic project/port facts and isolate every Compose project")

PLATFORM_INVENTORIES = {
  "local.yml" => ["nas_hosts", "nas", "local", "nas"],
  "remote.yml" => ["nas_hosts", "nas", "ssh", "nas"],
  "mac.yml" => ["mac_hosts", "mac", "local", "mac"]
}.freeze
# Each transport coordinate reads one environment variable, and only that one.
# The pairing is the point: an undef() hint is a message to an operator who has
# a shell with the wrong variable exported, so a hint naming the other
# coordinate's variable refuses at exactly the right moment and then sends that
# operator to export something that will not fix it.
TRANSPORT_COORDINATE_SOURCES = {
  "ansible_host" => "PLATFORM_NAS_ADDRESS",
  "ansible_user" => "PLATFORM_NAS_USER"
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
  # The other half of the same argument, for the other audience. An ssh
  # inventory states where it connects and who it connects as, and Ansible has a
  # plausible default for each: an empty ansible_host becomes the inventory
  # hostname -- the literal `nas` -- and an empty ansible_user becomes the local
  # login name. lookup('env') yields the empty string rather than an undefined
  # value, so a bare lookup reaches both defaults silently. undef() is what makes
  # the unset case fail while the connection keyword is templated, before the
  # first packet. Presence is required rather than tolerated, because deleting
  # the keyword outright reinstates the same fallback that the guard exists to
  # refuse; a local connection has no transport to state and must carry neither.
  TRANSPORT_COORDINATE_SOURCES.each do |coordinate, variable|
    coordinate_source = host.is_a?(Hash) ? host[coordinate] : nil
    if connection == "ssh"
      check(failures, coordinate_source.is_a?(String) && coordinate_source.include?("undef("),
            "inventory/#{inventory_name} must define #{coordinate} and fail on an " \
            "unset environment value with undef(), not fall back to Ansible's default")
      # Shape is not meaning: the check above is satisfied by any undef() at all,
      # including one whose hint names the other coordinate's variable, or one
      # with no hint to name anything. The refusal is only useful if it tells the
      # operator which variable to export, so the expression must read this
      # coordinate's variable, name that same variable in its hint, and mention
      # no other -- a hint naming both is a hint that names neither.
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

# These four are handed whole to a Python filter or posted verbatim to a service
# API from a task running under no_log: true, so an undeclared shape surfaces as
# a redacted AnsibleFilterError rather than as a named option. The nested
# options are what makes the declaration a shape and not just a container type;
# tests/filter_input_argument_spec_test.py proves they still refuse a malformed
# element.
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

# The ceilings and the budget are one policy, not two. Every managed container
# runs on the *same* cpuset -- platform_container_cpu_budget logical CPUs of the
# host, rendered as PLATFORM_CONTAINER_CPUSET -- and `cpus` is a per-container
# ceiling on that shared set, not a reservation carved out of it. The ceilings
# are therefore oversubscribed on purpose, sized for a workload that is idle
# almost all the time, and their total is not a quantity the platform has to fit
# anything into. inventory/group_vars/nas_hosts/main.yml records that model
# beside the budget; reading the total as a budget is the mistake this check
# exists to forestall.
#
# What does mean something is a single ceiling wider than the set it runs on.
# Docker clamps such a container to the cpuset anyway, so the number constrains
# nothing while reading as a deliberate limit -- it is a ceiling that lies. The
# NAS budget is the one compared against because these ceilings are written for
# the production set; a Mac host declares 0, meaning "whatever Docker reports",
# and pins nothing.
#
# The relation is `<=`, and the four containers sitting at exactly the budget are
# the point rather than an exemption: whichever one is busy may have the whole
# shared set. `<` would reject them, so it is not the stricter form of this rule
# but a different rule about how much of an idle machine a container may claim.
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

# config/media-acquisition.yml restates every acquisition ceiling, and it is not
# a fixture that could simply be deleted: roles/deployment_bundle ships it into
# the release, so the catalog an operator reads on the NAS is this file. It has
# to stay authored there, which leaves the two copies to be related rather than
# merged -- and until now nothing related them. The checks above pin Compose to
# tests/expected/<service>.yml and tests/expected to the CPU budget; the catalog
# was pinned only to a literal in tests/media_acquisition_foundation_test.rb, so
# a ceiling changed in Compose and in tests/expected left the catalog stale and
# silent.
#
# tests/expected/<service>.yml is the one home. This states the relation the
# catalog owes it, by name, so a drift says which container and which two files
# disagree instead of surfacing as a whole-structure mismatch.
#
# The container sets are compared in both directions first. A per-key loop over
# either side alone goes quiet exactly where a key was dropped, which is the
# drift most likely to be a mistake rather than an edit.
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

# README states the size of the catalog in English, and both numbers are a
# property of services/manifest.yml rather than of the prose. Derive them here so
# that promoting a service fails with the two words the sentence has to carry,
# instead of leaving the catalog paragraph a release behind and contradicting
# itself further down the same file -- which is exactly what Pinchflat's
# promotion did.
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
  # The catalog can hold exactly one of something, and "one projects" is a
  # sentence no reviewer would let through, so the noun agrees with the count.
  # It can also hold none, which English writes as "no", not "zero": Phase 4
  # promoted the last planned acquisition project and the sentence has to keep
  # reading like a sentence after it.
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

# Digest pinning with a human-readable version tag, so an update bot can propose
# a bump and a reader can tell what is deployed. The approved version is whatever
# compose.yml declares; pinning a copy of it here would mean every image update
# had to edit this file too, which is what a property check exists to avoid.
IMAGE = %r{\A\S+:[^@\s]+@sha256:[0-9a-f]{64}\z}

# Platform Compose fragments. The log rotation block and the health-check timing
# default are platform policy rather than a per-stack choice, and Compose
# resolves a YAML anchor only inside the file that declares it, so each stack
# carries its own copy of both.
#
# Sharing one file across stacks is possible -- `extends:` predates the Compose
# 2.18 floor nas_compose_minimum states, and Compose 5 resolves it -- and was
# deliberately not taken. Every per-container property checked below is read
# straight out of one parsed file today, for free, because Psych resolves the
# anchors; seeing through `extends:` would mean reimplementing Compose's merge
# here first, and the whole guard would then be only as good as that
# reimplementation. On the target the trade is worse still: a platform override
# that has not been deployed yet degrades to the canonical file, while a shared
# file that has not been deployed yet is a parse error for every stack at once.
#
# So the copies stay, and they are pinned equal here instead. A fragment edited
# in one stack fails by name rather than drifting away from the other eleven.
PLATFORM_LOGGING = {
  "driver" => "json-file",
  "options" => { "max-size" => "10m", "max-file" => "3" }
}.freeze

# The tuple eight of the platform's twenty-four timed health checks already
# carried, which is what makes it the default rather than a new opinion. A
# container needing different timing overrides only the fields it changes, so a
# deviation reads as a deviation instead of as another hand-written tuple.
PLATFORM_HEALTHCHECK_DEFAULTS = {
  "interval" => "30s",
  "timeout" => "10s",
  "retries" => 5,
  "start_period" => "60s"
}.freeze

# The stacks allowed to declare no platform fragment, and nothing else. immich
# is the one entry: three of its four containers run the health check their
# image ships and the fourth supplies only a test, so the platform's interval,
# timeout, retries and start_period would replace an image's own timing rather
# than share a default. Its compose.yml records the same reason at the top, and
# that comment is the thing this list points at -- an exemption whose reason
# lives only here is a list, not a decision. x-logging carries no entry: every
# stack logs the same way, and a stack that stops is a stack whose logs are
# unbounded on a NAS with one disk pool.
FRAGMENT_EXEMPTIONS = {
  "x-healthcheck-defaults" => %w[immich].freeze
}.freeze

# What a health-check command has to do to be one. Timing says how often the
# probe runs and presence says there is a probe; neither says the probe can
# report the service broken, and unpackerr's could not: `kill -0 1` asks whether
# PID 1 exists, PID 1 is the container's own entrypoint, and a container whose
# PID 1 has exited is one Docker has stopped probing. It was a health check by
# every structural measure above and by no useful one. So require the command to
# reach the service -- an HTTP or HTTPS URL, a TCP connection, a readiness
# client, or the image's own health subcommand -- rather than to observe the
# process table it is running inside. Stated as what
# a probe must contain and not as a list of no-ops, because the next no-op is
# never the one a denylist names.
HEALTHCHECK_PROBE = %r{https?://|/dev/tcp/|\bping\b|isready|\bhealth(check)?\b}

# Images whose runtime picks its own memory ceiling out of whatever it can see,
# rather than out of anything an operator wrote. A JVM has done this since JDK
# 10: it reads its cgroup limit and takes MaxRAMPercentage of it, defaulting to
# 25%, and where there is no limit it falls back to *host* physical memory. So
# paperless_tika reported MaxHeapSize=4135583744 {ergonomic} on the NAS,
# measured 2026-09-08 -- a quarter of 16 GB, chosen by nobody -- and the 4 GB to
# 16 GB upgrade quadrupled it silently, because no file here names either
# figure. A limit is therefore not only a containment ceiling for these images;
# it is the only thing that makes their heap a decision.
#
# The list is stated rather than derived because a Compose file does not say
# what runtime is inside an image and nothing here can find out. That is this
# check's honest limit: a third self-sizing image can land unlisted and the
# check stays green. EXPECTED_SELF_SIZING_CONTAINERS keeps the entries that are
# here from going quiet; nothing can guard the omission itself, for the same
# reason BASE_FIXTURE_PATHS cannot derive its own contents.
#
# Matched against the repository half of the image reference, so the version
# stays written only in the tag and digest.
MEMORY_SELF_SIZING_IMAGES = ["docker.io/apache/tika"].freeze

# Which containers that list is expected to reach, exactly and in both
# directions. A one-directional sweep passes when the tree loses Tika: the
# subject list empties, every remaining assertion holds, and the check reports
# success having examined nothing.
EXPECTED_SELF_SIZING_CONTAINERS = { "paperless-ngx" => ["tika"] }.freeze

# Environment keys a JVM heap gets written in. ES_JAVA_OPTS is Elasticsearch's
# own name for it; JAVA_TOOL_OPTIONS is the one any JVM honours however the
# image launches it.
HEAP_DECLARATION_KEYS = %w[JAVA_TOOL_OPTIONS JAVA_OPTS ES_JAVA_OPTS].freeze

BYTE_SUFFIXES = { "b" => 1, "k" => 1024, "kb" => 1024, "m" => 1024**2, "mb" => 1024**2,
                  "g" => 1024**3, "gb" => 1024**3 }.freeze

# Compose accepts 2g, 2G, 2gb, 2048m and a bare byte count; -Xmx accepts the
# same shapes without the two-letter forms. An unreadable form raises rather
# than returning nil, because nil would read as "no limit declared" and turn a
# gap in this parser into a check that quietly stopped applying.
def parse_bytes(value, what)
  text = value.to_s.strip.downcase
  return Integer(text, 10) if text.match?(/\A\d+\z/)

  match = text.match(/\A(\d+(?:\.\d+)?)(b|kb?|mb?|gb?)\z/)
  raise ArgumentError, "#{what}: cannot read #{value.inspect} as a byte quantity" if match.nil?

  (match[1].to_f * BYTE_SUFFIXES.fetch(match[2])).round
end

# The heap a container's environment asks for, in bytes, given the limit it runs
# under. -Xmx states it outright; MaxRAMPercentage states it as a share of the
# limit and so means nothing until a limit exists. nil when no heap is declared.
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

# The keys every long-running container on the platform shares. A stack may add
# to its own fragment -- networks, or a shutdown window every consumer genuinely
# wants -- but never disagree about these four. stop_grace_period is deliberately
# not among them: absent means Docker's 10s, and the platform runs 10s, 30s, 1m
# and 2m on purpose, so a shared default would flatten that silently.
PLATFORM_SERVICE_DEFAULTS = {
  "cpuset" => "${PLATFORM_CONTAINER_CPUSET:?}",
  "security_opt" => ["no-new-privileges:true"],
  "restart" => "unless-stopped",
  "logging" => PLATFORM_LOGGING
}.freeze

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

# How many library/staging pairs the same-mount import check below found. It
# derives its own subject list, so the count is asserted after the sweep.
import_pairs = 0

# Which containers the self-sizing image list actually reached. Collected during
# the sweep and compared against EXPECTED_SELF_SIZING_CONTAINERS afterwards, in
# both directions, because the failure this guards against is the subject list
# emptying rather than a subject misbehaving.
self_sizing_containers = Hash.new { |hash, key| hash[key] = [] }

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
    # Presence first, then equality. Skipping a stack that declares no fragment
    # pinned only the copies that already existed: bindery wrote the platform
    # tuple inline into its one health check and its copy was held to nothing,
    # which is a fragment the pin cannot see rather than a stack that chose not
    # to have one. Absence is now a decision the exemption list has to record.
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

    # Two obligations, and only the first has a subject in the tree today.
    #
    # A self-sizing image must carry a limit, because without one its runtime
    # reads host memory instead. Recorded per container in
    # self_sizing_containers below and compared against the stated expectation
    # after the sweep, so losing the subject fails instead of passing quietly.
    image_repository = spec["image"].to_s.split("@").first.to_s.rpartition(":").first
    if MEMORY_SELF_SIZING_IMAGES.include?(image_repository)
      self_sizing_containers[name] << container
      check(failures, spec.key?("mem_limit"),
            "#{label}: an image that sizes its own memory from what it can see must " \
            "declare mem_limit, or its runtime reads the host's RAM instead")
    end

    # And a declared heap must leave room beside it. Half is the boundary
    # because off-heap -- metaspace, code cache, thread stacks, direct buffers --
    # runs to roughly the heap again, so a heap above half the limit is a
    # container arranged to be killed. Stated as an inequality and not a ratio
    # so a deliberately generous limit stays legal.
    #
    # Nothing declares a heap here yet: Tika satisfies the rule above with a
    # limit alone and lets the JVM derive the heap from it, and Elasticsearch is
    # the first that must state one, because it fails a bootstrap check unless
    # -Xms equals -Xmx. Zero subjects is correct rather than a gap, so no floor
    # is asserted on this one. What proves it works is the pair of mutations in
    # tests/policy_manifest_test.rb that plant a heap on Tika, one without a
    # limit and one above half of it; without both, a version of this check
    # that skips whenever mem_limit is absent would pass unnoticed.
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
    # The other half of the same boundary. Refusing `privileged` says the
    # container starts without extra power; no_new_privs says it cannot acquire
    # any afterwards by executing a setuid binary. Every image on the platform
    # can honour it: the linuxserver.io, gosu and Postgres entrypoints reach
    # their service accounts with setuid(2) as root, which no_new_privs does not
    # restrict, and Gotenberg launches Chromium with --no-sandbox rather than
    # through the setuid sandbox helper. An image that genuinely needed the
    # escalation would belong in a stated allowlist here, with its reason, and
    # there is none — so the property holds for every container without
    # exception.
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

    # And the probe has to be able to say no. Read the command whatever shape
    # Compose allows -- a bare shell string, or a list whose first element is
    # the CMD/CMD-SHELL marker -- and hold it to HEALTHCHECK_PROBE. A container
    # deferring to its image's own HEALTHCHECK carries `disable: false` and no
    # `test:` at all, which is a different decision and not one this reads.
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
    # And bounded by the same two numbers everywhere. The keys above say a
    # container cannot log without limit; this says twelve stacks cannot each
    # pick their own limit, which is the drift the shared fragment exists to
    # prevent and the one a presence check never sees.
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

    # A library and the staging directory that feeds it must land inside one bind
    # mount. rename(2) refuses to cross a mount boundary even when both sides are
    # the same filesystem, so mounting each directory separately turns every
    # import into a full byte copy plus unlink and puts hardlinking out of reach.
    # Nothing in the container's own view says so -- the paths look like
    # neighbours and the import still reports success -- which is how two stacks
    # carried the defect while their roles claimed the opposite in a comment.
    #
    # The pairs are derived, not listed. A container path in the environment
    # naming a `.acquisition` staging root identifies the share it stages for;
    # every other environment path beneath that share is a library it can import
    # to, and both sides must resolve to the same longest-prefix mount. So a
    # third mount reintroduced at a library path is caught the same way the
    # original four were, and a downloader that mounts only staging pairs with
    # nothing and is not asked to.
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

# The pairing above discovers its own subjects, so an empty sweep would report a
# clean repository having compared nothing: an environment variable renamed to a
# value the path pattern no longer matches, or a staging root moved out from
# under `.acquisition`, is enough to empty it silently. Bindery declares both of
# the pairs the platform has today, so the floor is two rather than one.
check(failures, import_pairs >= 2,
      "the same-mount import check paired #{import_pairs} libraries with their staging roots; " \
      "at least the two Bindery declares must stay discoverable")

# Exactly, in both directions. An unlisted container reaching a self-sizing
# image fails here, and so does the list ceasing to reach a container it is
# expected to -- an image bumped to another repository, a container renamed, a
# stack retired. A floor would pass the second case as long as something else
# still matched.
check(failures,
      self_sizing_containers.transform_values(&:sort).sort.to_h ==
        EXPECTED_SELF_SIZING_CONTAINERS.transform_values(&:sort).sort.to_h,
      "containers on self-sizing images are " \
      "#{self_sizing_containers.transform_values(&:sort).sort.to_h.inspect}, and the pinned " \
      "expectation is #{EXPECTED_SELF_SIZING_CONTAINERS.inspect}; update both together")

# Service templates write their storage paths as literals, and Compose takes
# those rendered values straight through as bind sources. That makes the
# template path a second declaration of what nas_storage already declares, with
# nothing comparing the two: renaming one side leaves host_prep creating one
# directory while the service mounts another. Compose volume sources cannot
# reach these, because they arrive as an opaque ${SERVICE_..._PATH:?} the
# template supplies, so the templates are read directly here.
#
# Only a literal with a path suffix is a declaration. Several templates export
# the volume root itself (NAS_MEDIA_ROOT, NAS_DOCKER_ROOT, PLATFORM_MEDIA_ROOT)
# for a service to join onto, and requiring the suffix keeps those out.
#
# A media library root may also sit above the declared entries rather than at or
# below one, which is how Jellyfin mounts the whole media tree while nas_storage
# declares only the libraries below it: Ansible's file
# module creates the parent, and the leaves are where a mode and a recovery
# class belong. Demanding an exact entry would reject that legitimate parent
# mount. Accepting it is confined to the media root on purpose, because letting
# a Compose volume source name an ancestor would let a container see a whole
# service state tree where the declared entry gave it one subdirectory — which
# is exactly what the Docker root holds, so paths under it get no such
# allowance and must be declared at or below an entry.
#
# Deliberately source text. This sweeps every role template regardless of
# grammar — env files, XML, INI, YAML fragments — for a storage path written
# into a rendered artifact. There is no one structure to parse across them, and
# a path in a template comment still reaches the render unless the comment
# belongs to the target grammar.
STORAGE_ROOT_ANCESTOR_ALLOWED = {
  "nas_media_root" => true,
  "nas_docker_root" => false
}.freeze
Dir[File.join(ROOT, "roles", "*", "templates", "*.j2")].sort.each do |template_path|
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

# The Compose floor the disposable lanes actually need, which is not the one
# inventory declares.
#
# Compose's `!override` and `!reset` tags -- which replace a list rather than
# merge into it, and which is the whole reason a sandbox override can drop the
# NAS's /dev/dri device or its production port -- were introduced in Compose
# 2.24.4. nas_compose_minimum is 2.18.0, the floor
# community.docker.docker_compose_v2 documents, and roles/preflight asserts it on
# every host. That floor is right for the NAS, whose canonical compose.yml files
# carry no tag at all, and wrong for both disposable lanes: a host at 2.18.0
# passes preflight and then dies on the first override it cannot parse, which is
# ntfy rather than whatever anybody was changing.
#
# The tags are found as text, and that is the point rather than an economy.
# Psych resolves an unrecognised tag away without complaint, so the loop above --
# which reads these very files through YAML.safe_load_file -- cannot see the one
# thing that sets the floor, and neither can any other parse-based check in this
# repository. That blindness is why the defect survived two lanes and sixteen
# services. The pattern matches a tag in value position, so a `!override` written
# inside a comment (services/nextcloud/compose.mac.yml has one) is not mistaken for
# a use of it.
#
# What this proves, exactly: the floors the two harnesses request are consistent
# with the tags present in the tree, in both directions -- a kind that gains the
# tags, and a harness that stops requesting the floor, both fail here. It does
# not prove any real Mac or CI runner has that Compose installed, and 2.24.4 is
# taken from Compose's own release notes rather than measured here.
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
# Neither harness can put this in inventory. tests/policy_platform_test.rb holds
# a host group to machine facts and PLATFORM_* port lookups, so mac_hosts cannot
# carry it; the integration sandbox binds to inventory/local.yml and is a
# nas_hosts run like the NAS, so there is no group in which "2.18.0 there,
# 2.24.4 here" is expressible at all. Both request it on the command line.
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

# Timing is platform policy, not a number typed into a task. These values were
# literals across nine roles: one readiness delay written eleven times and four
# unrelated stack timeouts, with nothing relating any copy to any other, so they
# drifted independently. inventory/group_vars/all declares the ordinary wait and
# the ordinary readiness poll, and a service that needs longer declares its own
# role default with the reason beside it. A bare number bypasses both at once —
# it is neither the shared policy nor a documented deviation from it — so a bare
# number is refused and the task has to name which of the two it is.
#
# retries and delay are read as task keywords rather than searched for, because
# modules carry arguments of the same name that are not this policy at all:
# ansible.builtin.wait_for takes its own delay, and a Compose health check takes
# its own retries. wait_timeout only ever appears as a module argument, so it is
# looked for wherever a task carries it.
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
TIMING_KEYWORD_POLICY = {
  "retries" => "platform_readiness_retries",
  "delay" => "platform_readiness_delay"
}.freeze
role_task_files.each do |path|
  relative_path = path.delete_prefix("#{ROOT}/")
  flatten_tasks(YAML.safe_load_file(path, aliases: true)).each do |task|
    task_name = task["name"] || "an unnamed task"
    TIMING_KEYWORD_POLICY.each do |keyword, shared_variable|
      check(failures, !task[keyword].is_a?(Integer),
            "#{relative_path}: \"#{task_name}\" writes #{keyword}: #{task[keyword]} as a literal; " \
            "read #{shared_variable} or a role default that says why it differs")
    end
    check(failures, !literal_wait_timeout.call(task),
          "#{relative_path}: \"#{task_name}\" writes wait_timeout as a literal; " \
          "read platform_compose_wait_timeout or a role default that says why it differs")
  end
end

# --- whitespace backslash escapes inside Jinja expressions -------------------
#
# A backslash escape inside a `{{ }}` expression is never an escape under
# Ansible. AnsibleLexer pre-escapes every backslash in an expression's string
# constants before Jinja's own lexer can run its unicode_escape pass over them,
# so YAML is the only layer that processes a backslash and
# regex_replace('^(.*)_x$', '\1') means a backreference here rather than the
# byte \x01 it would mean under Jinja alone. The price is that '\n' inside an
# expression stays two characters, and a split on it finds no separator.
#
# THE CLASS HAS BITTEN TWICE, in two unrelated roles, which is why it is here
# rather than in one service contract (#530):
#   * roles/nextcloud/tasks/reconcile_trusted_domains.yml split occ's output on
#     '\n', so the live trusted_domains array read as one blob, every managed
#     domain read as missing, and the repair loop re-set all three on every
#     converge. The nextcloud lane's second converge reported changed=1; no
#     check in this repository would have (#513).
#   * roles/trailarr/tasks/reconcile_env.yml joined on '\n' and every following
#     run found the environment it had just written back differing again. Fixed
#     by hoisting the separator into a double-quoted `vars` entry, where YAML
#     resolves it to a real newline before Jinja is handed the expression.
# Two comments in two roles cannot enforce each other, so this file does it for
# all of them. It lands green on the tree as it stands: the sweep that motivated
# it found zero hits across every role task file and every root playbook.
#
# Scoped to `{{ }}` regions rather than to every string, because the
# pre-escaping is scoped that way too: AnsibleLexer exempts `{% %}` statements,
# and a folded `{% set p = raw.split('\n') %}` really does split on a newline
# while the `{{ }}` beside it does not. Measured on ansible-core 2.21.4, along
# with the fact that the YAML quoting does not decide it -- folded,
# single-quoted and double-quoted scalars all read one element, which the
# message repeats so the next reader does not reach for a different quote.
#
# Restricted to the whitespace escapes \n, \t and \r rather than to every
# backslash -- which is why the message says whitespace and not backslash, since
# Ansible processes none of them and this refuses only the three. Banning every
# backslash would ban the backreference the pre-escaping exists to make work.
#
# WHAT THAT LEAVES UNCOVERED, stated rather than discovered later: an escape
# handed to a regex filter is processed by Python's own re module, so
# regex_replace('\t', ' ') is correct and this would refuse it. Nothing in the
# repository does that today; the exemption belongs here when one arrives.
#
# The subject is every role task and handler file plus every root playbook. The
# playbook half is the part the nextcloud-scoped original could not reach, and
# it is floored separately: a combined floor passes while the playbook list
# silently empties, because the role list is twenty times its size.
root_playbook_files = Dir[File.join(ROOT, "*.yml")].sort.select do |path|
  document = YAML.safe_load_file(path, aliases: true)
  document.is_a?(Array) && document.all? { |play| play.is_a?(Hash) && play.key?("hosts") }
end
# 60 and 5 are sized against the mutation sandbox, not the tree: the harness
# copies each role's main.yml and what it statically imports, so the role list
# is 66 there against 117 here, while every root playbook is a stated fixture
# path and all five are present in both.
check_floor(failures, role_task_files.length, 60,
            "the Jinja escape scanner found too few role task files")
check_floor(failures, root_playbook_files.length, 5,
            "the Jinja escape scanner found too few root playbooks")
(role_task_files + root_playbook_files).each do |path|
  relative_path = path.delete_prefix("#{ROOT}/")
  # task_strings over the whole parsed document rather than over flattened
  # tasks, because a playbook's strings live in pre_tasks, vars and play
  # keywords as well, and the escape is wrong wherever Jinja meets it.
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

# A fetch from the public internet is the one task in a converge whose failure
# is somebody else's outage, and #330 is what that costs: the Hebrew OCR model
# was fetched with no retry and no timeout, raw.githubusercontent.com timed out
# at get_url's ten-second default, and a run that had converged 1388 tasks
# failed. On the NAS it compounds -- scripts/production_auto_deploy.py records
# the revision as attempted and failed and refuses it thereafter -- so a blip
# stalls automatic deployment until an operator intervenes.
#
# The class is get_url and nothing else today, and that was established by
# looking rather than assumed: every ansible.builtin.uri task in the repository
# addresses 127.0.0.1 or a Compose service name, because roles run on the target
# by design, and the external URLs in roles/jellyfin are plugin-repository
# values written into Jellyfin's own configuration for Jellyfin to fetch, not
# Ansible fetches. So requiring the four keywords on get_url covers every task
# that reaches a third party, and a future module that does needs its own entry
# here.
#
# The timeout is required, and required not to be a literal, in this check
# specifically: `timeout` is an ordinary module argument that local tasks pass
# legitimately, so literal_wait_timeout above cannot claim it the way it claims
# wait_timeout. retries and delay are only checked for presence here, because
# that same policy already refuses a literal for them in any role task.
#
# `until` must name the registered result. A retry loop whose condition does not
# read what the attempt produced is a loop that runs once and reports success,
# which looks exactly like this policy being satisfied.
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

# The sweep above discovers its own subjects, so an empty one would report a
# clean repository having inspected nothing -- renaming the module key, or
# collapsing these tasks into a loop the flattener does not walk, is enough to
# empty it in silence. Paperless and Pinchflat are the two external fetches the
# platform has, so the floor is two rather than one.
check(failures, external_fetch_tasks >= 2,
      "the external fetch policy inspected #{external_fetch_tasks} get_url tasks; " \
      "at least the Paperless OCR model and the Pinchflat yt-dlp build must stay discoverable")

check(failures, deploys_through_module,
      "no role deploys anything through docker_compose_v2")

# community.docker.docker_compose_v2_exec does not fail on a nonzero exit code.
# Read out of the module rather than inferred (plugins/modules/
# docker_compose_v2_exec.py, identical in 5.2.2 and the 5.3.0 requirements.yml
# pins): `run` sets check_rc only inside `if self.detach:`, call_cli defaults it
# to False, and every other invocation returns {"changed": True, "rc": rc, ...}
# whatever rc was. So an exec task with no failed_when cannot fail, and one that
# also states `changed_when: true` asserts a change it never verified -- the
# clean PLAY RECAP with the wrong answer behind it (#521). Twelve tasks were in
# that state when this check was written, one of them the occ password reset
# whose failure left the vault credential unable to authenticate while the
# deployment report announced a repair.
#
# The rule is the broad one deliberately: every non-detached exec, not only the
# changed_when: true subset the issue named. A read that reports success on a
# failed command is the same defect one stage earlier -- the Paperless identity
# inspection fed a from_json that named neither container nor command -- and
# `failed_when: false` satisfies the rule, so a task that genuinely tolerates
# failure states that it does instead of leaving it to be inferred from silence.
#
# `detach` is exempt because the module checks rc itself in exactly that branch.
# The exemption is deliberately narrow: only a literal true is honoured, so a
# templated or unrecognised value stays a subject and the check fails toward
# refusing rather than toward excusing.
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

    # Presence is not the property. `failed_when` REPLACES the module's own
    # failure verdict, so a condition naming a register the task does not set
    # resolves to an undefined lookup, evaluates false, and disarms the module
    # more thoroughly than omitting the line would -- the omission at least left
    # the detach branch honest. A condition that tolerates failure says
    # `failed_when: false` and is exempt; anything else has to be reading this
    # task's own result, so it must name the register this task writes.
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
# A floor, not `!empty?`: this sweep discovers its own subjects from the tree, so
# renaming the module key or moving these tasks somewhere the flattener does not
# walk would report a clean repository having inspected nothing. Twenty exec
# tasks are in roles/ today. The floor is twelve rather than twenty because the
# mutation sandbox copies only a role's statically imported stage files plus the
# paths BASE_FIXTURE_PATHS names, and jellyfin/tasks/qsv_probe.yml and
# paperless_ngx/tasks/managed_users.yml are reached by include_tasks -- so this
# check sees fourteen there, and raising the floor to today's count would redden
# every sandbox rather than catch anything.
check_floor(failures, compose_exec_tasks, 12,
            "docker_compose_v2_exec tasks the exit-code policy inspected")

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
#
# Read through static_role_tasks, not main.yml: the role is one stage per file
# now, and the property below is guarded by `jellyfin_startup.nil? ||`, so a
# reader that stops at the index would report the property holding on a role it
# never looked at.
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

# Every subject below is a property of the Paperless contract's runtime half,
# which is tests/contracts/paperless-runtime.rb since issue #147 gave it a file.
# Reading the wrapper instead would leave all eight checks matching nothing and
# refusing the repository forever.
paperless_contract = File.read(File.join(ROOT, "tests", "contracts", "paperless-runtime.rb"))
# The coordinated snapshot is snapshot-paperless.rb since #315; the .sh beside it
# is the wrapper that validates the mode and exports the environment, and holds
# none of the Ruby this reads.
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
  # The role gates itself: `roles/container_cpu/tasks/main.yml` includes the
  # Docker inspection only when not in check mode. A caller that repeats that
  # guard is copying a condition it does not own, and the next caller is the one
  # that forgets it.
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


# Included reconciliation files are gated on a phase string the caller passes
# through vars:. include_tasks never applies meta/argument_specs.yml, so a phase
# matching no gate turns the whole file into a silent no-op that still reports
# success -- and verify.yml reaches every verification it owns through exactly
# this mechanism, so a renamed call site would remove a verification without
# failing anything. Each gated file therefore opens with an unconditional assert
# naming the phases it implements, every literal it gates on must appear in that
# list, and the phases its callers actually pass must be exactly that list.
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
# Both loops below skip a file that gates on no phase, so an empty list is a
# clean run. It is floored indirectly today -- no task files means no
# role_task_files, which trips deploys_through_module -- but that floor reads
# tasks and handlers together, so a tree whose handlers alone carried
# docker_compose_v2 would satisfy it while every phase gate went unchecked.
#
# 25 is sized against the mutation fixture's 58, not the tree's 107: the harness
# copies each role's main.yml and what it statically imports, so this list is
# roughly half its real size inside every sandbox this script runs in.
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
    # A file that is not on disk is a different failure, reported elsewhere, and
    # the reduced fixture the mutation harness builds carries the callers without
    # the files they include.
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
declared_phases.each do |relative_path, declarations|
  declarations.each do |variable, phases|
    reached = (passed_phases.dig(relative_path, variable) || []).uniq.sort
    check(failures, reached == phases,
          "#{relative_path}: declares #{variable} phases #{phases.join(', ')} but its callers " \
          "pass #{reached.empty? ? 'none' : reached.join(', ')}")
  end
end

# The integration controller is a program in the same checkout it inspects.
# /repo inside its container is the copy of this tree the run is testing, and
# the file itself sits at /repo/tests, so a path taken from $0, dirname "$0" or
# BASH_SOURCE resolves into the tree the program is judging rather than the
# tree it is meant to act on. The launcher hands it both roots as environment;
# nothing in it may work one out for itself. The precedent for reading a
# sibling as /repo/tests/... is already in the file, which is exactly why a
# reviewer would read a new dirname as consistent rather than as a defect.
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

  # Extracting the program out of the sh -c argument made shellcheck able to
  # read it and it immediately found defects the escaping had hidden: 53 SC2086
  # and 4 SC2068 unquoted expansions, and one SC2070 -- `[ -n $VAR ]`, which
  # tests true on an empty value. That SC2070 was not cosmetic: it was the whole
  # of the bug that ran the nightly's idempotence and check-mode phases over 88
  # of 1495 tasks, so it is fixed and its exclusion is gone. The other two codes
  # remain pre-existing and stay excluded. Pinned here because an exclusion list
  # that may quietly grow is a check that quietly stops running -- and dropping a
  # code from it, as this change does, must cost an edit here rather than pass
  # unremarked.
  manifest = File.read(File.join(ROOT, "tests", "validate-policy.sh"))
  controller_check = manifest.lines.map(&:chomp).find do |line|
    line.end_with?(" tests/integration_controller.sh")
  end
  check(failures, controller_check ==
        "shellcheck --shell=sh -x --exclude=SC2068,SC2086 " \
        "tests/integration_controller.sh",
        "tests/validate-policy.sh: the integration controller must be " \
        "shellchecked excluding exactly SC2068,SC2086, not " \
        "#{controller_check.inspect}")
end

# The controller must not go back to being text inside a shell string: that is
# the shape that made it unreachable by sh -n and shellcheck in the first place.
launcher_source = File.read(File.join(ROOT, "tests", "integration.sh"))
check(failures, !launcher_source.include?(%(sh -eu -c ")),
      "tests/integration.sh: the controller is a program again pasted into an " \
      "sh -c argument, where no syntax check or linter can read it")


# Every top-level def in a Python file as raw source text, keyed by name and
# collected as a list so a redefinition further down is visible rather than
# hidden behind the first. Comments above a def belong to no definition, which
# is what lets a script keep prose the other one cannot honestly repeat.
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
  # Without this the default block would answer an absent name with [], whose
  # .first is nil -- and [nil, nil].uniq.length == 1, so a name no script
  # defines would read as two scripts agreeing. Dropped, an absent name answers
  # nil and the next call on it raises, which is a failure rather than a pass.
  definitions.default_proc = nil
  definitions
end

# One line of Python with its string literals removed, so a bracket count over
# what is left counts code brackets. Without this,
# MARKDOWN_PATTERN = re.compile(r"([\\`*_{}\[\]()#+\-.!|>])") is a line whose
# brackets happen to balance inside the quoted character class and whose `#`
# would read as a comment. Triple-quoted strings are not handled and no
# module-level constant here uses one; one that did would be caught by the
# per-constant line count below rather than silently mis-extracted.
PYTHON_STRING_LITERAL = /
  (?:[rRbBfFuU]{0,2})
  (?: "(?:\\.|[^"\\])*" | '(?:\\.|[^'\\])*' )
/x
def python_bracket_delta(line)
  code = line.gsub(PYTHON_STRING_LITERAL, "").sub(/#.*\z/, "")
  code.count("([{") - code.count(")]}")
end

# Every top-level constant assignment in a Python file as raw source text, keyed
# by name and collected as a list so a reassignment further down is visible
# rather than hidden behind the first -- the same shape, and the same reasons, as
# python_top_level_definitions above. A comment above an assignment belongs to no
# constant, which is what lets one copy carry prose the other cannot honestly
# repeat.
#
# The extent of an assignment is bracket depth rather than indentation, because a
# dict or tuple constant closes on a column-0 `}` or `)` that an indentation rule
# would read as the next top-level statement.
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


# scripts/production_auto_deploy.py and scripts/image_prune.py are two
# self-sufficient single-file programs, and that is structural rather than an
# oversight: each is installed on the NAS by an ansible.builtin.copy of exactly
# one file, so a shared module would be a second file that must land too, and a
# script that arrived without it would die at import -- before any handler could
# report it, on every five-minute tick, with no merge able to heal the host.
# services/dozzle/alert_relay.py mirrors the same helpers from inside a
# container, where a module in the deploy account's home is not reachable at
# all. So the duplication stays.
#
# Divergence is the part that does not have to. The two copies of _write_private
# drifted in opposite directions until one fsynced and never repaired the mode
# while the other repaired the mode and never fsynced, each carrying the bug the
# other had fixed (#354). Compared as text here, so re-divergence fails in the
# fast loop rather than on the NAS.
#
# Compared as text and not as code, because every filter that would let the two
# copies differ cosmetically is a filter that can get one edge case wrong,
# compare empty to empty and pass. Prose true of only one script therefore lives
# in a comment above its def, which is outside the extracted body. That is why
# these definitions are byte-identical down to the docstring (#423).
#
# services/dozzle/alert_relay.py mirrors markdown_escape from inside a container
# and is deliberately outside this glob: its copy takes a different bound and no
# annotations, so it is a relative rather than a duplicate. Do not converge it.
duplicated_scripts = Dir.glob(File.join(ROOT, "scripts/*.py")).sort
check_floor(failures, duplicated_scripts.length, 2, "scripts/*.py programs")
script_definitions = duplicated_scripts.to_h do |path|
  [File.basename(path), python_top_level_definitions(path)]
end

# The fewest lines each definition can honestly be, per name rather than one
# number: _timestamp is two statements and _write_private is forty lines, so a
# floor low enough for both would be barely more than non-emptiness while a
# floor sized for the largest would fail the smallest. An extractor that stopped
# at the first blank line yields two lines for every one of these, so each floor
# is set well above that and below the current length, leaving room for prose.
duplicated_helper_floors = {
  "_write_private" => 20,
  "_record_lock_holder" => 12,
  "markdown_escape" => 6,
  "_timestamp" => 6,
}
check_floor(failures, duplicated_helper_floors.length, 4,
            "helpers held identical across scripts/*.py")

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
    # Both halves of the extraction, because an extractor that stopped at the
    # first blank line and one that ran on into the next definition would each
    # compare equal to itself across the two files and prove nothing.
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

# The list above is stated, and a stated list of what must match fails open: the
# guard covered only _write_private for as long as it existed, while
# markdown_escape, _timestamp and _record_lock_holder sat duplicated and
# unwatched beside it (#423). This closes that, derived rather than stated: a
# copy is byte-identical at the moment it is made, so a name both scripts define
# whose bodies already agree is a fresh duplicate and must be named above. The
# names that differ on purpose -- format_duration, rotate_logs, and the entry
# points main, load_config, _run and their kin -- never reach it.
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
#
# Two holes in everything above, both of them the #354 shape displaced.
#
# THE PINNED FUNCTION'S OWN INPUT WAS UNPINNED. markdown_escape is compared
# byte-for-byte; MARKDOWN_PATTERN, the character class it escapes with, is
# byte-identical in all three copies and was referenced by no test at all. Cut
# to r"([\\`*])" in one script, both markdown_escape bodies left untouched,
# policy_test.rb reported all properties holding and the pruner's ntfy
# notification would have shipped unescaped _ * [ ] # | > while the deploy
# poller's did not -- with the identity check on the consumer reporting the two
# copies identical. NOTIFICATION_TIMEOUT_SECONDS = 10 is the same class in two
# files and was compared by nothing either.
#
# THE SUBJECT COULD NOT SEE THE RELAY. Everything above globs scripts/*.py and
# derives its reverse direction with reduce(:&), so it needs BOTH scripts to
# define a name. services/dozzle/alert_relay.py is outside that glob by design
# and CLAUDE.md names it as a third copy site, so a verbatim copy shared by the
# relay and exactly one script was pinned by nothing: planted as _shared_bound in
# image_prune.py and alert_relay.py, it left this file green.
#
# NOT CLOSED BY CONVERGING BODIES, and the comment above is right about why: the
# relay's markdown_escape takes a different bound and no annotations and declines
# to escape intra-word underscores, so it is a relative rather than a duplicate.
# What it shares with the scripts is the DATA, and data has no such excuse.
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

# Which copies of a constant must agree, and how long the extraction of each must
# be. The site list is exact in both directions rather than a floor: a copy that
# disappears is as much a change to this contract as one that diverges, and a
# floor of two would let the relay drop MARKDOWN_PATTERN silently.
#
# `lines` is the honesty half, and it is an exact count rather than the floor the
# function table uses, because one line is a legitimate length for a constant and
# a floor of one is not a check. It catches both an extraction that stopped early
# on a multi-line constant and one that ran into the next statement. A legitimate
# reformat costs one edit here, which is the stated-number posture this file
# takes everywhere else.
duplicated_constant_sites = {
  "MARKDOWN_PATTERN" => {
    "sites" => %w[
      scripts/image_prune.py
      scripts/production_auto_deploy.py
      services/dozzle/alert_relay.py
    ],
    "lines" => 1
  },
  "NOTIFICATION_TIMEOUT_SECONDS" => {
    "sites" => %w[scripts/image_prune.py scripts/production_auto_deploy.py],
    "lines" => 1
  }
}
check_floor(failures, duplicated_constant_sites.length, 2,
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
        "above already pins: markdown_escape can be byte-identical in all three files " \
        "while one of them escapes a different character class, and that reads as the " \
        "copies agreeing (#515)")
end

# The reverse direction, derived rather than stated, exactly as the reduce(:&)
# stanza above derives it for functions across scripts/*.py -- and for the same
# reason, since a stated list of what must match fails open.
#
# TWO DIFFERENCES FROM THAT STANZA, both of them the holes this closes. The
# subject is the three copy sites rather than the glob, so the relay is in it.
# And the rule is "SOME PAIR is byte-identical" rather than "every site that
# defines it agrees": the weaker phrasing fails open on precisely the shape being
# closed, because a name in all three where two agree and the third differs on
# purpose would go unflagged while those two sat unpinned. markdown_escape is
# clean here because it is excluded by name, not because its bodies disagree.
#
# The stanza above is this rule over a narrower subject and is left alone: its
# glob picks up a fourth scripts/*.py program that this stated site list would
# not, so the two cover different futures. A divergence in their overlap is
# reported twice, which is noise rather than a defect.
site_names = DUPLICATION_SITES.to_h do |relative|
  [relative, site_definitions.fetch(relative).keys.to_set + site_constants.fetch(relative).keys.to_set]
end
shared_across_sites = site_names.values.combination(2).map { |left, right| left & right }
                                .reduce(Set.new, :|).sort
check_floor(failures, shared_across_sites.length, 15,
            "top-level names shared by at least two of the copy sites")
# And a second floor, on the relay's own participation, for the same reason the
# Jinja escape scanner above floors its two subject lists separately. Sixteen of
# the twenty-one names that count above come from the two scripts/*.py files
# alone, so a subject that stopped reaching services/dozzle/alert_relay.py -- a
# moved path, an extractor returning nothing for it -- would leave the count
# comfortably above fifteen while the half of this check that #515 exists for
# stopped running. DUPLICATION_SITES.length does not cover it: that proves the
# path is in the list, not that anything was read out of it. Six today --
# MARKDOWN_PATTERN, TIMESTAMP_PATTERN, main, markdown_escape, publish and
# render_notification -- of which only two are byte-identical, which is exactly
# the mix that makes the relay worth reading.
relay_site = "services/dozzle/alert_relay.py"
check(failures, DUPLICATION_SITES.include?(relay_site),
      "#{relay_site} must be one of the copy sites: CLAUDE.md names it as the third place these " \
      "helpers are duplicated, and the reduce(:&) stanza above cannot see it")
relay_shared = (site_names[relay_site] || Set.new).select do |name|
  DUPLICATION_SITES.any? { |relative| relative != relay_site && site_names.fetch(relative).include?(name) }
end
check_floor(failures, relay_shared.length, 5,
            "top-level names #{relay_site} shares with a scripts/*.py program")
listed_by_name = duplicated_helper_floors.keys.to_set | duplicated_constant_sites.keys.to_set
unlisted_pairwise = shared_across_sites.reject { |name| listed_by_name.include?(name) }.select do |name|
  bodies = DUPLICATION_SITES.flat_map do |relative|
    [site_definitions.fetch(relative), site_constants.fetch(relative)]
      .filter_map { |table| table[name].first if table.key?(name) }
  end
  # Two sites spelling it the same way is what makes it a copy. Comparing
  # lengths rather than asking whether every site agrees is the whole point:
  # a third site differing on purpose must not excuse the pair that does not.
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
