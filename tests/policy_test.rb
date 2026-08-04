#!/usr/bin/env ruby
# Property-based policy checks.
#
# Deliberately asserts *properties* rather than per-service expected values.
# Literal assertions grow linearly with services, must be edited for every
# change, and tempt you into pinning documentation prose, which couples wording
# to CI while validating no behaviour. Adding a service here requires no edits.

require "yaml"

ROOT = File.expand_path("..", __dir__)
failures = []

def check(failures, condition, message)
  failures << message unless condition
end

service_dirs = Dir[File.join(ROOT, "services", "*")].select { |p| File.directory?(p) }
check(failures, service_dirs.any?, "no services defined")

storage = YAML.safe_load_file(File.join(ROOT, "inventory", "group_vars", "all", "main.yml"))
declared_paths = storage.fetch("nas_storage").map { |entry| entry.fetch("path") }

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

if failures.empty?
  puts "policy: all properties hold"
else
  failures.each { |f| warn "FAIL #{f}" }
  abort "#{failures.length} policy violation(s)"
end
