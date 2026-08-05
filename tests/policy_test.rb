#!/usr/bin/env ruby
# Property-based policy checks.
#
# Most checks deliberately assert properties rather than per-service values.
# The source-platform inventory is the exception: pinning that finite set keeps
# an omitted legacy service from silently disappearing from the migration scope.

require "open3"
require "set"
require "yaml"
require_relative "policy_support"

include PolicySupport

ROOT = File.expand_path("..", __dir__)
failures = []

def check(failures, condition, message)
  failures << message unless condition
end

service_dirs = Dir[File.join(ROOT, "services", "*")].select { |p| File.directory?(p) }
check(failures, service_dirs.any?, "no services defined")

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
SERVICE_CONTRACT_BASENAME_EXCEPTIONS = { "paperless-ngx" => "paperless" }.freeze
REQUIRED_MANIFEST_FIELDS = %w[name legacy_path role tranche status].freeze
ALLOWED_SERVICE_STATUSES = %w[planned implemented accepted].freeze
IMPLEMENTED_STATUSES = %w[implemented accepted].freeze

def flatten_tasks(tasks, flattened = [])
  Array(tasks).each do |task|
    next unless task.is_a?(Hash)

    flattened << task
    %w[block rescue always].each { |section| flatten_tasks(task[section], flattened) }
  end
  flattened
end

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
  prefixes = [service_name.tr("-", "_"), role_name].uniq
  service_names = [service_name, role_name].uniq
  expected_tag = "platform_verify_#{service_name}"
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

  contract_basename = SERVICE_CONTRACT_BASENAME_EXCEPTIONS.fetch(name, name)
  relative_contract_path = "tests/contracts/#{contract_basename}.sh"
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

      next unless source.include?("NAS_DOCKER_ROOT")

      # Service state must be declared in the storage inventory so host_prep
      # creates it with the right ownership and it gets a recovery class.
      relative = source.sub(/\A\$\{NAS_DOCKER_ROOT:\?\}/, "")
      expected = "{{ nas_docker_root }}#{relative}"
      declared = declared_paths.include?(expected) ||
                 declared_paths.any? { |p| expected.start_with?(p + "/") }
      check(failures, declared,
            "#{label}: #{source} is not declared in nas_storage (expected #{expected})")
    end
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
].each do |command|
  check(failures, validation_commands.include?(command),
        "validate-policy.sh must run #{command}")
end

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
  next if value.start_with?("replace-") || value == "192.0.2.1"

  check(failures, false, "#{example_path}: #{key} looks like a real value, not a placeholder")
end

# The example documents what vault must contain; the generator's template is what
# actually gets written. Drift means an operator follows the example and ends up
# with a vault missing keys the roles require, failing late and confusingly.
def vault_keys(path)
  File.readlines(path).grep(/^vault_[a-z_]+:/).map { |line| line[/^vault_[a-z_]+/] }.sort
end

template_keys = vault_keys(File.join(ROOT, "templates", "vault-plain.yml.j2"))
example_keys = vault_keys(example_path)
(template_keys - example_keys).each do |key|
  check(failures, false, "vault.yml.example is missing #{key}, which the generator writes")
end
(example_keys - template_keys).each do |key|
  check(failures, false, "generate-secrets.yml does not produce documented key #{key}")
end

vault_path = File.join(ROOT, "inventory", "group_vars", "all", "vault.yml")
if File.file?(vault_path)
  first = File.open(vault_path, &:readline).strip
  check(failures, first.start_with?("$ANSIBLE_VAULT;"), "vault.yml is present but not encrypted")
end

# The plays must be exercised, not merely parsed: the two worst bugs so far, a
# Darwin-only fact and command being skipped under --check, both survived syntax
# checking and were caught by running.
harness = File.read(File.join(ROOT, "tests", "integration.sh"))
["IDEMPOTENT", "CHECK MODE"].each do |property|
  check(failures, harness.include?(property), "integration harness must assert #{property}")
end
first_converge = harness.index("\n    run_play\n")
contract_execution = harness.index("ruby /repo/tests/run_contracts.rb --execute")
idempotence_phase = harness.index("=== phase 2: asserting idempotence ===")
check(failures, first_converge && contract_execution && idempotence_phase &&
                first_converge < contract_execution && contract_execution < idempotence_phase,
      "integration must execute registered contracts after converge and before idempotence")
check(failures, harness.match?(/^ruby_package='ruby=\d+\.\d+\.\d+-r\d+'$/) &&
                harness.match?(/^curl_package='curl=\d+\.\d+\.\d+-r\d+'$/),
      "integration must pin distro ruby and curl packages")

if failures.empty?
  puts "policy: all properties hold"
else
  failures.each { |f| warn "FAIL #{f}" }
  abort "#{failures.length} policy violation(s)"
end
